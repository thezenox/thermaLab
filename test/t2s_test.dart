import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 't2s_fixture.dart';

import 'package:t2s_thermal/t2s/shutter_correction.dart';
import 'package:t2s_thermal/t2s/t2s_commands.dart';
import 'package:t2s_thermal/t2s/t2s_frame.dart';
import 'package:t2s_thermal/t2s/temperature_model.dart';

void main() {
  group('frame decoding', () {
    test('splits image and metadata rows and reads fields', () {
      final Uint8List bytes = buildFrame(
        imageValue: 9000,
        fpaRaw: 8617,
        shutterRaw: 3000,
        cal01: 0.25,
        emissivity: 0.95,
        firmware: 'T2S+V2.1',
      );
      final T2sFrame f = T2sFrame.decode(bytes, 256, 196)!;
      expect(f.width, 256);
      expect(f.height, 192);
      expect(f.counts.length, 256 * 192);
      expect(f.counts.every((int v) => v == 9000), isTrue);
      expect(f.meta.fpaRaw, 8617);
      expect(f.meta.fpaTemp(f.profile), closeTo(20.0, 1e-9));
      expect(f.meta.shutterRaw, 3000);
      expect(f.meta.shutterTempV1, closeTo(300.0 - 273.15, 1e-9));
      expect(f.meta.cal01, closeTo(0.25, 1e-7));
      expect(f.meta.emissivity, closeTo(0.95, 1e-7));
      expect(f.meta.firmwareVersion, 'T2S+V2.1');
    });

    test('rejects frames that do not fit the layout', () {
      expect(T2sFrame.decode(Uint8List(100), 256, 196), isNull);
      expect(T2sFrame.decode(Uint8List(1000000), 300, 196), isNull);
    });

    test('V2 shutter decoding follows the vendor formula', () {
      T2sMetadata meta(int shutterRaw, int fix) => T2sFrame.decode(
        buildFrame(shutterRaw: shutterRaw, shutterFixRaw: fix),
        256,
        196,
      )!.meta;
      // raw < 2049: v = raw * 0.625, T = (v + 2731.5) / 10 - 273.15
      expect(meta(451, 0).shutterTempV2, closeTo(28.1875, 1e-9));
      // raw >= 2049: v = (0xFFF - raw) * -0.625
      expect(meta(4095, 0).shutterTempV2, closeTo(0.0, 1e-9));
      // Upper byte of the fix word is a signed 0.1 °C correction.
      expect(meta(4095, 0xFA00).shutterTempV2, closeTo(-0.6, 1e-9));
      expect(meta(4095, 0x0300).shutterTempV2, closeTo(0.3, 1e-9));
    });
  });

  group('commands', () {
    test('float parameters become four position/byte words', () {
      final List<int> words = encodeFloat(T2sParameter.emissivity, 0.95);
      final ByteData d = ByteData(4)..setFloat32(0, 0.95, Endian.little);
      expect(words, <int>[
        for (int i = 0; i < 4; i++) ((16 + i) << 8) | d.getUint8(i),
      ]);
    });

    test('uint16 parameters become two words', () {
      expect(encodeUint16(T2sParameter.distance, 0x0102), <int>[
        (20 << 8) | 0x02,
        (21 << 8) | 0x01,
      ]);
    });
  });

  group('temperature model', () {
    final T2sFrame frame = T2sFrame.decode(
      buildFrame(
        fpaRaw: 8617,
        shutterRaw: 451,
        cal00: 8000,
        cal01: 0.25,
        cal02: 30,
        cal03: -0.00001,
        cal04: 0.01,
        cal05: 1.0,
        emissivity: 0.95,
        reflected: 20,
        air: 20,
        humidity: 0.45,
        distance: 1,
      ),
      256,
      196,
    )!;

    test('table is finite and increasing around the operating point', () {
      final TemperatureTable t = TemperatureTable.build(
        frame.meta,
        frame.profile,
        const ModelSettings(revision: HardwareRevision.v2),
      );
      double previous = double.negativeInfinity;
      for (int c = 8000; c < 12000; c += 100) {
        final double v = t.lookup(c);
        expect(v.isFinite, isTrue, reason: 'count $c');
        expect(v, greaterThan(previous), reason: 'count $c');
        previous = v;
      }
    });

    test('user offset shifts every value', () {
      const ModelSettings base = ModelSettings(revision: HardwareRevision.v2);
      final TemperatureTable a = TemperatureTable.build(
        frame.meta,
        frame.profile,
        base,
      );
      final TemperatureTable b = TemperatureTable.build(
        frame.meta,
        frame.profile,
        base.copyWith(userOffset: 2.5),
      );
      expect(b.lookup(9000) - a.lookup(9000), closeTo(2.5, 1e-3));
    });

    test('shutter offset solver hits the target', () {
      const ModelSettings settings = ModelSettings(
        revision: HardwareRevision.v2,
      );
      final double? offset = solveShutterOffset(
        meta: frame.meta,
        profile: frame.profile,
        settings: settings,
        count: 9000,
        targetCelsius: 21.0,
      );
      expect(offset, isNotNull);
      final TemperatureTable t = TemperatureTable.build(
        frame.meta,
        frame.profile,
        settings.copyWith(shutterOffset: offset),
      );
      expect(t.lookup(9000), closeTo(21.0, 0.1));
    });

    test('factory emissivity 0.02 is detected as unusable', () {
      final T2sFrame bad = T2sFrame.decode(
        buildFrame(
          fpaRaw: 8617,
          shutterRaw: 451,
          cal00: 8000,
          cal01: 0.25,
          cal02: 30,
          cal03: -0.00001,
          cal04: 0.01,
          cal05: 1.0,
          emissivity: 0.02,
          reflected: 20,
          air: 20,
          distance: 1,
        ),
        256,
        196,
      )!;
      final TemperatureTable t = TemperatureTable.build(
        bad.meta,
        bad.profile,
        const ModelSettings(revision: HardwareRevision.v2),
      );
      expect(t.nanCount, greaterThan(0));
    });
  });

  group('shutter correction', () {
    test('removes a fixed pattern and repairs dead pixels', () {
      const int w = 8;
      const int h = 4;
      final Uint16List pattern = Uint16List.fromList(<int>[
        for (int i = 0; i < w * h; i++) 1000 + (i % 3) * 10,
      ]);
      pattern[5] = 0; // dead pixel
      final ShutterCorrection c = ShutterCorrection.fromFrames(
        <Uint16List>[pattern, pattern],
        w,
        h,
      );
      expect(c.deadPixels, <int>[5]);

      final Uint16List scene = Uint16List.fromList(<int>[
        for (int i = 0; i < w * h; i++) pattern[i] + 50,
      ]);
      final Uint16List out = c.apply(scene);
      final int expected = (c.referenceMean + 50).round();
      for (int i = 0; i < w * h; i++) {
        expect(out[i], closeTo(expected, 1), reason: 'pixel $i');
      }
    });
  });
}

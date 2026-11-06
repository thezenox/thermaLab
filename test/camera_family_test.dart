import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/t2s/camera_catalog.dart';
import 'package:t2s_thermal/t2s/t2s_frame.dart';
import 'package:t2s_thermal/t2s/temperature_model.dart';
import 'package:t2s_thermal/t2s/tiny1c_commands.dart';

/// A P2 Pro style frame: 256x192 picture on top (filled with noise-like
/// bytes) and temperatures in 1/64 K below.
Uint8List tiny1cFrame(double Function(int x, int y) celsius) {
  const int w = 256;
  const int h = 192;
  final ByteData d = ByteData(w * h * 2 * 2);
  for (int i = 0; i < w * h * 2; i++) {
    d.setUint8(i, (i * 37) & 0xFF);
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int raw = ((celsius(x, y) + kZeroCelsius) * 64).round();
      d.setUint16(w * h * 2 + (y * w + x) * 2, raw, Endian.little);
    }
  }
  return d.buffer.asUint8List();
}

void main() {
  group('Tiny1-C frames', () {
    test('lower half becomes temperatures, picture half is ignored', () {
      final T2sFrame f = T2sFrame.decodeTiny1c(
        tiny1cFrame((int x, int y) => 20 + x / 10 + y / 100),
        256,
        384,
      )!;
      expect(f.family, CameraFamily.tiny1c);
      expect(f.width, 256);
      expect(f.height, 192);
      expect(f.meta, isNull);
      final TemperatureTable t = TemperatureTable.linear(
        const ModelSettings(revision: HardwareRevision.v1),
      );
      double at(int x, int y) => t.lookup(f.counts[y * 256 + x]);
      expect(at(0, 0), closeTo(20.0, 0.05));
      expect(at(255, 0), closeTo(45.5, 0.05));
      expect(at(100, 150), closeTo(31.5, 0.05));
    });

    test('covers the high temperature range and applies the user offset', () {
      final T2sFrame f = T2sFrame.decodeTiny1c(
        tiny1cFrame((int x, int y) => x < 128 ? -20 : 550),
        256,
        384,
      )!;
      final TemperatureTable t = TemperatureTable.linear(
        const ModelSettings(revision: HardwareRevision.v1, userOffset: 1.5),
      );
      expect(t.lookup(f.counts[0]), closeTo(-18.5, 0.05));
      expect(t.lookup(f.counts[200]), closeTo(551.5, 0.05));
    });

    test('rejects frames that are too short', () {
      expect(T2sFrame.decodeTiny1c(Uint8List(1000), 256, 384), isNull);
    });
  });

  group('automatic camera detection', () {
    List<OfferedMode> modes(List<(String, int, int)> list) => <OfferedMode>[
      for (int i = 0; i < list.length; i++)
        OfferedMode(list[i].$1, list[i].$2, list[i].$3, i),
    ];

    test('T2S+ stream with metadata rows is Xtherm', () {
      final StreamChoice c = chooseStream(
        modes(<(String, int, int)>[('YUYV', 256, 196)]),
        null,
      )!;
      expect(c.family, CameraFamily.xtherm);
      expect(c.modeIndex, 0);
    });

    test('P2 Pro stream of two halves is Tiny1-C', () {
      final StreamChoice c = chooseStream(
        modes(<(String, int, int)>[
          ('MJPEG', 256, 384),
          ('YUYV', 256, 192),
          ('YUYV', 256, 384),
        ]),
        null,
      )!;
      expect(c.family, CameraFamily.tiny1c);
      expect(c.modeIndex, 2);
    });

    test('HT-301 style 384 px stream is Xtherm', () {
      final StreamChoice c = chooseStream(
        modes(<(String, int, int)>[('YUYV', 384, 292)]),
        null,
      )!;
      expect(c.family, CameraFamily.xtherm);
    });

    test('a known USB ID decides the family', () {
      final KnownCamera p2 = knownCamera('0bda:5830')!;
      expect(p2.family, CameraFamily.tiny1c);
      final StreamChoice c = chooseStream(
        modes(<(String, int, int)>[('YUYV', 256, 384)]),
        p2,
      )!;
      expect(c.family, CameraFamily.tiny1c);
      expect(knownCamera('04b4:0100')!.revision, HardwareRevision.v2);
    });

    test('ordinary webcams are rejected', () {
      expect(
        chooseStream(
          modes(<(String, int, int)>[('YUYV', 640, 480), ('MJPEG', 1280, 720)]),
          null,
        ),
        isNull,
      );
    });
  });

  test('Tiny1-C long command packs like P2Pro-Viewer', () async {
    final List<(int, Uint8List)> sent = <(int, Uint8List)>[];
    final Tiny1cCommands cmd = Tiny1cCommands(({
      required int requestType,
      required int request,
      required int value,
      required int index,
      Uint8List? data,
      int length = 0,
      int timeoutMs = 1000,
    }) {
      if (requestType == 0xC1) return Uint8List.fromList(<int>[0]); // ready
      sent.add((index, data!));
      return Uint8List(0);
    });
    await cmd.setHighGain(false);
    expect(sent[0].$1, 0x9d00);
    // <H cmd> + >H p1 + >I p2: 0xC514 little-endian, gain select 5, value 0
    expect(sent[0].$2, <int>[0x14, 0xC5, 0x00, 0x05, 0, 0, 0, 0]);
    expect(sent[1].$1, 0x1d08);
    expect(sent[1].$2, <int>[0, 0, 0, 0, 0, 0, 0, 0]);
  });
}

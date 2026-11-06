// Frame layout and metadata decoding for the InfiRay / Xtherm T2S+ family.
//
// Ported from IR-Py-Thermal (https://github.com/diminDDL/IR-Py-Thermal,
// GPL-3.0), which reverse-engineered the layout from the vendor app.
//
// In raw mode the camera streams YUY2 frames whose bytes are really
// little-endian 16-bit words: `imageHeight` rows of 14-bit sensor counts
// followed by 4 rows of metadata (calibration constants, sensor
// temperatures, radiometric parameters).

import 'dart:convert';
import 'dart:typed_data';

const int kMetadataRows = 4;
const double kZeroCelsius = 273.15;

/// Per-resolution constants of the temperature model.
class SensorProfile {
  const SensorProfile({
    required this.width,
    required this.fpaOffset,
    required this.fpaDivisor,
    required this.metaBlockStride,
    required this.cal00Offset,
    required this.cal00FpaMultiplier,
  });

  final int width;
  final double fpaOffset;
  final double fpaDivisor;

  /// `amountPixels` in IR-Py-Thermal: distance in words between the frame
  /// statistics block and the calibration block.
  final int metaBlockStride;
  final double cal00Offset;
  final double cal00FpaMultiplier;

  static SensorProfile? forWidth(int width) {
    switch (width) {
      case 256:
        return const SensorProfile(
          width: 256,
          fpaOffset: 8617,
          fpaDivisor: 37.682,
          metaBlockStride: 256,
          cal00Offset: 170,
          cal00FpaMultiplier: 0,
        );
      case 240:
        return const SensorProfile(
          width: 240,
          fpaOffset: 7800,
          fpaDivisor: 36,
          metaBlockStride: 240,
          cal00Offset: 390,
          cal00FpaMultiplier: 7.05,
        );
      case 384:
        return const SensorProfile(
          width: 384,
          fpaOffset: 7800,
          fpaDivisor: 36,
          metaBlockStride: 384 * 3,
          cal00Offset: 390,
          cal00FpaMultiplier: 7.05,
        );
      case 640:
        return const SensorProfile(
          width: 640,
          fpaOffset: 6867,
          fpaDivisor: 33.8,
          metaBlockStride: 640 * 3,
          cal00Offset: 390,
          cal00FpaMultiplier: 7.05,
        );
    }
    return null;
  }
}

/// Values the camera embeds in the 4 metadata rows of every frame.
class T2sMetadata {
  T2sMetadata._({
    required this.fpaAverage,
    required this.fpaRaw,
    required this.maxX,
    required this.maxY,
    required this.maxRaw,
    required this.minX,
    required this.minY,
    required this.minRaw,
    required this.avgRaw,
    required this.centerRaw,
    required this.cal00,
    required this.shutterRaw,
    required this.coreRaw,
    required this.cal01,
    required this.cal02,
    required this.cal03,
    required this.cal04,
    required this.cal05,
    required this.firmwareVersion,
    required this.serialNumber,
    required this.shutterFixRaw,
    required this.correction,
    required this.reflectedTemp,
    required this.airTemp,
    required this.humidity,
    required this.emissivity,
    required this.distance,
  });

  final int fpaAverage;
  final int fpaRaw;
  final int maxX;
  final int maxY;
  final int maxRaw;
  final int minX;
  final int minY;
  final int minRaw;
  final int avgRaw;
  final int centerRaw;

  final int cal00;
  final int shutterRaw;
  final int coreRaw;
  final double cal01;
  final double cal02;
  final double cal03;
  final double cal04;
  final double cal05;
  final String firmwareVersion;
  final String serialNumber;

  /// Word whose upper byte is a signed shutter correction in 0.1 °C (V2).
  final int shutterFixRaw;

  final double correction;
  final double reflectedTemp;
  final double airTemp;
  final double humidity;
  final double emissivity;
  final int distance;

  static T2sMetadata parse(
    Uint16List words,
    ByteData bytes,
    int metaStart,
    SensorProfile profile,
  ) {
    final int stride = profile.metaBlockStride;
    final int calBlock = metaStart + stride;
    final int userArea = metaStart + stride + 127;

    int u16(int index) => words[index];
    double f32(int index) => bytes.getFloat32(index * 2, Endian.little);
    String ascii(int index, int words) {
      final List<int> raw = <int>[];
      for (int i = 0; i < words * 2; i++) {
        final int b = bytes.getUint8(index * 2 + i);
        if (b == 0) break;
        raw.add(b);
      }
      return latin1.decode(raw, allowInvalid: true).trim();
    }

    return T2sMetadata._(
      fpaAverage: u16(metaStart),
      fpaRaw: u16(metaStart + 1),
      maxX: u16(metaStart + 2),
      maxY: u16(metaStart + 3),
      maxRaw: u16(metaStart + 4),
      minX: u16(metaStart + 5),
      minY: u16(metaStart + 6),
      minRaw: u16(metaStart + 7),
      avgRaw: u16(metaStart + 8),
      centerRaw: u16(metaStart + 12),
      cal00: u16(calBlock),
      shutterRaw: u16(calBlock + 1),
      coreRaw: u16(calBlock + 2),
      cal01: f32(calBlock + 3),
      cal02: f32(calBlock + 5),
      cal03: f32(calBlock + 7),
      cal04: f32(calBlock + 9),
      cal05: f32(calBlock + 11),
      firmwareVersion: ascii(calBlock + 24, 8),
      serialNumber: ascii(calBlock + 32, 3),
      shutterFixRaw: u16(metaStart + stride * 2 + 47),
      correction: f32(userArea),
      reflectedTemp: f32(userArea + 2),
      airTemp: f32(userArea + 4),
      humidity: f32(userArea + 6),
      emissivity: f32(userArea + 8),
      distance: u16(userArea + 10),
    );
  }

  /// Focal-plane-array temperature in °C.
  double fpaTemp(SensorProfile profile) =>
      20.0 - (fpaRaw - profile.fpaOffset) / profile.fpaDivisor;

  /// Shutter temperature as V1 units report it (0.1 K).
  double get shutterTempV1 => shutterRaw / 10.0 - kZeroCelsius;

  /// Core temperature as V1 units report it (0.1 K).
  double get coreTempV1 => coreRaw / 10.0 - kZeroCelsius;

  /// Signed correction from the upper byte of [shutterFixRaw], in °C.
  double get shutterFixV2 {
    final int hi = (shutterFixRaw >> 8) & 0xFF;
    return (hi >= 128 ? hi - 256 : hi) / 10.0;
  }

  /// Shutter temperature decoded the way the vendor app does for V2 units.
  /// Known to be unreliable on V2 hardware; the model corrects it with an
  /// offset solved against a reference temperature.
  double get shutterTempV2 {
    double value;
    double factor;
    if (shutterRaw < 2049) {
      value = shutterRaw.toDouble();
      factor = 0.625;
    } else {
      value = (0xFFF - shutterRaw).toDouble();
      factor = -0.625;
    }
    return (value * factor + 2731.5) / 10.0 - kZeroCelsius + shutterFixV2;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'fpaAverage': fpaAverage,
    'fpaRaw': fpaRaw,
    'maxX': maxX,
    'maxY': maxY,
    'maxRaw': maxRaw,
    'minX': minX,
    'minY': minY,
    'minRaw': minRaw,
    'avgRaw': avgRaw,
    'centerRaw': centerRaw,
    'cal00': cal00,
    'shutterRaw': shutterRaw,
    'coreRaw': coreRaw,
    'cal01': cal01,
    'cal02': cal02,
    'cal03': cal03,
    'cal04': cal04,
    'cal05': cal05,
    'firmwareVersion': firmwareVersion,
    'serialNumber': serialNumber,
    'shutterFixRaw': shutterFixRaw,
    'correction': correction,
    'reflectedTemp': reflectedTemp,
    'airTemp': airTemp,
    'humidity': humidity,
    'emissivity': emissivity,
    'distance': distance,
    'shutterTempV1': shutterTempV1,
    'coreTempV1': coreTempV1,
    'shutterTempV2': shutterTempV2,
  };
}

/// Camera families with different stream layouts.
enum CameraFamily {
  /// InfiRay Xtherm line (T2S+, T2L, T3S, HT-301, ...): image rows of sensor
  /// counts plus 4 metadata rows; temperatures from a radiometric model.
  xtherm,

  /// InfiRay Tiny1-C modules (P2 Pro, Topdon TC001, ...): a processed image
  /// on top and a second half of temperatures in 1/64 K below.
  tiny1c,
}

/// Temperatures from cameras that deliver them directly (Tiny1-C) are kept
/// as "counts" on a linear scale, so the rest of the pipeline (statistics,
/// colouring, markers, logging) works the same for every camera:
/// count = (°C + [kLinearOffsetC]) * [kLinearCountsPerC], 0.05 °C steps
/// from -40 °C to about 779 °C.
const double kLinearOffsetC = 40.0;
const double kLinearCountsPerC = 20.0;

int linearCountFor(double celsius) =>
    ((celsius + kLinearOffsetC) * kLinearCountsPerC).round().clamp(0, 16383);

/// One decoded camera frame: sensor counts plus, for Xtherm cameras, the
/// metadata needed by the temperature model.
class T2sFrame {
  T2sFrame._({
    required this.family,
    required this.profile,
    required this.width,
    required this.height,
    required this.counts,
    required this.meta,
    required this.rawBytes,
  });

  final CameraFamily family;

  /// Xtherm sensor constants; null for Tiny1-C frames.
  final SensorProfile? profile;
  final int width;
  final int height;

  /// Sensor counts, row-major, `width * height` entries. For Tiny1-C frames
  /// these are linear temperature counts (see [linearCountFor]).
  final Uint16List counts;

  /// Xtherm metadata rows; null for Tiny1-C frames.
  final T2sMetadata? meta;

  /// The full frame exactly as received, for export.
  final Uint8List rawBytes;

  /// Decodes a YUY2 payload of `frameWidth x frameHeight` (image rows plus
  /// [kMetadataRows]). Returns null when the size does not fit the layout.
  static T2sFrame? decode(Uint8List payload, int frameWidth, int frameHeight) {
    final SensorProfile? profile = SensorProfile.forWidth(frameWidth);
    if (profile == null || frameHeight <= kMetadataRows) return null;
    final int wordCount = frameWidth * frameHeight;
    if (payload.lengthInBytes < wordCount * 2) return null;

    // Copy into a fresh, 2-byte aligned buffer.
    final Uint8List data = Uint8List.fromList(
      payload.sublist(0, wordCount * 2),
    );
    final Uint16List words = data.buffer.asUint16List(0, wordCount);
    final ByteData bytes = data.buffer.asByteData();

    final int imageHeight = frameHeight - kMetadataRows;
    final int imageWords = frameWidth * imageHeight;
    final T2sMetadata meta = T2sMetadata.parse(
      words,
      bytes,
      imageWords,
      profile,
    );
    return T2sFrame._(
      family: CameraFamily.xtherm,
      profile: profile,
      width: frameWidth,
      height: imageHeight,
      counts: Uint16List.fromList(words.sublist(0, imageWords)),
      meta: meta,
      rawBytes: data,
    );
  }

  /// Decodes a Tiny1-C frame of `frameWidth x frameHeight` (two halves of
  /// equal height). The lower half holds little-endian temperatures in
  /// 1/64 K: T(°C) = raw / 64 - 273.15.
  static T2sFrame? decodeTiny1c(
    Uint8List payload,
    int frameWidth,
    int frameHeight,
  ) {
    if (frameHeight.isOdd || frameHeight < 4) return null;
    final int wordCount = frameWidth * frameHeight;
    if (payload.lengthInBytes < wordCount * 2) return null;
    final Uint8List data = Uint8List.fromList(
      payload.sublist(0, wordCount * 2),
    );
    final ByteData bytes = data.buffer.asByteData();
    final int imageHeight = frameHeight ~/ 2;
    final int n = frameWidth * imageHeight;
    final int start = n * 2; // bytes: the upper half is the picture
    final Uint16List counts = Uint16List(n);
    for (int i = 0; i < n; i++) {
      final int raw = bytes.getUint16(start + i * 2, Endian.little);
      counts[i] = linearCountFor(raw / 64.0 - kZeroCelsius);
    }
    return T2sFrame._(
      family: CameraFamily.tiny1c,
      profile: null,
      width: frameWidth,
      height: imageHeight,
      counts: counts,
      meta: null,
      rawBytes: data,
    );
  }
}

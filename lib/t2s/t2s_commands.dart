// Command words for the T2S+ family.
//
// The firmware reuses the standard UVC "Zoom, Absolute" control (camera
// terminal selector 0x0B) as a register-poke channel. Values from
// IR-Py-Thermal (https://github.com/diminDDL/IR-Py-Thermal, GPL-3.0).

import 'dart:typed_data';

abstract final class T2sCommand {
  /// Close the shutter / run flat-field correction. Re-sending it faster
  /// than about once per second keeps the shutter closed.
  static const int shutter = 0x8000;

  /// Switch the stream to 16-bit raw sensor data.
  static const int rawMode = 0x8004;

  /// Measurement range -20..120 °C.
  static const int rangeNormal = 0x8020;

  /// Measurement range 120..450 °C.
  static const int rangeHigh = 0x8021;

  /// Commit radiometric parameters. Without this the camera keeps a
  /// factory default emissivity of 0.02 and the model yields NaN.
  static const int saveParameters = 0x80FF;
}

/// Byte offsets of the radiometric parameters written via [encodeFloat].
abstract final class T2sParameter {
  static const int correction = 0 * 4;
  static const int reflectedTemp = 1 * 4;
  static const int airTemp = 2 * 4;
  static const int humidity = 3 * 4;
  static const int emissivity = 4 * 4;
  static const int distance = 5 * 4;
}

/// Splits a float parameter into the four zoom writes the camera expects:
/// `(position + i) << 8 | byte_i`.
List<int> encodeFloat(int position, double value) {
  final ByteData data = ByteData(4)..setFloat32(0, value, Endian.little);
  return <int>[
    for (int i = 0; i < 4; i++) ((position + i) << 8) | data.getUint8(i),
  ];
}

/// Splits a 16-bit parameter into the two zoom writes the camera expects.
List<int> encodeUint16(int position, int value) {
  return <int>[
    (position << 8) | (value & 0xFF),
    ((position + 1) << 8) | ((value >> 8) & 0xFF),
  ];
}

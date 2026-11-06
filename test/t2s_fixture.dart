import 'dart:typed_data';

/// Builds a synthetic 256x196 frame with the given metadata fields at the
/// word offsets the T2S+ uses.
Uint8List buildFrame({
  int imageValue = 9000,
  int fpaRaw = 8617,
  int cal00 = 8000,
  int shutterRaw = 3000,
  int coreRaw = 3000,
  int shutterFixRaw = 0,
  double cal01 = 0.25,
  double cal02 = 30,
  double cal03 = -0.00001,
  double cal04 = 0.01,
  double cal05 = 1.0,
  double correction = 0,
  double reflected = 20,
  double air = 20,
  double humidity = 0,
  double emissivity = 0.95,
  int distance = 1,
  String firmware = '',
}) {
  const int w = 256;
  const int words = w * 196;
  const int base = w * 192;
  final ByteData d = ByteData(words * 2);
  void u16(int index, int v) => d.setUint16(index * 2, v, Endian.little);
  void f32(int index, double v) =>
      d.setFloat32(index * 2, v, Endian.little);

  for (int i = 0; i < base; i++) {
    u16(i, imageValue);
  }
  u16(base + 1, fpaRaw);
  u16(base + 256, cal00);
  u16(base + 257, shutterRaw);
  u16(base + 258, coreRaw);
  f32(base + 259, cal01);
  f32(base + 261, cal02);
  f32(base + 263, cal03);
  f32(base + 265, cal04);
  f32(base + 267, cal05);
  for (int i = 0; i < firmware.length; i++) {
    d.setUint8((base + 280) * 2 + i, firmware.codeUnitAt(i));
  }
  u16(base + 559, shutterFixRaw);
  f32(base + 383, correction);
  f32(base + 385, reflected);
  f32(base + 387, air);
  f32(base + 389, humidity);
  f32(base + 391, emissivity);
  u16(base + 393, distance);
  return d.buffer.asUint8List();
}

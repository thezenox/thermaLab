// Vendor commands for InfiRay Tiny1-C modules (P2 Pro, Topdon TC001).
//
// Reverse-engineered by P2Pro-Viewer (https://github.com/LeoDJ/P2Pro-Viewer):
// commands are vendor control transfers (request 0x45 out, 0x44 in, value
// 0x78) addressed through wIndex; after each command the module is polled
// until it reports ready.

import 'dart:typed_data';

/// Sends one USB control transfer; returns the data read for IN requests.
typedef ControlTransfer = Uint8List Function({
  required int requestType,
  required int request,
  required int value,
  required int index,
  Uint8List? data,
  int length,
  int timeoutMs,
});

abstract final class Tiny1cCmd {
  static const int set = 0x4000;
  static const int propTpdParams = 0x8514;
}

/// Parameters of [Tiny1cCmd.propTpdParams].
abstract final class Tiny1cTpd {
  /// 1/127 steps, 0..127.
  static const int emissivity = 3;

  /// 1 = high gain (normal range), 0 = low gain (high temperature range).
  static const int gainSelect = 5;
}

class Tiny1cCommands {
  Tiny1cCommands(this.transfer);

  final ControlTransfer transfer;

  bool _ready() {
    final Uint8List r = transfer(
      requestType: 0xC1,
      request: 0x44,
      value: 0x78,
      index: 0x200,
      length: 1,
    );
    if (r.isEmpty) return false;
    if (r[0] & 0xFC != 0) {
      throw StateError('camera reports error 0x${r[0].toRadixString(16)}');
    }
    return r[0] & 0x03 == 0;
  }

  Future<void> _waitReady({Duration timeout = const Duration(seconds: 2)}) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!_ready()) {
      if (sw.elapsed > timeout) throw StateError('camera not ready');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// "Long command write": command code plus four parameters.
  Future<void> longWrite(int cmd, int p1, int p2, [int p3 = 0, int p4 = 0]) async {
    final ByteData d1 = ByteData(8)
      ..setUint16(0, cmd, Endian.little)
      ..setUint16(2, p1, Endian.big)
      ..setUint32(4, p2, Endian.big);
    final ByteData d2 = ByteData(8)
      ..setUint32(0, p3, Endian.big)
      ..setUint32(4, p4, Endian.big);
    transfer(
      requestType: 0x41,
      request: 0x45,
      value: 0x78,
      index: 0x9d00,
      data: d1.buffer.asUint8List(),
    );
    transfer(
      requestType: 0x41,
      request: 0x45,
      value: 0x78,
      index: 0x1d08,
      data: d2.buffer.asUint8List(),
    );
    await _waitReady();
  }

  /// High gain = normal range (about -20..150 °C), low gain = high range.
  Future<void> setHighGain(bool high) => longWrite(
    Tiny1cCmd.propTpdParams | Tiny1cCmd.set,
    Tiny1cTpd.gainSelect,
    high ? 1 : 0,
  );

  Future<void> setEmissivity(double e) => longWrite(
    Tiny1cCmd.propTpdParams | Tiny1cCmd.set,
    Tiny1cTpd.emissivity,
    (e.clamp(0.01, 1.0) * 127).round(),
  );
}

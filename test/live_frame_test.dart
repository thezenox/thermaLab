import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/capture/live_server.dart';

void main() {
  test('frame message holds header JSON and aligned temperature grid', () {
    final Int16List temps = Int16List.fromList(<int>[1000, -32768, 2500]);
    for (final String pad in <String>['', 'x']) {
      final Map<String, Object?> header = <String, Object?>{'w': 3, 'p': pad};
      final Uint8List msg = encodeFrame(header, temps);
      final int len = ByteData.sublistView(msg).getUint32(0, Endian.little);
      expect(jsonDecode(utf8.decode(msg.sublist(4, 4 + len))), header);
      final int start = 4 + len + ((4 + len) % 2);
      final Int16List decoded = msg.buffer.asByteData(start).buffer
          .asInt16List(start, 3);
      expect(decoded, temps);
    }
  });

  test('row-delta coding round-trips in 0.1 °C', () {
    // 1/50 °C input: 20.00, 20.10, (no value), 21.00 | 30.00, 29.90
    final Int16List grid = Int16List.fromList(<int>[1000, 1005, -32768, 1050, 1500, 1495, 1495, 1495]);
    final Int16List coded = deltaEncodeTenths(grid, 4);
    final List<int> decoded = <int>[];
    for (int row = 0; row < coded.length; row += 4) {
      int acc = 0;
      for (int i = row; i < row + 4; i++) {
        acc = i == row ? coded[i] : acc + coded[i];
        decoded.add(acc);
      }
    }
    expect(decoded, <int>[200, 201, 201, 210, 300, 299, 299, 299]);
  });
}

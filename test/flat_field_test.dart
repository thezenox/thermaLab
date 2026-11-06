import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/t2s/flat_field.dart';

void main() {
  test('removes a warm-edge pattern and keeps the centre level', () {
    const int w = 256;
    const int h = 192;
    // Uniform scene at 6000 counts plus edges up to ~80 counts warmer.
    Uint16List frame(int seed) {
      final math.Random r = math.Random(seed);
      return Uint16List.fromList(<int>[
        for (int y = 0; y < h; y++)
          for (int x = 0; x < w; x++)
            (6000 +
                    80 *
                        (math.pow((2 * x + 1) / w - 1, 2) +
                            math.pow((2 * y + 1) / h - 1, 2)) /
                        2 +
                    r.nextInt(7) -
                    3)
                .round(),
      ]);
    }

    final FlatField ff = FlatField.fit(<Uint16List>[
      for (int i = 0; i < 5; i++) frame(i),
    ], w, h)!;
    expect(ff.maxOffset, closeTo(80, 5));

    final Uint16List out = ff.apply(frame(42));
    double at(int x, int y) => out[y * w + x].toDouble();
    expect(at(w ~/ 2, h ~/ 2), closeTo(6000, 4));
    expect(at(0, 0), closeTo(6000, 5));
    expect(at(w - 1, h - 1), closeTo(6000, 5));

    final FlatField copy = FlatField.fromCoefficients(w, h, ff.coefficients)!;
    expect(copy.offset[0], closeTo(ff.offset[0], 1e-6));
  });
}

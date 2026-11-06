import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/render/geometry.dart';

void main() {
  test('quarter turn moves the top-left corner to the top-right', () {
    expect(sensorToDisplay(0, 0, 1), (1.0, 0.0));
    expect(sensorToDisplay(1, 0, 1), (1.0, 1.0));
  });

  test('display and sensor mappings are inverse for every rotation', () {
    for (int turns = 0; turns < 4; turns++) {
      for (final (double, double) p in <(double, double)>[
        (0.1, 0.2),
        (0.9, 0.3),
        (0.5, 0.5),
      ]) {
        final (double a, double b) = sensorToDisplay(p.$1, p.$2, turns);
        final (double u, double v) = displayToSensor(a, b, turns);
        expect(u, closeTo(p.$1, 1e-12), reason: 'turns $turns');
        expect(v, closeTo(p.$2, 1e-12), reason: 'turns $turns');
        final (double ma, double mb) =
            sensorToDisplay(p.$1, p.$2, turns, mirror: true);
        expect(ma, closeTo(1 - a, 1e-12));
        expect(mb, closeTo(b, 1e-12));
        final (double mu, double mv) =
            displayToSensor(ma, mb, turns, mirror: true);
        expect(mu, closeTo(p.$1, 1e-12));
        expect(mv, closeTo(p.$2, 1e-12));
      }
    }
  });
}

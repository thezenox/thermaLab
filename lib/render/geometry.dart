/// Maps normalised sensor coordinates to the display after rotating the
/// image clockwise by [turns] quarter turns and, if [mirror] is set,
/// flipping it horizontally.
(double, double) sensorToDisplay(
  double u,
  double v,
  int turns, {
  bool mirror = false,
}) {
  final (double a, double b) = switch (turns % 4) {
    1 => (1 - v, u),
    2 => (1 - u, 1 - v),
    3 => (v, 1 - u),
    _ => (u, v),
  };
  return mirror ? (1 - a, b) : (a, b);
}

/// Inverse of [sensorToDisplay].
(double, double) displayToSensor(
  double a,
  double b,
  int turns, {
  bool mirror = false,
}) {
  if (mirror) a = 1 - a;
  return switch (turns % 4) {
    1 => (b, 1 - a),
    2 => (1 - a, 1 - b),
    3 => (1 - b, a),
    _ => (a, b),
  };
}

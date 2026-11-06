// Lens shading ("vignetting") correction.
//
// The shutter sits behind the lens, so shutter correction cannot remove
// the warm-edge pattern caused by the lens and its housing. Looking at a
// uniform surface shows that pattern; a smooth polynomial surface fitted to
// it is subtracted from every frame, relative to the image centre, so the
// centre readings stay as they are.

import 'dart:math' as math;
import 'dart:typed_data';

class FlatField {
  FlatField._(this.width, this.height, this.coefficients)
    : offset = _evaluate(width, height, coefficients);

  final int width;
  final int height;

  /// Coefficients of the polynomial in normalised coordinates (x, y in
  /// -1..1), terms ordered as in [_terms].
  final List<double> coefficients;

  /// Per-pixel offset in counts, zero at the image centre.
  final Float32List offset;

  /// Polynomial degree of the fitted surface.
  static const int degree = 4;

  /// Exponent pairs (i, j) of x^i * y^j with i + j <= [degree].
  static final List<(int, int)> _terms = <(int, int)>[
    for (int d = 0; d <= degree; d++)
      for (int i = d; i >= 0; i--) (i, d - i),
  ];

  /// Fits the surface to the average of [frames] (counts after shutter
  /// correction, all looking at a uniform surface).
  static FlatField? fit(List<Uint16List> frames, int width, int height) {
    if (frames.isEmpty) return null;
    final int n = width * height;
    final Float64List mean = Float64List(n);
    for (final Uint16List f in frames) {
      for (int i = 0; i < n; i++) {
        mean[i] += f[i];
      }
    }
    for (int i = 0; i < n; i++) {
      mean[i] /= frames.length;
    }

    // Least squares via normal equations on a subsample of pixels.
    final int m = _terms.length;
    final List<Float64List> ata =
        List<Float64List>.generate(m, (_) => Float64List(m));
    final Float64List atb = Float64List(m);
    final Float64List row = Float64List(m);
    for (int y = 0; y < height; y += 2) {
      for (int x = 0; x < width; x += 2) {
        _fillRow(row, _nx(x, width), _ny(y, height));
        final double v = mean[y * width + x];
        for (int a = 0; a < m; a++) {
          atb[a] += row[a] * v;
          for (int b = 0; b < m; b++) {
            ata[a][b] += row[a] * row[b];
          }
        }
      }
    }
    final List<double>? c = _solve(ata, atb);
    if (c == null) return null;
    return FlatField._(width, height, c);
  }

  static FlatField? fromCoefficients(int width, int height, List<double> c) {
    if (c.length != _terms.length) return null;
    return FlatField._(width, height, c);
  }

  /// Largest correction (counts) anywhere in the image.
  double get maxOffset =>
      offset.fold(0.0, (double a, double v) => math.max(a, v.abs()));

  Uint16List apply(Uint16List counts) {
    final Uint16List out = Uint16List(counts.length);
    for (int i = 0; i < counts.length; i++) {
      out[i] = (counts[i] - offset[i]).round().clamp(0, 16383);
    }
    return out;
  }

  static double _nx(int x, int w) => (2 * x + 1) / w - 1;
  static double _ny(int y, int h) => (2 * y + 1) / h - 1;

  static void _fillRow(Float64List row, double x, double y) {
    for (int t = 0; t < _terms.length; t++) {
      final (int i, int j) = _terms[t];
      row[t] = _pow(x, i) * _pow(y, j);
    }
  }

  static double _pow(double v, int e) {
    double r = 1;
    for (int k = 0; k < e; k++) {
      r *= v;
    }
    return r;
  }

  static Float32List _evaluate(int w, int h, List<double> c) {
    final Float64List row = Float64List(_terms.length);
    double surface(double x, double y) {
      _fillRow(row, x, y);
      double s = 0;
      for (int t = 0; t < row.length; t++) {
        s += row[t] * c[t];
      }
      return s;
    }

    final double centre = surface(0, 0);
    final Float32List out = Float32List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        out[y * w + x] = surface(_nx(x, w), _ny(y, h)) - centre;
      }
    }
    return out;
  }

  /// Gaussian elimination with partial pivoting.
  static List<double>? _solve(List<Float64List> a, Float64List b) {
    final int n = b.length;
    final List<Float64List> m = <Float64List>[
      for (int i = 0; i < n; i++) Float64List.fromList(<double>[...a[i], b[i]]),
    ];
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
      }
      if (m[pivot][col].abs() < 1e-12) return null;
      final Float64List tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final double f = m[r][col] / m[col][col];
        if (f == 0) continue;
        for (int k = col; k <= n; k++) {
          m[r][k] -= f * m[col][k];
        }
      }
    }
    return <double>[for (int i = 0; i < n; i++) m[i][n] / m[i][i]];
  }
}

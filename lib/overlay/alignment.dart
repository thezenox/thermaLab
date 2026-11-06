// Image maths for the camera overlay: edge maps and the search that finds
// where the thermal image sits inside the phone camera picture.
//
// All maps are row-major Float32Lists in display orientation.

import 'dart:math' as math;
import 'dart:typed_data';

/// A grey-value or edge map.
class Plane {
  Plane(this.width, this.height, this.data)
    : assert(data.length == width * height);

  Plane.zero(this.width, this.height) : data = Float32List(width * height);

  final int width;
  final int height;
  final Float32List data;

  double at(int x, int y) => data[y * width + x];

  /// Bilinear resample to [w] x [h].
  Plane resize(int w, int h, {bool mirror = false}) {
    final Plane out = Plane.zero(w, h);
    final double sx = width / w;
    final double sy = height / h;
    for (int y = 0; y < h; y++) {
      final double fy = math.min((y + 0.5) * sy - 0.5, height - 1.0).clamp(0.0, height - 1.0);
      final int y0 = fy.floor();
      final int y1 = math.min(y0 + 1, height - 1);
      final double wy = fy - y0;
      for (int x = 0; x < w; x++) {
        final int xx = mirror ? w - 1 - x : x;
        final double fx = ((xx + 0.5) * sx - 0.5).clamp(0.0, width - 1.0);
        final int x0 = fx.floor();
        final int x1 = math.min(x0 + 1, width - 1);
        final double wx = fx - x0;
        final double top = at(x0, y0) * (1 - wx) + at(x1, y0) * wx;
        final double bottom = at(x0, y1) * (1 - wx) + at(x1, y1) * wx;
        out.data[y * w + x] = top * (1 - wy) + bottom * wy;
      }
    }
    return out;
  }

  /// Sobel gradient magnitude.
  Plane edges() {
    final Plane out = Plane.zero(width, height);
    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        final double gx = at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1) -
            at(x - 1, y - 1) - 2 * at(x - 1, y) - at(x - 1, y + 1);
        final double gy = at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1) -
            at(x - 1, y - 1) - 2 * at(x, y - 1) - at(x + 1, y - 1);
        out.data[y * width + x] = math.sqrt(gx * gx + gy * gy);
      }
    }
    return out;
  }

  /// Value below which [q] of all entries lie (approximate, by sampling).
  double percentile(double q) {
    final int step = math.max(1, data.length ~/ 4096);
    final List<double> sample = <double>[
      for (int i = 0; i < data.length; i += step) data[i],
    ]..sort();
    return sample[(q * (sample.length - 1)).round()];
  }
}

/// Where the thermal image lies in the camera picture: centre and width as
/// fractions of the camera picture, height follows from the thermal aspect.
class OverlayAlignment {
  const OverlayAlignment({
    required this.centerX,
    required this.centerY,
    required this.width,
    this.mirrored = false,
    this.score = 0,
  });

  /// Uncalibrated guess: thermal field of view about 60 % of the camera's.
  static const OverlayAlignment initial = OverlayAlignment(
    centerX: 0.5,
    centerY: 0.5,
    width: 0.6,
  );

  final double centerX;
  final double centerY;
  final double width;

  /// The thermal image is mirrored relative to the camera.
  final bool mirrored;

  /// Normalised cross-correlation of the match (0..1, higher is better).
  final double score;

  OverlayAlignment copyWith({double? centerX, double? centerY, double? score}) =>
      OverlayAlignment(
        centerX: centerX ?? this.centerX,
        centerY: centerY ?? this.centerY,
        width: width,
        mirrored: mirrored,
        score: score ?? this.score,
      );

  Map<String, Object> toJson() => <String, Object>{
    'cx': centerX,
    'cy': centerY,
    'w': width,
    'mirrored': mirrored,
    'score': score,
  };

  static OverlayAlignment? fromJson(Map<String, dynamic> j) {
    final num? cx = j['cx'] as num?;
    final num? cy = j['cy'] as num?;
    final num? w = j['w'] as num?;
    if (cx == null || cy == null || w == null) return null;
    return OverlayAlignment(
      centerX: cx.toDouble(),
      centerY: cy.toDouble(),
      width: w.toDouble(),
      mirrored: j['mirrored'] == true,
      score: (j['score'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Best placement of a template inside an image.
class _Match {
  _Match(this.x, this.y, this.w, this.h, this.score);
  final int x;
  final int y;
  final int w;
  final int h;
  final double score;
}

/// Summed-area tables for fast window means and variances.
class _Integral {
  _Integral(Plane p)
    : w = p.width + 1,
      sum = Float64List((p.width + 1) * (p.height + 1)),
      sq = Float64List((p.width + 1) * (p.height + 1)) {
    for (int y = 0; y < p.height; y++) {
      double rowSum = 0;
      double rowSq = 0;
      for (int x = 0; x < p.width; x++) {
        final double v = p.data[y * p.width + x];
        rowSum += v;
        rowSq += v * v;
        sum[(y + 1) * w + x + 1] = sum[y * w + x + 1] + rowSum;
        sq[(y + 1) * w + x + 1] = sq[y * w + x + 1] + rowSq;
      }
    }
  }

  final int w;
  final Float64List sum;
  final Float64List sq;

  double _box(Float64List t, int x, int y, int bw, int bh) =>
      t[(y + bh) * w + x + bw] - t[y * w + x + bw] - t[(y + bh) * w + x] + t[y * w + x];

  (double, double) meanVar(int x, int y, int bw, int bh) {
    final double n = (bw * bh).toDouble();
    final double m = _box(sum, x, y, bw, bh) / n;
    return (m, math.max(0.0, _box(sq, x, y, bw, bh) / n - m * m));
  }
}

/// Zero-mean, unit-norm copy of [t] (null when it has no contrast).
Float32List? _normalised(Plane t) {
  double mean = 0;
  for (final double v in t.data) {
    mean += v;
  }
  mean /= t.data.length;
  double norm = 0;
  final Float32List out = Float32List(t.data.length);
  for (int i = 0; i < out.length; i++) {
    final double v = t.data[i] - mean;
    out[i] = v;
    norm += v * v;
  }
  if (norm < 1e-9) return null;
  final double inv = 1 / math.sqrt(norm);
  for (int i = 0; i < out.length; i++) {
    out[i] *= inv;
  }
  return out;
}

/// Normalised cross-correlation of template [t] (normalised, tw x th)
/// placed at (x, y) in [img].
double _ncc(Plane img, _Integral integral, Float32List t, int tw, int th, int x, int y) {
  final (double _, double variance) = integral.meanVar(x, y, tw, th);
  if (variance < 1e-9) return -1;
  double dot = 0;
  for (int ty = 0; ty < th; ty++) {
    final int row = (y + ty) * img.width + x;
    final int trow = ty * tw;
    for (int tx = 0; tx < tw; tx++) {
      dot += t[trow + tx] * img.data[row + tx];
    }
  }
  // The template has zero mean, so the image mean drops out of the dot
  // product; only its standard deviation is needed.
  return dot / math.sqrt(variance * tw * th);
}

_Match? _search(
  Plane img,
  Plane thermal,
  double aspect, {
  required int minW,
  required int maxW,
  int wStep = 1,
  int? x0,
  int? x1,
  int? y0,
  int? y1,
  bool mirror = false,
}) {
  final _Integral integral = _Integral(img);
  _Match? best;
  for (int tw = minW; tw <= maxW; tw += wStep) {
    final int th = (tw / aspect).round();
    if (tw > img.width || th > img.height || tw < 8 || th < 8) continue;
    final Float32List? t = _normalised(thermal.resize(tw, th, mirror: mirror));
    if (t == null) return null;
    final int xa = math.max(0, x0 ?? 0);
    final int xb = math.min(img.width - tw, x1 ?? img.width - tw);
    final int ya = math.max(0, y0 ?? 0);
    final int yb = math.min(img.height - th, y1 ?? img.height - th);
    for (int y = ya; y <= yb; y++) {
      for (int x = xa; x <= xb; x++) {
        final double s = _ncc(img, integral, t, tw, th, x, y);
        if (best == null || s > best.score) best = _Match(x, y, tw, th, s);
      }
    }
  }
  return best;
}

/// Input for [calibrate], kept in plain data so it can run in an isolate.
class CalibrationInput {
  CalibrationInput({
    required this.camera,
    required this.thermal,
  });

  /// Camera grey image in display orientation.
  final Plane camera;

  /// Thermal image (temperatures or counts) in display orientation.
  final Plane thermal;
}

/// Finds scale, position and mirroring of the thermal image inside the
/// camera picture by matching edge maps: a coarse exhaustive search, then
/// a refinement at higher resolution. Returns null without usable contrast.
OverlayAlignment? calibrate(CalibrationInput input) {
  final double aspect = input.thermal.width / input.thermal.height;
  Plane edgeMap(Plane p, int w, int h) {
    final Plane e = p.resize(w, h).edges();
    // Compress strong edges so a single hot object does not dominate.
    final double cap = math.max(e.percentile(0.98), 1e-6);
    for (int i = 0; i < e.data.length; i++) {
      e.data[i] = math.min(e.data[i], cap) / cap;
    }
    return e;
  }

  final Plane camCoarse = edgeMap(input.camera, 60, (60 * input.camera.height / input.camera.width).round());
  final Plane camFine = edgeMap(input.camera, 120, (120 * input.camera.height / input.camera.width).round());
  final Plane thermalEdges = edgeMap(input.thermal, 64, (64 / aspect).round());

  _Match? best;
  bool bestMirrored = false;
  for (final bool mirror in <bool>[false, true]) {
    final _Match? m = _search(
      camCoarse,
      thermalEdges,
      aspect,
      // The thermal field of view is wide; small matches (strong zoom) are
      // usually false close-up hits, so the search starts at 45 %.
      minW: (camCoarse.width * 0.45).round(),
      maxW: camCoarse.width,
      mirror: mirror,
    );
    if (m != null && (best == null || m.score > best.score)) {
      best = m;
      bestMirrored = mirror;
    }
  }
  if (best == null) return null;

  // Refine around the coarse result at twice the resolution.
  final double k = camFine.width / camCoarse.width;
  final _Match? fine = _search(
    camFine,
    thermalEdges,
    aspect,
    minW: ((best.w - 2) * k).round(),
    maxW: ((best.w + 2) * k).round(),
    x0: ((best.x - 2) * k).round(),
    x1: ((best.x + 2) * k).round(),
    y0: ((best.y - 2) * k).round(),
    y1: ((best.y + 2) * k).round(),
    mirror: bestMirrored,
  );
  final _Match m = fine ?? best;
  final Plane ref = fine != null ? camFine : camCoarse;
  return OverlayAlignment(
    centerX: (m.x + m.w / 2) / ref.width,
    centerY: (m.y + m.h / 2) / ref.height,
    width: m.w / ref.width,
    mirrored: bestMirrored,
    score: m.score,
  );
}

/// Re-finds only the position (parallax changes with distance) within
/// [maxShift] of [around], keeping the calibrated scale.
OverlayAlignment? trackPosition(
  CalibrationInput input,
  OverlayAlignment around, {
  double maxShift = 0.08,
}) {
  final double aspect = input.thermal.width / input.thermal.height;
  const int camW = 96;
  final int camH = (camW * input.camera.height / input.camera.width).round();
  Plane edgeMap(Plane p, int w, int h) {
    final Plane e = p.resize(w, h).edges();
    final double cap = math.max(e.percentile(0.98), 1e-6);
    for (int i = 0; i < e.data.length; i++) {
      e.data[i] = math.min(e.data[i], cap) / cap;
    }
    return e;
  }

  final Plane cam = edgeMap(input.camera, camW, camH);
  final Plane thermal = edgeMap(input.thermal, 48, (48 / aspect).round());
  final int tw = (around.width * camW).round();
  final int th = (tw / aspect).round();
  final int cx = (around.centerX * camW - tw / 2).round();
  final int cy = (around.centerY * camH - th / 2).round();
  final int dx = (maxShift * camW).round();
  final int dy = (maxShift * camH).round();
  final _Match? m = _search(
    cam,
    thermal,
    aspect,
    minW: tw,
    maxW: tw,
    x0: cx - dx,
    x1: cx + dx,
    y0: cy - dy,
    y1: cy + dy,
    mirror: around.mirrored,
  );
  if (m == null) return null;
  return around.copyWith(
    centerX: (m.x + m.w / 2) / camW,
    centerY: (m.y + m.h / 2) / camH,
    score: m.score,
  );
}

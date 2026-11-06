// Software non-uniformity correction for V2 units, which stream uncorrected
// sensor counts. With the shutter closed every pixel sees the same
// temperature, so the closed-shutter frame is the per-pixel offset pattern.
//
// Approach from IR-Py-Thermal and t2s-thermal-macos: subtract the averaged
// reference frame, add back its mean, and repair the few dead pixels.

import 'dart:math' as math;
import 'dart:typed_data';

import 'temperature_model.dart';

class ShutterCorrection {
  ShutterCorrection._(
    this.width,
    this.height,
    this.reference,
    this.referenceMean,
    this.deadPixels,
  );

  final int width;
  final int height;
  final Float32List reference;
  final double referenceMean;

  /// Indices of pixels treated as dead, empty if none or implausibly many.
  final List<int> deadPixels;

  /// More flagged pixels than this means the shutter was not fully closed
  /// and scene content was mistaken for defects.
  static const int maxPlausibleDeadPixels = 50;

  static ShutterCorrection fromFrames(
    List<Uint16List> frames,
    int width,
    int height,
  ) {
    if (frames.isEmpty) {
      throw ArgumentError('ShutterCorrection needs at least one frame');
    }
    final int n = width * height;
    final Float32List reference = Float32List(n);
    for (final Uint16List f in frames) {
      for (int i = 0; i < n; i++) {
        reference[i] += f[i];
      }
    }
    double sum = 0;
    double minV = double.infinity;
    double maxV = -double.infinity;
    for (int i = 0; i < n; i++) {
      final double v = reference[i] / frames.length;
      reference[i] = v;
      sum += v;
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
    final double threshold = minV + (maxV - minV) * 0.05;
    final List<int> dead = <int>[
      for (int i = 0; i < n; i++)
        if (reference[i] < threshold) i,
    ];
    return ShutterCorrection._(
      width,
      height,
      reference,
      sum / n,
      dead.length <= maxPlausibleDeadPixels ? dead : const <int>[],
    );
  }

  /// Removes the per-pixel pattern. The closed-shutter level ends up at
  /// [level] (default: the reference mean, which drifts with sensor
  /// temperature).
  Uint16List apply(Uint16List counts, {double? level}) {
    final int n = width * height;
    final Uint16List out = Uint16List(n);
    final double anchor = level ?? referenceMean;
    for (int i = 0; i < n; i++) {
      final double v = counts[i] - reference[i] + anchor;
      out[i] = v.round().clamp(0, kTableSize - 1);
    }
    for (final int i in deadPixels) {
      out[i] = _neighbourMean(out, i);
    }
    return out;
  }

  int _neighbourMean(Uint16List img, int index) {
    final Set<int> dead = deadPixels.toSet();
    final int x0 = index % width;
    final int y0 = index ~/ width;
    int sum = 0;
    int count = 0;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        final int x = x0 + dx;
        final int y = y0 + dy;
        if ((dx == 0 && dy == 0) || x < 0 || y < 0 || x >= width || y >= height) {
          continue;
        }
        final int j = y * width + x;
        if (dead.contains(j)) continue;
        sum += img[j];
        count++;
      }
    }
    return count == 0 ? img[index] : sum ~/ count;
  }
}

double countsMean(Uint16List counts) {
  double sum = 0;
  for (final int v in counts) {
    sum += v;
  }
  return sum / counts.length;
}

/// Standard deviation of 16x16 block means: the coarse scene structure,
/// insensitive to pixel- and column-level fixed-pattern noise. Near zero
/// when the shutter covers the sensor.
double blockStdDev(List<int> counts, int width, int height, {int block = 16}) {
  final List<double> means = <double>[];
  for (int by = 0; by + block <= height; by += block) {
    for (int bx = 0; bx + block <= width; bx += block) {
      double sum = 0;
      for (int y = by; y < by + block; y++) {
        final int row = y * width;
        for (int x = bx; x < bx + block; x++) {
          sum += counts[row + x];
        }
      }
      means.add(sum / (block * block));
    }
  }
  if (means.isEmpty) return double.nan;
  final double mean = means.reduce((double a, double b) => a + b) / means.length;
  double sq = 0;
  for (final double m in means) {
    sq += (m - mean) * (m - mean);
  }
  return math.sqrt(sq / means.length);
}

/// Standard deviation of the counts.
double countsStdDev(Uint16List counts) {
  double sum = 0;
  double sumSq = 0;
  for (final int v in counts) {
    sum += v;
    sumSq += v.toDouble() * v;
  }
  final double mean = sum / counts.length;
  return math.sqrt(math.max(0, sumSq / counts.length - mean * mean));
}

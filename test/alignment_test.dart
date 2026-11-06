import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/overlay/alignment.dart';

/// A camera-like picture with a few blocks and a disc.
Plane scene(int w, int h) {
  final Plane p = Plane.zero(w, h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      double v = 60;
      if (x > 50 && x < 120 && y > 70 && y < 150) v = 200;
      if (x > 140 && x < 200 && y > 180 && y < 260) v = 140;
      if (math.pow(x - 110, 2) + math.pow(y - 230, 2) < 900) v = 230;
      if (x > 30 && x < 60 && y > 200 && y < 300) v = 20;
      p.data[y * w + x] = v;
    }
  }
  return p;
}

/// Cuts the region (cx, cy, width as fractions) out of [cam] and scales it
/// to a 192x256 "thermal" picture, optionally mirrored.
Plane crop(Plane cam, double cx, double cy, double width, {bool mirror = false}) {
  const int tw = 192;
  const int th = 256;
  final double w = width * cam.width;
  final double h = w * th / tw;
  final double x0 = cx * cam.width - w / 2;
  final double y0 = cy * cam.height - h / 2;
  final Plane out = Plane.zero(tw, th);
  for (int y = 0; y < th; y++) {
    for (int x = 0; x < tw; x++) {
      final int sx = (x0 + (x + 0.5) * w / tw).floor().clamp(0, cam.width - 1);
      final int sy = (y0 + (y + 0.5) * h / th).floor().clamp(0, cam.height - 1);
      final int tx = mirror ? tw - 1 - x : x;
      out.data[y * tw + tx] = cam.data[sy * cam.width + sx];
    }
  }
  return out;
}

void main() {
  final Plane cam = scene(240, 320);

  for (final bool mirror in <bool>[false, true]) {
    test('calibration finds a ${mirror ? 'mirrored ' : ''}crop', () {
      final OverlayAlignment? a = calibrate(
        CalibrationInput(
          camera: cam,
          thermal: crop(cam, 0.48, 0.56, 0.62, mirror: mirror),
        ),
      );
      expect(a, isNotNull);
      expect(a!.mirrored, mirror);
      expect(a.centerX, closeTo(0.48, 0.03));
      expect(a.centerY, closeTo(0.56, 0.03));
      expect(a.width, closeTo(0.62, 0.04));
      expect(a.score, greaterThan(0.5));
    });
  }

  test('tracking follows a shifted crop at fixed scale', () {
    const OverlayAlignment calibrated = OverlayAlignment(
      centerX: 0.5,
      centerY: 0.5,
      width: 0.6,
    );
    final OverlayAlignment? t = trackPosition(
      CalibrationInput(camera: cam, thermal: crop(cam, 0.52, 0.56, 0.6)),
      calibrated,
    );
    expect(t, isNotNull);
    expect(t!.centerX, closeTo(0.52, 0.02));
    expect(t.centerY, closeTo(0.56, 0.02));
    expect(t.width, 0.6);
  });
}

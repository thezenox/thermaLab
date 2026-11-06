import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../probe/probe_controller.dart';
import '../render/geometry.dart';
import 'alignment.dart';
import 'overlay_feature.dart';
import 'visible_camera.dart';

/// Connects the phone camera with the thermal stream: calibration and the
/// continuous parallax tracking of the overlay.
class OverlayEngine {
  OverlayEngine(this.controller, this.camera) {
    if (kCameraOverlayEnabled) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => _track(),
      );
    }
  }

  final ProbeController controller;
  final VisibleCamera camera;
  Timer? _timer;
  bool _tracking = false;

  /// Thermal counts resampled into display orientation (rotation and mirror
  /// as shown on screen), or null without a frame.
  Plane? thermalDisplayPlane() {
    final f = controller.frame;
    final Uint16List? counts = controller.processedCounts;
    if (f == null || counts == null) return null;
    final int turns = controller.quarterTurns;
    final bool odd = turns.isOdd;
    final int w = odd ? f.height : f.width;
    final int h = odd ? f.width : f.height;
    final Plane out = Plane.zero(w, h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final (double u, double v) = displayToSensor(
          (x + 0.5) / w,
          (y + 0.5) / h,
          turns,
          mirror: controller.mirror,
        );
        final int sx = (u * f.width).floor().clamp(0, f.width - 1);
        final int sy = (v * f.height).floor().clamp(0, f.height - 1);
        out.data[y * w + x] = counts[sy * f.width + sx].toDouble();
      }
    }
    return out;
  }

  CalibrationInput? _input() {
    final Plane? cam = camera.greyPlane;
    final Plane? thermal = thermalDisplayPlane();
    if (cam == null || thermal == null) return null;
    return CalibrationInput(camera: cam, thermal: thermal);
  }

  /// Runs the full calibration in a background isolate.
  Future<OverlayAlignment?> calibrateNow() async {
    final CalibrationInput? input = _input();
    if (input == null) return null;
    return compute(calibrate, input);
  }

  Future<void> _track() async {
    final OverlayAlignment? base = camera.calibrated;
    if (_tracking ||
        !camera.enabled ||
        !camera.liveAlign ||
        base == null ||
        camera.greyPlane == null) {
      return;
    }
    final CalibrationInput? input = _input();
    if (input == null) return;
    _tracking = true;
    try {
      // Always search around the calibrated position, so tracking cannot
      // wander off over time.
      final OverlayAlignment? tracked = await compute(
        _trackInIsolate,
        (input, base),
      );
      // Only follow confident matches; in featureless scenes stay put.
      if (tracked != null && tracked.score > 0.3) {
        camera.applyTracked(tracked);
      }
    } catch (e) {
      debugPrint('[overlay] tracking failed: $e');
    } finally {
      _tracking = false;
    }
  }

  void dispose() {
    _timer?.cancel();
  }
}

OverlayAlignment? _trackInIsolate((CalibrationInput, OverlayAlignment) args) =>
    trackPosition(args.$1, args.$2);

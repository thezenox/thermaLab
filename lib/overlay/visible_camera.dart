import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart' hide Plane;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alignment.dart';

enum OverlayMode { edges, blend }

/// The phone's main camera as a low-resolution grey image in display
/// (portrait) orientation, plus an edge image for the overlay, and the
/// stored alignment between the two cameras.
class VisibleCamera extends ChangeNotifier {
  VisibleCamera() {
    unawaited(_loadPreferences());
  }

  CameraController? _controller;
  bool get running => _controller?.value.isStreamingImages ?? false;
  bool starting = false;
  String? error;

  /// Grey camera picture, display orientation (portrait).
  ui.Image? grey;

  /// White edges with alpha = edge strength, same size as [grey].
  ui.Image? edges;

  /// Latest grey values for alignment (same orientation as [grey]).
  Plane? greyPlane;

  // Settings.
  bool enabled = false;
  OverlayMode mode = OverlayMode.edges;

  /// Edge strength or camera share in blend mode, 0..1.
  double strength = 0.7;

  /// Follow the parallax shift with distance by re-matching continuously.
  bool liveAlign = true;

  /// Calibrated alignment (null: not calibrated, the default guess is used).
  OverlayAlignment? calibrated;

  /// Alignment used for drawing (calibration plus live parallax tracking).
  OverlayAlignment current = OverlayAlignment.initial;

  bool _processing = false;
  final Stopwatch _sinceFrame = Stopwatch()..start();
  static const Duration _frameInterval = Duration(milliseconds: 100);

  /// Output size of the grey/edge images in portrait orientation.
  static const int outWidth = 240;
  static const int outHeight = 320;

  Future<void> _loadPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    mode = OverlayMode.values[(prefs.getInt('overlayMode') ?? 0).clamp(0, 1)];
    strength = prefs.getDouble('overlayStrength') ?? 0.7;
    liveAlign = prefs.getBool('overlayLiveAlign') ?? true;
    final String? json = prefs.getString('overlayAlignment');
    if (json != null) {
      calibrated = OverlayAlignment.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
    }
    current = calibrated ?? OverlayAlignment.initial;
    notifyListeners();
  }

  Future<void> setMode(OverlayMode m) async {
    mode = m;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('overlayMode', m.index);
  }

  Future<void> setStrength(double v) async {
    strength = v;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('overlayStrength', v);
  }

  Future<void> setLiveAlign(bool v) async {
    liveAlign = v;
    if (!v) current = calibrated ?? OverlayAlignment.initial;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('overlayLiveAlign', v);
  }

  Future<void> saveCalibration(OverlayAlignment a) async {
    calibrated = a;
    current = a;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('overlayAlignment', jsonEncode(a.toJson()));
  }

  Future<void> resetCalibration() async {
    calibrated = null;
    current = OverlayAlignment.initial;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('overlayAlignment');
  }

  /// Moves the drawn alignment towards a live-tracked position.
  void applyTracked(OverlayAlignment tracked) {
    const double k = 0.3;
    current = current.copyWith(
      centerX: current.centerX + (tracked.centerX - current.centerX) * k,
      centerY: current.centerY + (tracked.centerY - current.centerY) * k,
      score: tracked.score,
    );
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    notifyListeners();
    if (on) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> start() async {
    if (_controller != null || starting) return;
    starting = true;
    error = null;
    notifyListeners();
    try {
      final List<CameraDescription> cams = await availableCameras();
      final CameraDescription back = cams.firstWhere(
        (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final CameraController c = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await c.initialize();
      _controller = c;
      await c.startImageStream(
        (CameraImage img) => _onImage(img, back.sensorOrientation),
      );
    } catch (e) {
      error = 'Camera failed: $e';
      enabled = false;
      await stop();
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final CameraController? c = _controller;
    _controller = null;
    try {
      if (c != null && c.value.isStreamingImages) await c.stopImageStream();
      await c?.dispose();
    } catch (_) {}
    grey?.dispose();
    edges?.dispose();
    grey = null;
    edges = null;
    greyPlane = null;
    notifyListeners();
  }

  void _onImage(CameraImage img, int sensorOrientation) {
    if (_processing || _sinceFrame.elapsed < _frameInterval) return;
    _sinceFrame
      ..reset()
      ..start();
    _processing = true;
    try {
      final Plane plane = _toPortraitGrey(img, sensorOrientation);
      greyPlane = plane;
      _publish(plane);
    } catch (e) {
      debugPrint('[overlay] frame failed: $e');
      _processing = false;
    }
  }

  /// Samples the Y plane into a [outWidth] x [outHeight] grey image,
  /// rotated by the sensor orientation so it is upright in portrait.
  Plane _toPortraitGrey(CameraImage img, int sensorOrientation) {
    final Plane out = Plane.zero(outWidth, outHeight);
    final Uint8List y = img.planes[0].bytes;
    final int stride = img.planes[0].bytesPerRow;
    final int w = img.width;
    final int h = img.height;
    final int rot = sensorOrientation % 360;
    final bool swap = rot == 90 || rot == 270;
    final int srcW = swap ? h : w; // upright dimensions
    final int srcH = swap ? w : h;
    for (int oy = 0; oy < outHeight; oy++) {
      final int uy = (oy + 0.5) * srcH ~/ outHeight;
      for (int ox = 0; ox < outWidth; ox++) {
        final int ux = (ox + 0.5) * srcW ~/ outWidth;
        // Upright (ux, uy) -> raw sensor (sx, sy).
        int sx;
        int sy;
        switch (rot) {
          case 90:
            sx = uy;
            sy = h - 1 - ux;
          case 180:
            sx = w - 1 - ux;
            sy = h - 1 - uy;
          case 270:
            sx = w - 1 - uy;
            sy = ux;
          default:
            sx = ux;
            sy = uy;
        }
        out.data[oy * outWidth + ox] = y[sy * stride + sx].toDouble();
      }
    }
    return out;
  }

  void _publish(Plane plane) {
    final int n = outWidth * outHeight;
    final Uint8List greyRgba = Uint8List(n * 4);
    for (int i = 0; i < n; i++) {
      final int v = plane.data[i].round().clamp(0, 255);
      greyRgba[i * 4] = v;
      greyRgba[i * 4 + 1] = v;
      greyRgba[i * 4 + 2] = v;
      greyRgba[i * 4 + 3] = 255;
    }
    final Plane e = plane.edges();
    final double cap = math.max(e.percentile(0.97), 8);
    final Uint8List edgeRgba = Uint8List(n * 4);
    for (int i = 0; i < n; i++) {
      final int a = (e.data[i] / cap * 255).round().clamp(0, 255);
      edgeRgba[i * 4] = 255;
      edgeRgba[i * 4 + 1] = 255;
      edgeRgba[i * 4 + 2] = 255;
      edgeRgba[i * 4 + 3] = a;
    }
    int pending = 2;
    ui.Image? newGrey;
    ui.Image? newEdges;
    void done() {
      if (--pending > 0) return;
      grey?.dispose();
      edges?.dispose();
      grey = newGrey;
      edges = newEdges;
      _processing = false;
      notifyListeners();
    }

    ui.decodeImageFromPixels(greyRgba, outWidth, outHeight, ui.PixelFormat.rgba8888, (ui.Image i) {
      newGrey = i;
      done();
    });
    ui.decodeImageFromPixels(edgeRgba, outWidth, outHeight, ui.PixelFormat.rgba8888, (ui.Image i) {
      newEdges = i;
      done();
    });
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

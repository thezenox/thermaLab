import 'dart:ui' as ui;

import '../overlay/visible_camera.dart';
import '../probe/probe_controller.dart';
import '../render/scene_painter.dart';

/// Assembles the drawable scene from the controller's latest frame, or null
/// while there is nothing to show.
SceneData? buildScene(
  ProbeController c, {
  VisibleCamera? camera,
  int? highlightedPointId,
}) {
  final ui.Image? image = c.image;
  final FrameStats? s = c.stats;
  final f = c.frame;
  if (image == null || s == null || f == null || c.calibrationPending) {
    return null;
  }

  final (double, double) cold =
      c.coldMarker ?? (s.coldest.$1.toDouble(), s.coldest.$2.toDouble());
  final (double, double) hot =
      c.hotMarker ?? (s.hottest.$1.toDouble(), s.hottest.$2.toDouble());
  final List<SceneMarker> markers = <SceneMarker>[
    SceneMarker(
      x: cold.$1,
      y: cold.$2,
      temperature: s.minTemp,
      kind: MarkerKind.coldest,
    ),
    SceneMarker(
      x: hot.$1,
      y: hot.$2,
      temperature: s.maxTemp,
      kind: MarkerKind.hottest,
    ),
    SceneMarker(
      x: (f.width ~/ 2).toDouble(),
      y: (f.height ~/ 2).toDouble(),
      temperature: s.centerTemp,
      kind: MarkerKind.centre,
    ),
  ];
  int? highlighted;
  for (int i = 0; i < c.measurePoints.length; i++) {
    final MeasurePoint p = c.measurePoints[i];
    if (p.id == highlightedPointId) highlighted = markers.length;
    markers.add(
      SceneMarker(
        x: p.x.toDouble(),
        y: p.y.toDouble(),
        temperature: c.temperatureAt(p.x, p.y),
        kind: MarkerKind.user,
        label: '${i + 1}',
      ),
    );
  }

  return SceneData(
    image: image,
    sensorWidth: f.width,
    sensorHeight: f.height,
    quarterTurns: c.quarterTurns,
    palette: c.palette,
    scaleLow: c.scaleLow,
    scaleHigh: c.scaleHigh,
    markers: markers,
    timestamp: DateTime.now(),
    highlightedMarker: highlighted,
    timestampCorner: c.timestampCorner,
    labelOutline: c.labelOutline,
    mirror: c.mirror,
    overlay: _overlayLayer(camera),
  );
}

OverlayLayer? _overlayLayer(VisibleCamera? camera) {
  if (camera == null || !camera.enabled) return null;
  final bool blend = camera.mode == OverlayMode.blend;
  final ui.Image? img = blend ? camera.grey : camera.edges;
  if (img == null) return null;
  return OverlayLayer(
    image: img,
    centerX: camera.current.centerX,
    centerY: camera.current.centerY,
    width: camera.current.width,
    mirrored: camera.current.mirrored,
    blend: blend,
    strength: camera.strength,
  );
}

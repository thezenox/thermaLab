import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'geometry.dart';
import 'palette.dart';

/// The phone camera picture laid over or under the thermal image.
class OverlayLayer {
  const OverlayLayer({
    required this.image,
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.mirrored,
    required this.blend,
    required this.strength,
  });

  /// Grey picture (blend) or white edges with alpha (edge mode).
  final ui.Image image;

  /// Where the thermal image lies in [image], as fractions of its size.
  final double centerX;
  final double centerY;
  final double width;

  /// The camera crop must be flipped to match the thermal image.
  final bool mirrored;

  /// Blend mode (grey picture under a translucent thermal image) instead
  /// of edges drawn over it.
  final bool blend;

  /// 0..1: edge opacity, or camera share in blend mode.
  final double strength;
}

/// A labelled spot drawn on the thermal image.
class SceneMarker {
  const SceneMarker({
    required this.x,
    required this.y,
    required this.temperature,
    required this.kind,
    this.label,
  });

  /// Sensor pixel coordinates (fractional while a marker glides).
  final double x;
  final double y;
  final double? temperature;
  final MarkerKind kind;

  /// Optional short tag shown before the temperature (e.g. "1").
  final String? label;
}

enum MarkerKind { centre, hottest, coldest, user }

/// Everything needed to draw one frame of the viewer. The same data drives
/// the screen, photos, videos and the live stream, so they look identical.
class SceneData {
  const SceneData({
    required this.image,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.quarterTurns,
    required this.palette,
    required this.scaleLow,
    required this.scaleHigh,
    required this.markers,
    required this.timestamp,
    this.highlightedMarker,
    this.timestampCorner = 2,
    this.labelOutline = 1,
    this.mirror = false,
    this.overlay,
  });

  final ui.Image image;
  final int sensorWidth;
  final int sensorHeight;
  final int quarterTurns;
  final Palette palette;
  final double scaleLow;
  final double scaleHigh;
  final List<SceneMarker> markers;
  final DateTime timestamp;

  /// Index into [markers] that is being dragged, drawn emphasised.
  final int? highlightedMarker;

  /// 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
  final int timestampCorner;

  /// Outline around marker labels: 0 shadow only, 1 normal, 2 thick.
  final int labelOutline;

  /// Thermal image flipped horizontally after rotation.
  final bool mirror;

  /// Phone camera layer, null when the overlay is off.
  final OverlayLayer? overlay;

  SceneData withImage(ui.Image other, {OverlayLayer? overlay}) => SceneData(
    image: other,
    sensorWidth: sensorWidth,
    sensorHeight: sensorHeight,
    quarterTurns: quarterTurns,
    palette: palette,
    scaleLow: scaleLow,
    scaleHigh: scaleHigh,
    markers: markers,
    timestamp: timestamp,
    highlightedMarker: highlightedMarker,
    timestampCorner: timestampCorner,
    labelOutline: labelOutline,
    mirror: mirror,
    overlay: overlay ?? this.overlay,
  );

  /// Aspect ratio (width / height) of the rotated image.
  double get aspectRatio => quarterTurns.isOdd
      ? sensorHeight / sensorWidth
      : sensorWidth / sensorHeight;
}

/// Draws [data] into a rectangle of [size] starting at the origin.
void paintScene(Canvas canvas, Size size, SceneData data) {
  final OverlayLayer? overlay = data.overlay;
  if (overlay != null && overlay.blend) {
    _paintOverlay(canvas, size, overlay, 1.0);
    _paintImage(canvas, size, data, opacity: 1 - 0.75 * overlay.strength);
  } else {
    _paintImage(canvas, size, data);
    if (overlay != null) _paintOverlay(canvas, size, overlay, overlay.strength);
  }
  // Text and stroke sizes follow the output size so a 480 px video frame
  // and a phone screen look alike.
  final double unit = size.shortestSide / 360.0;
  for (int i = 0; i < data.markers.length; i++) {
    _paintMarker(canvas, size, data, data.markers[i], unit,
        highlighted: i == data.highlightedMarker);
  }
  _paintScale(canvas, size, data, unit);
  _paintTimestamp(canvas, size, data.timestamp, data.timestampCorner, unit);
}

/// Draws the part of the camera picture that matches the thermal view.
void _paintOverlay(Canvas canvas, Size size, OverlayLayer o, double opacity) {
  final ui.Image img = o.image;
  final double w = o.width * img.width;
  final double h = w * size.height / size.width;
  final Rect src = Rect.fromCenter(
    center: Offset(o.centerX * img.width, o.centerY * img.height),
    width: w,
    height: h,
  );
  canvas.save();
  canvas.clipRect(Offset.zero & size);
  if (o.mirrored) {
    canvas.translate(size.width, 0);
    canvas.scale(-1, 1);
  }
  canvas.drawImageRect(
    img,
    src,
    Offset.zero & size,
    Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)),
  );
  canvas.restore();
}

void _paintImage(
  Canvas canvas,
  Size size,
  SceneData data, {
  double opacity = 1,
}) {
  final ui.Image img = data.image;
  canvas.save();
  canvas.translate(size.width / 2, size.height / 2);
  if (data.mirror) canvas.scale(-1, 1);
  canvas.rotate(data.quarterTurns % 4 * math.pi / 2);
  // In the rotated frame the image spans the unrotated dimensions.
  final bool odd = data.quarterTurns.isOdd;
  final double w = odd ? size.height : size.width;
  final double h = odd ? size.width : size.height;
  canvas.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    Rect.fromCenter(center: Offset.zero, width: w, height: h),
    Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)),
  );
  canvas.restore();
}

Offset markerOffset(Size size, SceneData data, num x, num y) {
  final (double a, double b) = sensorToDisplay(
    (x + 0.5) / data.sensorWidth,
    (y + 0.5) / data.sensorHeight,
    data.quarterTurns,
    mirror: data.mirror,
  );
  return Offset(a * size.width, b * size.height);
}

const List<Shadow> _textShadow = <Shadow>[
  Shadow(blurRadius: 3, color: Colors.black),
  Shadow(blurRadius: 1, color: Colors.black),
];

TextPainter _text(String s, double fontSize, Color color,
    {FontWeight weight = FontWeight.w600}) {
  return TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: weight,
        shadows: _textShadow,
        fontFeatures: const <ui.FontFeature>[ui.FontFeature.tabularFigures()],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

String formatTemp(double? t) =>
    t == null || t.isNaN ? '--' : '${t.toStringAsFixed(1)}°';

void _paintMarker(
  Canvas canvas,
  Size size,
  SceneData data,
  SceneMarker m,
  double unit, {
  required bool highlighted,
}) {
  final Offset o = markerOffset(size, data, m.x, m.y);
  final Color color = switch (m.kind) {
    MarkerKind.centre => Colors.white,
    MarkerKind.hottest => const Color(0xFFFF5252),
    MarkerKind.coldest => const Color(0xFF40C4FF),
    MarkerKind.user => const Color(0xFFFFEB3B),
  };
  final double r = (highlighted ? 11 : 7) * unit;
  final Paint outline = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3.2 * unit
    ..color = Colors.black54;
  final Paint stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6 * unit
    ..color = color;

  // Measurement points are a numbered disc centred on the measured pixel.
  double reach = r;
  if (m.kind == MarkerKind.user) {
    final TextPainter number = TextPainter(
      text: TextSpan(
        text: m.label ?? '',
        style: TextStyle(
          color: Colors.black,
          fontSize: (highlighted ? 13 : 10.5) * unit,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double radius = math.max(
      (highlighted ? 10.5 : 8) * unit,
      number.width / 2 + 3.5 * unit,
    );
    canvas.drawCircle(o, radius, Paint()..color = color);
    canvas.drawCircle(
      o,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * unit
        ..color = Colors.black,
    );
    number.paint(canvas, o - Offset(number.width / 2, number.height / 2));
    reach = radius;
  } else {
    void shape(Paint p) {
      switch (m.kind) {
        case MarkerKind.centre:
          canvas.drawLine(o - Offset(r, 0), o + Offset(r, 0), p);
          canvas.drawLine(o - Offset(0, r), o + Offset(0, r), p);
        case MarkerKind.hottest:
        case MarkerKind.coldest:
          final bool up = m.kind == MarkerKind.hottest;
          final Path tri = Path()
            ..moveTo(o.dx, o.dy + (up ? -r : r))
            ..lineTo(o.dx - r * 0.9, o.dy + (up ? r * 0.6 : -r * 0.6))
            ..lineTo(o.dx + r * 0.9, o.dy + (up ? r * 0.6 : -r * 0.6))
            ..close();
          canvas.drawPath(tri, p);
        case MarkerKind.user:
          break;
      }
    }

    shape(outline);
    shape(stroke);
  }

  final String text = formatTemp(m.temperature);
  final TextPainter tp = _text(text, 12.5 * unit, color);

  // Keep the label inside the image.
  double dx = o.dx + reach + 3 * unit;
  if (dx + tp.width > size.width - 4 * unit) {
    dx = o.dx - reach - 3 * unit - tp.width;
  }
  double dy = o.dy - tp.height / 2;
  dy = dy.clamp(2 * unit, size.height - tp.height - 2 * unit);
  final Offset textAt = Offset(dx, dy);
  if (data.labelOutline > 0) {
    _outlined(text, 12.5 * unit, data.labelOutline == 2 ? 4.5 * unit : 2.6 * unit)
        .paint(canvas, textAt);
  }
  tp.paint(canvas, textAt);
}

/// Black stroked copy of a label, drawn underneath it for contrast.
TextPainter _outlined(String s, double fontSize, double strokeWidth) {
  return TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        fontFeatures: const <ui.FontFeature>[ui.FontFeature.tabularFigures()],
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.black,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

void _paintScale(Canvas canvas, Size size, SceneData data, double unit) {
  final double barW = 9 * unit;
  final double barH = math.min(size.height * 0.42, 170 * unit);
  final double right = size.width - 8 * unit;
  final Rect bar = Rect.fromLTWH(
    right - barW,
    (size.height - barH) / 2,
    barW,
    barH,
  );

  // Labels: top, 3 intermediate, bottom.
  const int ticks = 5;
  final List<TextPainter> labels = <TextPainter>[
    for (int i = 0; i < ticks; i++)
      _text(
        (data.scaleHigh - (data.scaleHigh - data.scaleLow) * i / (ticks - 1))
            .toStringAsFixed(1),
        10.5 * unit,
        Colors.white,
        weight: FontWeight.w500,
      ),
  ];
  final double labelW = labels.map((TextPainter t) => t.width).reduce(math.max);

  final RRect plate = RRect.fromRectAndRadius(
    Rect.fromLTRB(
      bar.left - labelW - 10 * unit,
      bar.top - 8 * unit,
      bar.right + 4 * unit,
      bar.bottom + 8 * unit,
    ),
    Radius.circular(5 * unit),
  );
  canvas.drawRRect(plate, Paint()..color = const Color(0x66000000));

  final List<Color> colors = <Color>[
    for (int i = 255; i >= 0; i -= 17) Color(_rgbaToArgb(data.palette.rgba[i])),
    Color(_rgbaToArgb(data.palette.rgba[0])),
  ];
  canvas.drawRect(
    bar,
    Paint()
      ..shader = ui.Gradient.linear(
        bar.topCenter,
        bar.bottomCenter,
        colors,
        <double>[for (int i = 0; i < colors.length; i++) i / (colors.length - 1)],
      ),
  );
  canvas.drawRect(
    bar,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 * unit
      ..color = Colors.white70,
  );
  for (int i = 0; i < ticks; i++) {
    final double y = bar.top + bar.height * i / (ticks - 1);
    final TextPainter tp = labels[i];
    tp.paint(
      canvas,
      Offset(bar.left - 5 * unit - tp.width, y - tp.height / 2),
    );
    canvas.drawLine(
      Offset(bar.left - 3 * unit, y),
      Offset(bar.left, y),
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 0.8 * unit,
    );
  }
  final TextPainter unitLabel =
      _text('°C', 10 * unit, Colors.white70, weight: FontWeight.w500);
  unitLabel.paint(
    canvas,
    Offset(bar.center.dx - unitLabel.width / 2, bar.top - 7 * unit - unitLabel.height),
  );
}

int _rgbaToArgb(int v) =>
    (v & 0xFF00FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);

String formatTimestamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

void _paintTimestamp(
  Canvas canvas,
  Size size,
  DateTime t,
  int corner,
  double unit,
) {
  final TextPainter tp = _text(
    formatTimestamp(t),
    11 * unit,
    Colors.white,
    weight: FontWeight.w500,
  );
  // The plate sits flush in the chosen corner of the image.
  final double padX = 5 * unit;
  final double padY = 2.5 * unit;
  final double w = tp.width + 2 * padX;
  final double h = tp.height + 2 * padY;
  final bool right = corner == 1 || corner == 3;
  final bool bottom = corner >= 2;
  final Rect plate = Rect.fromLTWH(
    right ? size.width - w : 0,
    bottom ? size.height - h : 0,
    w,
    h,
  );
  canvas.drawRect(plate, Paint()..color = const Color(0x8C000000));
  tp.paint(canvas, plate.topLeft + Offset(padX, padY));
}

/// Screen painter wrapper around [paintScene].
class ScenePainter extends CustomPainter {
  ScenePainter(this.data);

  final SceneData data;

  @override
  void paint(Canvas canvas, Size size) => paintScene(canvas, size, data);

  @override
  bool shouldRepaint(ScenePainter oldDelegate) => true;
}

/// Renders [data] off-screen at [size] (for photos, video and streaming).
///
/// Draws from a private copy of the thermal image, because the live image
/// is replaced (and disposed) by the next camera frame while this runs.
Future<ui.Image> renderScene(SceneData data, Size size) async {
  final ui.Image own = data.image.clone();
  final OverlayLayer? o = data.overlay;
  final ui.Image? ownOverlay = o?.image.clone();
  try {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    paintScene(
      canvas,
      size,
      data.withImage(
        own,
        overlay: o == null
            ? null
            : OverlayLayer(
                image: ownOverlay!,
                centerX: o.centerX,
                centerY: o.centerY,
                width: o.width,
                mirrored: o.mirrored,
                blend: o.blend,
                strength: o.strength,
              ),
      ),
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      return await picture.toImage(size.width.round(), size.height.round());
    } finally {
      picture.dispose();
    }
  } finally {
    own.dispose();
    ownOverlay?.dispose();
  }
}

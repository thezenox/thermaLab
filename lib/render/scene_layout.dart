import 'dart:ui' show Offset;

/// Which overlay elements are shown and where the movable ones sit.
///
/// Positions are fractions of the free space in the image: (0, 0) puts an
/// element flush into the top-left corner, (1, 1) into the bottom-right one,
/// whatever the element's size.
class SceneLayout {
  const SceneLayout({
    this.showClock = true,
    this.showScale = true,
    this.showCentre = true,
    this.showHottest = true,
    this.showColdest = true,
    this.clockPos = const Offset(0, 1),
    this.scalePos = const Offset(1, 0.5),
  });

  final bool showClock;
  final bool showScale;
  final bool showCentre;
  final bool showHottest;
  final bool showColdest;
  final Offset clockPos;
  final Offset scalePos;

  SceneLayout copyWith({
    bool? showClock,
    bool? showScale,
    bool? showCentre,
    bool? showHottest,
    bool? showColdest,
    Offset? clockPos,
    Offset? scalePos,
  }) => SceneLayout(
    showClock: showClock ?? this.showClock,
    showScale: showScale ?? this.showScale,
    showCentre: showCentre ?? this.showCentre,
    showHottest: showHottest ?? this.showHottest,
    showColdest: showColdest ?? this.showColdest,
    clockPos: clockPos ?? this.clockPos,
    scalePos: scalePos ?? this.scalePos,
  );

  Map<String, Object> toJson() => <String, Object>{
    'showClock': showClock,
    'showScale': showScale,
    'showCentre': showCentre,
    'showHottest': showHottest,
    'showColdest': showColdest,
    'clockX': clockPos.dx,
    'clockY': clockPos.dy,
    'scaleX': scalePos.dx,
    'scaleY': scalePos.dy,
  };

  /// Reads a full or partial map; missing entries keep the values of [base].
  static SceneLayout fromJson(
    Map<String, dynamic> j, [
    SceneLayout base = const SceneLayout(),
  ]) {
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    double n(String k, double d) =>
        j[k] is num ? (j[k] as num).toDouble().clamp(0.0, 1.0) : d;
    return SceneLayout(
      showClock: b('showClock', base.showClock),
      showScale: b('showScale', base.showScale),
      showCentre: b('showCentre', base.showCentre),
      showHottest: b('showHottest', base.showHottest),
      showColdest: b('showColdest', base.showColdest),
      clockPos: Offset(n('clockX', base.clockPos.dx), n('clockY', base.clockPos.dy)),
      scalePos: Offset(n('scaleX', base.scalePos.dx), n('scaleY', base.scalePos.dy)),
    );
  }

  /// Layout matching the former fixed timestamp corners (0 top-left,
  /// 1 top-right, 2 bottom-left, 3 bottom-right).
  static SceneLayout fromTimestampCorner(int corner) => SceneLayout(
    clockPos: Offset(corner == 1 || corner == 3 ? 1 : 0, corner >= 2 ? 1 : 0),
  );
}

/// Snaps a dragged fraction to edges and centre when close.
double snapFraction(double v, {double threshold = 0.04}) {
  for (final double target in const <double>[0, 0.5, 1]) {
    if ((v - target).abs() < threshold) return target;
  }
  return v.clamp(0.0, 1.0);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/render/scene_layout.dart';

void main() {
  test('layout survives a JSON round trip', () {
    const SceneLayout l = SceneLayout(
      showClock: false,
      showHottest: false,
      clockPos: Offset(0.25, 0),
      scalePos: Offset(0, 0.75),
    );
    final SceneLayout back = SceneLayout.fromJson(l.toJson());
    expect(back.showClock, isFalse);
    expect(back.showHottest, isFalse);
    expect(back.showScale, isTrue);
    expect(back.clockPos, const Offset(0.25, 0));
    expect(back.scalePos, const Offset(0, 0.75));
  });

  test('partial updates from the browser keep the other values', () {
    const SceneLayout base = SceneLayout(clockPos: Offset(1, 0));
    final SceneLayout l = SceneLayout.fromJson(
      <String, dynamic>{'showColdest': false},
      base,
    );
    expect(l.showColdest, isFalse);
    expect(l.showCentre, isTrue);
    expect(l.clockPos, const Offset(1, 0));
  });

  test('the former timestamp corners map to positions', () {
    expect(SceneLayout.fromTimestampCorner(0).clockPos, Offset.zero);
    expect(SceneLayout.fromTimestampCorner(1).clockPos, const Offset(1, 0));
    expect(SceneLayout.fromTimestampCorner(2).clockPos, const Offset(0, 1));
    expect(SceneLayout.fromTimestampCorner(3).clockPos, const Offset(1, 1));
  });

  test('dragging snaps to edges and centre', () {
    expect(snapFraction(0.02), 0);
    expect(snapFraction(0.97), 1);
    expect(snapFraction(0.52), 0.5);
    expect(snapFraction(0.3), 0.3);
    expect(snapFraction(1.4), 1);
  });
}

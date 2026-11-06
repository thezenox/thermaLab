import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../capture/capture_service.dart';
import '../capture/csv_logger.dart';
import '../overlay/overlay_engine.dart';
import '../overlay/overlay_feature.dart';
import '../overlay/visible_camera.dart';
import '../probe/probe_controller.dart';
import '../render/geometry.dart';
import '../render/scene_layout.dart';
import '../render/scene_painter.dart';
import 'scene_builder.dart';
import 'settings_page.dart';

/// Main screen: the thermal image with its overlays, and four actions.
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.controller,
    required this.capture,
    required this.overlay,
  });

  final ProbeController controller;
  final CaptureService capture;
  final OverlayEngine overlay;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  ProbeController get c => widget.controller;
  CaptureService get capture => widget.capture;
  VisibleCamera get camera => widget.overlay.camera;

  MeasurePoint? _dragging;
  bool _overTrash = false;

  /// Release button mode: photo or video.
  bool _videoMode = false;

  /// White flash over the image when a photo is taken.
  double _flash = 0;

  /// Layout edit mode: toggle and move the overlay elements.
  bool _editing = false;

  /// Element being dragged in edit mode ('clock' or 'scale').
  String? _dragElement;
  Offset _dragStartFraction = Offset.zero;
  Offset _dragStartLocal = Offset.zero;

  /// Touch distance (logical pixels) within which a point can be grabbed.
  static const double _grabRadius = 32;
  static const double _trashSize = 56;


  void _toast(String? error, String success) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(error ?? success),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _finishCsv() async {
    final File? file = await capture.csv.finish();
    if (file == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: 'text/csv')],
        subject: 'Thermal temperature log',
      ),
    );
  }

  /// Second row: optional tools (CSV logging, camera overlay).
  Widget _secondaryBar() {
    final CsvLogger csv = capture.csv;
    final bool ready =
        c.streaming && c.image != null && !c.calibrationPending;
    final List<Widget> items = <Widget>[
      if (kCameraOverlayEnabled)
        _ChipButton(
        icon: camera.enabled ? Icons.layers : Icons.layers_outlined,
        label: camera.starting
            ? 'Overlay…'
            : (camera.calibrated == null && camera.enabled
                  ? 'Overlay (not calibrated)'
                  : 'Overlay'),
        active: camera.enabled,
        activeColor: Colors.teal,
        onPressed: () async {
          await camera.setEnabled(!camera.enabled);
          if (camera.error != null && mounted) _toast(camera.error, '');
        },
      ),
    ];
    if (csv.enabled) {
      final Duration d = csv.elapsed;
      items.add(
        _ChipButton(
          icon: csv.recording ? Icons.pause : Icons.fiber_manual_record,
          label: csv.recording
              ? 'CSV ${d.inMinutes.toString().padLeft(2, '0')}:'
                    '${(d.inSeconds % 60).toString().padLeft(2, '0')}'
              : (csv.hasData ? 'CSV paused' : 'CSV'),
          active: csv.recording,
          onPressed: ready || csv.recording ? csv.toggle : null,
        ),
      );
      if (csv.hasData) {
        items.add(
          _ChipButton(
            icon: Icons.ios_share,
            label: 'Save CSV (${csv.rows})',
            onPressed: _finishCsv,
          ),
        );
      }
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: items,
      ),
    );
  }

  /// Takes a photo. Success is shown by a short flash over the image; only
  /// errors produce a message.
  Future<void> _photo() async {
    setState(() => _flash = 0.75);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _flash = 0);
    });
    final String? error = await capture.takePhoto();
    if (error != null && mounted) _toast(error, '');
  }

  Future<void> _toggleRecording() async {
    final String? error = capture.recording
        ? await capture.stopRecording()
        : await capture.startRecording();
    if (error != null && mounted) _toast(error, '');
  }

  void _release() {
    if (_videoMode || capture.recording) {
      _toggleRecording();
    } else {
      _photo();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
        <Listenable>[c, capture, capture.csv, camera],
      ),
      builder: (BuildContext context, _) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              _topBar(),
              Expanded(child: Center(child: _sceneArea())),
              _secondaryBar(),
              _toolbar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final List<Widget> chips = <Widget>[];
    if (capture.streaming) {
      chips.add(_Badge(
        color: Colors.teal,
        text: capture.liveServer.hasViewers
            ? 'LIVE · ${capture.liveServer.viewerCount}'
            : 'LIVE',
      ));
    }
    if (c.busy && c.streaming) {
      chips.add(const _Badge(color: Colors.blueGrey, text: 'Shutter…'));
    }
    if (_editing) return _editBar();
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          for (final Widget w in chips)
            Padding(padding: const EdgeInsets.only(right: 8), child: w),
          IconButton(
            tooltip: 'Arrange display',
            onPressed: c.image == null ? null : () => setState(() => _editing = true),
            icon: const _EditLayoutIcon(),
          ),
        ],
      ),
    );
  }

  /// Toggles for every overlay element, shown while editing the layout.
  Widget _editBar() {
    final SceneLayout l = c.layout;
    Widget toggle(String label, bool on, SceneLayout Function(bool) apply) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text(label),
          selected: on,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          onSelected: (bool v) => c.setLayout(apply(v), persist: false),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  toggle('Clock', l.showClock, (bool v) => l.copyWith(showClock: v)),
                  toggle('Colour bar', l.showScale, (bool v) => l.copyWith(showScale: v)),
                  toggle('Centre', l.showCentre, (bool v) => l.copyWith(showCentre: v)),
                  toggle('Max', l.showHottest, (bool v) => l.copyWith(showHottest: v)),
                  toggle('Min', l.showColdest, (bool v) => l.copyWith(showColdest: v)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: () {
              c.setLayout(c.layout);
              setState(() {
                _editing = false;
                _dragElement = null;
              });
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _sceneArea() {
    if (c.streaming && (c.image == null || c.calibrationPending)) {
      return const _Calibrating();
    }
    if (!c.streaming || c.image == null) {
      return _NoCamera(
        status: c.status,
        busy: c.busy,
        onRetry: c.busy ? null : c.autoConnect,
      );
    }
    final SceneData? data = buildScene(
      c,
      camera: camera,
      highlightedPointId: _dragging?.id,
      editing: _editing,
    );
    if (data == null) return const CircularProgressIndicator();

    return AspectRatio(
      aspectRatio: data.aspectRatio,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Size size = box.biggest;
          final Rect trash = Rect.fromCenter(
            center: Offset(size.width / 2, size.height - _trashSize),
            width: _trashSize,
            height: _trashSize,
          );

          (int, int) toSensor(Offset local) {
            final (double u, double v) = displayToSensor(
              (local.dx / size.width).clamp(0.0, 1.0),
              (local.dy / size.height).clamp(0.0, 1.0),
              data.quarterTurns,
              mirror: data.mirror,
            );
            return (
              (u * data.sensorWidth).floor().clamp(0, data.sensorWidth - 1),
              (v * data.sensorHeight).floor().clamp(0, data.sensorHeight - 1),
            );
          }

          MeasurePoint? pointNear(Offset local) {
            MeasurePoint? best;
            double bestDist = _grabRadius;
            for (final MeasurePoint p in c.measurePoints) {
              final double d =
                  (markerOffset(size, data, p.x, p.y) - local).distance;
              if (d < bestDist) {
                best = p;
                bestDist = d;
              }
            }
            return best;
          }

          void moveTo(Offset local) {
            final MeasurePoint? p = _dragging;
            if (p == null) return;
            final (int x, int y) = toSensor(local);
            c.moveMeasurePoint(p, x, y);
            final bool over = trash.inflate(8).contains(local);
            if (over != _overTrash) setState(() => _overTrash = over);
          }

          void endDrag() {
            final MeasurePoint? p = _dragging;
            if (p != null && _overTrash) c.removeMeasurePoint(p);
            setState(() {
              _dragging = null;
              _overTrash = false;
            });
          }

          if (_editing) {
            return GestureDetector(
              onPanStart: (DragStartDetails d) {
                final Offset at = d.localPosition;
                String? hit;
                if (data.layout.showClock &&
                    clockRect(size, data).inflate(14).contains(at)) {
                  hit = 'clock';
                } else if (data.layout.showScale &&
                    scaleRect(size, data).inflate(14).contains(at)) {
                  hit = 'scale';
                }
                if (hit == null) return;
                _dragElement = hit;
                _dragStartLocal = at;
                _dragStartFraction = hit == 'clock'
                    ? c.layout.clockPos
                    : c.layout.scalePos;
              },
              onPanUpdate: (DragUpdateDetails d) {
                final String? el = _dragElement;
                if (el == null) return;
                // Free space the fraction is relative to (element size and
                // edge margin as used by the painter).
                final Rect r = el == 'clock'
                    ? clockRect(size, data)
                    : scaleRect(size, data);
                final double margin =
                    el == 'clock' ? 0 : 6 * size.shortestSide / 360;
                final double freeW = size.width - 2 * margin - r.width;
                final double freeH = size.height - 2 * margin - r.height;
                final Offset delta = d.localPosition - _dragStartLocal;
                final Offset pos = Offset(
                  snapFraction(
                    _dragStartFraction.dx + (freeW > 0 ? delta.dx / freeW : 0),
                  ),
                  snapFraction(
                    _dragStartFraction.dy + (freeH > 0 ? delta.dy / freeH : 0),
                  ),
                );
                c.setLayout(
                  el == 'clock'
                      ? c.layout.copyWith(clockPos: pos)
                      : c.layout.copyWith(scalePos: pos),
                  persist: false,
                );
              },
              onPanEnd: (_) => _dragElement = null,
              child: CustomPaint(size: size, painter: ScenePainter(data)),
            );
          }

          return GestureDetector(
            onLongPressStart: (LongPressStartDetails d) {
              MeasurePoint? p = pointNear(d.localPosition);
              if (p == null) {
                final (int x, int y) = toSensor(d.localPosition);
                p = c.addMeasurePoint(x, y);
                if (p == null) {
                  _toast('At most ${ProbeController.maxMeasurePoints} '
                      'points', '');
                  return;
                }
              }
              setState(() => _dragging = p);
            },
            onLongPressMoveUpdate: (LongPressMoveUpdateDetails d) =>
                moveTo(d.localPosition),
            onLongPressEnd: (_) => endDrag(),
            onPanStart: (DragStartDetails d) {
              final MeasurePoint? p = pointNear(d.localPosition);
              if (p != null) setState(() => _dragging = p);
            },
            onPanUpdate: (DragUpdateDetails d) => moveTo(d.localPosition),
            onPanEnd: (_) => endDrag(),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: CustomPaint(painter: ScenePainter(data)),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _flash,
                      duration: _flash > 0
                          ? Duration.zero
                          : const Duration(milliseconds: 280),
                      curve: Curves.easeOut,
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ),
                ),
                if (_dragging != null)
                  Positioned.fromRect(
                    rect: trash,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _overTrash
                            ? Colors.red.withValues(alpha: 0.85)
                            : Colors.black54,
                        border: Border.all(color: Colors.white70),
                      ),
                      child: const Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _toolbar() {
    final bool ready =
        c.streaming && c.image != null && !c.calibrationPending;
    final bool recording = capture.recording;
    final Duration d = capture.recordingDuration;
    const Color gold = Color(0xFFD4A84B);

    Widget modeLabel(String text, bool video) {
      final bool selected = _videoMode == video;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _videoMode = video),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            text,
            style: TextStyle(
              color: selected ? gold : Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.6,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: 32,
            child: recording
                ? Center(
                    child: Text(
                      '● ${d.inMinutes.toString().padLeft(2, '0')}:'
                      '${(d.inSeconds % 60).toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      modeLabel('PHOTO', false),
                      modeLabel('VIDEO', true),
                    ],
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _ToolButton(
                icon: Icons.shutter_speed,
                label: 'Shutter',
                onPressed: ready && !c.busy && c.canTriggerShutter
                    ? c.runShutterCorrection
                    : null,
              ),
              _ReleaseButton(
                mode: recording
                    ? _ReleaseMode.recording
                    : (_videoMode ? _ReleaseMode.video : _ReleaseMode.photo),
                onPressed: ready || recording ? _release : null,
              ),
              _ToolButton(
                icon: Icons.settings,
                label: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(
                      controller: c,
                      capture: capture,
                      overlay: widget.overlay,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _ReleaseMode { photo, video, recording }

/// The big round release button, styled after phone camera apps: white for
/// photos, red dot for video, red square to stop a recording.
class _ReleaseButton extends StatefulWidget {
  const _ReleaseButton({required this.mode, required this.onPressed});

  final _ReleaseMode mode;
  final VoidCallback? onPressed;

  @override
  State<_ReleaseButton> createState() => _ReleaseButtonState();
}

class _ReleaseButtonState extends State<_ReleaseButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    const Color gold = Color(0xFFD4A84B);
    const Color red = Color(0xFFD9342B);
    final bool enabled = widget.onPressed != null;
    final _ReleaseMode mode = widget.mode;
    final Color ring = mode == _ReleaseMode.photo ? Colors.white : gold;
    final Widget inner = switch (mode) {
      _ReleaseMode.photo => Container(
        key: const ValueKey<String>('photo'),
        width: 58,
        height: 58,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
      _ReleaseMode.video => Container(
        key: const ValueKey<String>('video'),
        width: 54,
        height: 54,
        decoration: const BoxDecoration(color: red, shape: BoxShape.circle),
      ),
      _ReleaseMode.recording => Container(
        key: const ValueKey<String>('stop'),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: red,
          borderRadius: BorderRadius.circular(5),
        ),
      ),
    };

    return Semantics(
      button: true,
      label: switch (mode) {
        _ReleaseMode.photo => 'Take photo',
        _ReleaseMode.video => 'Start video',
        _ReleaseMode.recording => 'Stop video',
      },
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.35,
          duration: const Duration(milliseconds: 150),
          child: AnimatedScale(
            scale: _down ? 0.88 : 1,
            duration: const Duration(milliseconds: 90),
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ring, width: 3),
              ),
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                transitionBuilder: (Widget child, Animation<double> a) =>
                    ScaleTransition(scale: a, child: child),
                child: inner,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final Color fg = enabled ? Colors.white : Colors.white24;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: fg, size: 30),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: fg, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Shown from connecting until the first shutter correction is done, so the
/// raw, striped sensor image never appears.
class _Calibrating extends StatelessWidget {
  const _Calibrating();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox.square(
            dimension: 48,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 16),
          Text(
            'Calibrating camera…',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 4),
          Text(
            'This takes a few seconds',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _NoCamera extends StatelessWidget {
  const _NoCamera({required this.status, required this.busy, this.onRetry});

  final String status;
  final bool busy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.usb, color: Colors.white38, size: 48),
          const SizedBox(height: 12),
          Text(
            busy ? status : 'Plug in the T2S+ camera',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 12),
          if (busy)
            const CircularProgressIndicator()
          else
            OutlinedButton(onPressed: onRetry, child: const Text('Connect')),
        ],
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.activeColor = Colors.redAccent,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final Color fg = enabled ? Colors.white : Colors.white30;
    return Material(
      color: active ? activeColor.withValues(alpha: 0.85) : Colors.white10,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gear with a small pencil: "arrange the display".
class _EditLayoutIcon extends StatelessWidget {
  const _EditLayoutIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            child: Icon(Icons.settings_outlined, color: Colors.white70, size: 22),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: EdgeInsets.all(1),
                child: Icon(Icons.edit, color: Color(0xFFD4A84B), size: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
  Timer? _recordTicker;

  /// Touch distance (logical pixels) within which a point can be grabbed.
  static const double _grabRadius = 32;
  static const double _trashSize = 56;

  @override
  void dispose() {
    _recordTicker?.cancel();
    super.dispose();
  }

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
    final bool ready = c.streaming && c.image != null;
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

  Future<void> _photo() async {
    final String? error = await capture.takePhoto();
    if (mounted) _toast(error, 'Photo saved to the gallery');
  }

  Future<void> _toggleRecording() async {
    if (capture.recording) {
      _recordTicker?.cancel();
      final String? error = await capture.stopRecording();
      if (mounted) _toast(error, 'Video saved to the gallery');
    } else {
      final String? error = await capture.startRecording();
      if (error != null) {
        if (mounted) _toast(error, '');
        return;
      }
      _recordTicker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    }
    if (mounted) setState(() {});
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
    if (capture.recording) {
      final Duration d = capture.recordingDuration;
      chips.add(_Badge(
        color: Colors.red,
        text: 'REC ${d.inMinutes.toString().padLeft(2, '0')}:'
            '${(d.inSeconds % 60).toString().padLeft(2, '0')}',
      ));
    }
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
    return SizedBox(
      height: 32,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          for (final Widget w in chips)
            Padding(padding: const EdgeInsets.only(right: 8), child: w),
        ],
      ),
    );
  }

  Widget _sceneArea() {
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
    final bool ready = c.streaming && c.image != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _ToolButton(
            icon: Icons.shutter_speed,
            label: 'Shutter',
            onPressed: ready && !c.busy ? c.runShutterCorrection : null,
          ),
          _ToolButton(
            icon: Icons.photo_camera,
            label: 'Photo',
            onPressed: ready ? _photo : null,
          ),
          _ToolButton(
            icon: capture.recording
                ? Icons.stop_circle
                : Icons.fiber_manual_record,
            label: capture.recording ? 'Stop' : 'Video',
            color: Colors.redAccent,
            onPressed: ready || capture.recording ? _toggleRecording : null,
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
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;
    final Color fg = enabled ? (color ?? Colors.white) : Colors.white24;
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

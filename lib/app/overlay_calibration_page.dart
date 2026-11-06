import 'package:flutter/material.dart';

import '../overlay/alignment.dart';
import '../overlay/overlay_engine.dart';
import '../overlay/visible_camera.dart';
import '../probe/probe_controller.dart';
import '../render/scene_painter.dart';
import 'scene_builder.dart';

/// Finds where the thermal image sits in the phone camera picture and
/// stores it for this phone.
class OverlayCalibrationPage extends StatefulWidget {
  const OverlayCalibrationPage({
    super.key,
    required this.controller,
    required this.overlay,
  });

  final ProbeController controller;
  final OverlayEngine overlay;

  @override
  State<OverlayCalibrationPage> createState() => _OverlayCalibrationPageState();
}

class _OverlayCalibrationPageState extends State<OverlayCalibrationPage> {
  VisibleCamera get camera => widget.overlay.camera;
  ProbeController get c => widget.controller;

  bool _busy = false;
  OverlayAlignment? _result;
  String? _message;
  late final OverlayMode _previousMode = camera.mode;
  late final bool _previousEnabled = camera.enabled;
  late final double _previousStrength = camera.strength;

  @override
  void initState() {
    super.initState();
    // Blend view makes misalignment easy to judge.
    camera.mode = OverlayMode.blend;
    camera.strength = 0.5;
    if (!camera.enabled) camera.setEnabled(true);
  }

  @override
  void dispose() {
    camera.mode = _previousMode;
    camera.strength = _previousStrength;
    if (_result == null) camera.current = camera.calibrated ?? OverlayAlignment.initial;
    if (!_previousEnabled) camera.setEnabled(false);
    super.dispose();
  }

  Future<void> _calibrate() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final OverlayAlignment? a = await widget.overlay.calibrateNow();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = a;
      if (a == null) {
        _message = 'No usable picture yet. Wait for both cameras and try again.';
      } else {
        camera.current = a;
        final String quality = a.score > 0.5
            ? 'good'
            : a.score > 0.3
                ? 'fair'
                : 'weak - aim at something with clearer edges';
        _message = 'Match ${(a.score * 100).round()} % ($quality). '
            'Thermal field = ${(a.width * 100).round()} % of the camera width.'
            '${a.mirrored ? '\nThe thermal image looks mirrored.' : ''}';
      }
    });
  }

  Future<void> _mirrorAndRetry() async {
    await c.applySetting('mirror', !c.mirror);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _calibrate();
  }

  Future<void> _save() async {
    final OverlayAlignment? a = _result;
    if (a == null) return;
    await camera.saveCalibration(a);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[c, camera]),
      builder: (BuildContext context, _) {
        final SceneData? data = buildScene(c, camera: camera);
        return Scaffold(
          appBar: AppBar(title: const Text('Calibrate overlay')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              const Text(
                'Aim both cameras at an object with clear edges that is '
                'warmer or colder than its surroundings, 0.5 to 2 m away: '
                'a window frame, a mug of hot water in front of a wall, a '
                'hand against a cool background. Hold still and tap '
                'Calibrate.',
              ),
              const SizedBox(height: 12),
              if (data == null)
                const AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                AspectRatio(
                  aspectRatio: data.aspectRatio,
                  child: CustomPaint(painter: ScenePainter(data)),
                ),
              const SizedBox(height: 12),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_message!),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: _busy ? null : _calibrate,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.center_focus_strong),
                    label: const Text('Calibrate'),
                  ),
                  if (_result?.mirrored ?? false)
                    OutlinedButton(
                      onPressed: _busy ? null : _mirrorAndRetry,
                      child: const Text('Mirror thermal image and retry'),
                    ),
                  if (_result != null)
                    FilledButton.tonal(
                      onPressed: _busy ? null : _save,
                      child: const Text('Save'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

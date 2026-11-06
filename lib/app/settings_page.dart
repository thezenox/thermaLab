import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../capture/capture_service.dart';
import '../probe/probe_controller.dart';
import '../probe/probe_page.dart';
import '../overlay/overlay_engine.dart';
import '../overlay/overlay_feature.dart';
import '../overlay/visible_camera.dart';
import '../render/palette.dart';
import '../t2s/t2s_frame.dart' show CameraFamily;
import 'overlay_calibration_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.capture,
    required this.overlay,
  });

  final ProbeController controller;
  final CaptureService capture;
  final OverlayEngine overlay;

  @override
  Widget build(BuildContext context) {
    final ProbeController c = controller;
    return ListenableBuilder(
      listenable: Listenable.merge(
        <Listenable>[c, capture, capture.csv, overlay.camera],
      ),
      builder: (BuildContext context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          children: <Widget>[
            if (c.streaming)
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: Text(c.cameraName),
                subtitle: Text(
                  c.family == CameraFamily.tiny1c
                      ? 'Tiny1-C protocol: the camera calibrates itself'
                      : 'Xtherm protocol, hardware revision '
                            '${c.settings.revision.name.toUpperCase()}',
                ),
              ),
            const _Section('Display'),
            ListTile(
              title: const Text('Colour palette'),
              trailing: DropdownButton<Palette>(
                value: c.palette,
                underline: const SizedBox.shrink(),
                items: <DropdownMenuItem<Palette>>[
                  for (final Palette p in Palette.all)
                    DropdownMenuItem<Palette>(value: p, child: Text(p.name)),
                ],
                onChanged: (Palette? p) {
                  if (p != null) c.setPalette(p);
                },
              ),
            ),
            SwitchListTile(
              title: const Text('Mirror image'),
              subtitle: const Text('Flip the thermal image left/right'),
              value: c.mirror,
              onChanged: (bool v) => c.applySetting('mirror', v),
            ),
            ListTile(
              title: const Text('Rotate image'),
              subtitle: Text('${c.quarterTurns * 90}°'),
              trailing: const Icon(Icons.rotate_90_degrees_cw),
              onTap: c.rotate,
            ),
            SwitchListTile(
              title: const Text('Fixed temperature scale'),
              subtitle: Text(
                c.fixedScale
                    ? '${c.fixedMin.toStringAsFixed(0)} … '
                          '${c.fixedMax.toStringAsFixed(0)} °C'
                    : 'Off: the scale follows the scene',
              ),
              value: c.fixedScale,
              onChanged: (bool v) => c.applySetting('fixedScale', v),
            ),
            if (c.fixedScale)
              RangeSlider(
                values: RangeValues(
                  c.fixedMin.clamp(-20, 450).toDouble(),
                  c.fixedMax.clamp(-20, 450).toDouble(),
                ),
                min: -20,
                max: 200,
                divisions: 220,
                labels: RangeLabels(
                  '${c.fixedMin.toStringAsFixed(0)} °C',
                  '${c.fixedMax.toStringAsFixed(0)} °C',
                ),
                onChanged: (RangeValues v) {
                  if (v.end - v.start < 1) return;
                  c.applySetting('fixedMin', v.start.roundToDouble());
                  c.applySetting('fixedMax', v.end.roundToDouble());
                },
              ),
            ListTile(
              enabled: !c.fixedScale,
              title: const Text('Minimum colour span'),
              subtitle: Text(
                'The scale never gets narrower than '
                '${c.minSpan.toStringAsFixed(0)} °C, so evenly warm scenes '
                'stay calm instead of showing sensor noise.',
              ),
            ),
            Slider(
              value: c.minSpan.clamp(0, 20).toDouble(),
              min: 0,
              max: 20,
              divisions: 20,
              label: '${c.minSpan.toStringAsFixed(0)} °C',
              onChanged: c.fixedScale ? null : c.setMinSpan,
            ),
            const ListTile(
              leading: Icon(Icons.edit_note),
              title: Text('Arrange the display'),
              subtitle: Text(
                'Use the edit button at the top right of the main screen to '
                'show or hide clock, colour scale and markers and to move '
                'them.',
              ),
            ),
            ListTile(
              title: const Text('Outline around marker labels'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 0, label: Text('Shadow')),
                    ButtonSegment<int>(value: 1, label: Text('Normal')),
                    ButtonSegment<int>(value: 2, label: Text('Thick')),
                  ],
                  selected: <int>{c.labelOutline},
                  onSelectionChanged: (Set<int> v) =>
                      c.applySetting('labelOutline', v.first),
                ),
              ),
            ),
            const _Section('Shutter'),
            SwitchListTile(
              title: const Text('Automatic shutter'),
              subtitle: const Text(
                'Re-calibrates on its own as the camera warms up.',
              ),
              value: c.autoShutter,
              onChanged: c.setAutoShutter,
            ),
            SwitchListTile(
              title: const Text('Lens shading correction'),
              subtitle: Text(
                c.flatField == null
                    ? 'Not measured yet'
                    : 'Evens out warmer edges and a cooler centre',
              ),
              value: c.flatFieldEnabled && c.flatField != null,
              onChanged: c.flatField == null
                  ? null
                  : (bool v) => c.applySetting('flatField', v),
            ),
            ListTile(
              title: const Text('Measure lens shading'),
              subtitle: const Text(
                'Point the camera at an evenly warm surface first',
              ),
              trailing: const Icon(Icons.blur_circular),
              onTap: c.streaming && !c.busy
                  ? () => _measureShading(context, c)
                  : null,
            ),
            if (c.flatField != null)
              ListTile(
                title: const Text('Remove lens shading correction'),
                leading: const Icon(Icons.restart_alt),
                onTap: c.resetFlatField,
              ),
            if (kCameraOverlayEnabled) ...<Widget>[
            const _Section('Camera overlay'),
            ListTile(
              title: const Text('Calibrate overlay'),
              subtitle: Text(
                overlay.camera.calibrated == null
                    ? 'Not calibrated yet'
                    : 'Calibrated (match '
                          '${(overlay.camera.calibrated!.score * 100).round()} %)',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => OverlayCalibrationPage(
                    controller: c,
                    overlay: overlay,
                  ),
                ),
              ),
            ),
            ListTile(
              title: const Text('Overlay style'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SegmentedButton<OverlayMode>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<OverlayMode>>[
                    ButtonSegment<OverlayMode>(
                      value: OverlayMode.edges,
                      label: Text('Edges'),
                    ),
                    ButtonSegment<OverlayMode>(
                      value: OverlayMode.blend,
                      label: Text('Blend'),
                    ),
                  ],
                  selected: <OverlayMode>{overlay.camera.mode},
                  onSelectionChanged: (Set<OverlayMode> v) =>
                      overlay.camera.setMode(v.first),
                ),
              ),
            ),
            ListTile(
              title: Text(
                overlay.camera.mode == OverlayMode.edges
                    ? 'Edge strength'
                    : 'Camera share',
              ),
              subtitle: Slider(
                value: overlay.camera.strength,
                onChanged: overlay.camera.setStrength,
              ),
            ),
            SwitchListTile(
              title: const Text('Follow distance (parallax)'),
              subtitle: const Text(
                'Keeps re-aligning while you move, since the two cameras '
                'are about 10 cm apart.',
              ),
              value: overlay.camera.liveAlign,
              onChanged: overlay.camera.setLiveAlign,
            ),
            if (overlay.camera.calibrated != null)
              ListTile(
                title: const Text('Reset overlay calibration'),
                leading: const Icon(Icons.restart_alt),
                onTap: overlay.camera.resetCalibration,
              ),
            ],
            const _Section('Temperature log'),
            SwitchListTile(
              title: const Text('CSV logging'),
              subtitle: const Text(
                'Adds a CSV record/pause button. Logs hottest, coldest, '
                'centre and measurement points over time.',
              ),
              value: capture.csv.enabled,
              onChanged: capture.csv.setEnabled,
            ),
            if (capture.csv.enabled)
              ListTile(
                title: const Text('Log interval'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SegmentedButton<double>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<double>>[
                      ButtonSegment<double>(value: 0.5, label: Text('0.5 s')),
                      ButtonSegment<double>(value: 1, label: Text('1 s')),
                      ButtonSegment<double>(value: 5, label: Text('5 s')),
                      ButtonSegment<double>(value: 10, label: Text('10 s')),
                    ],
                    selected: <double>{capture.csv.interval},
                    onSelectionChanged: (Set<double> v) =>
                        capture.csv.setInterval(v.first),
                  ),
                ),
              ),
            const _Section('Live stream'),
            SwitchListTile(
              title: const Text('Stream to browsers'),
              subtitle: const Text(
                'Anyone in the same Wi-Fi can open the address. '
                'No password.',
              ),
              value: capture.streaming,
              onChanged: (bool on) async {
                final String? error = await capture.setStreaming(on);
                if (error != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(error)),
                  );
                }
              },
            ),
            if (capture.streaming) ...<Widget>[
              SwitchListTile(
                title: const Text('Allow remote control'),
                subtitle: const Text(
                  'Viewers can set measurement points, trigger the shutter, '
                  'take photos, record videos and change display settings. '
                  'Files are saved on this phone.',
                ),
                value: capture.remoteControl,
                onChanged: capture.setRemoteControl,
              ),
              ListTile(
                title: const Text('Stream frame rate'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<int>>[
                      ButtonSegment<int>(value: 5, label: Text('5')),
                      ButtonSegment<int>(value: 10, label: Text('10')),
                      ButtonSegment<int>(value: 15, label: Text('15')),
                      ButtonSegment<int>(value: 25, label: Text('25 fps')),
                    ],
                    selected: <int>{capture.streamFps},
                    onSelectionChanged: (Set<int> v) =>
                        capture.setStreamFps(v.first),
                  ),
                ),
              ),
              ListTile(
                title: SelectableText(
                  capture.streamUrl ?? 'No Wi-Fi address found',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                subtitle: Text(
                  '${capture.liveServer.viewerCount} viewer(s) connected',
                ),
                trailing: capture.streamUrl == null
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            tooltip: 'Copy',
                            icon: const Icon(Icons.copy),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: capture.streamUrl!),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Share',
                            icon: const Icon(Icons.share),
                            onPressed: () => SharePlus.instance.share(
                              ShareParams(
                                uri: Uri.parse(capture.streamUrl!),
                                subject: 'Thermal camera live view',
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
            const _Section('Advanced'),
            ListTile(
              title: const Text('Diagnostics'),
              subtitle: const Text(
                'Raw data, model options, manual calibration, log export',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProbePage(controller: c),
                ),
              ),
            ),
            const AboutListTile(
              applicationName: 'thermaLab',
              applicationLegalese: 'GNU General Public License v3.0',
              child: Text('About'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _measureShading(BuildContext context, ProbeController c) async {
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('Measure lens shading'),
      content: const Text(
        'Point the camera at a surface that has the same temperature '
        'everywhere: a plain wall, a closed door, or a sheet of paper held '
        'a few centimetres in front of the lens (blurry is fine). Keep it '
        'filling the whole picture and hold still for about three seconds.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Start'),
        ),
      ],
    ),
  );
  if (go != true) return;
  final String message = await c.calibrateFlatField();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

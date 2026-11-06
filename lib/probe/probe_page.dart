import 'package:flutter/material.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

import '../render/geometry.dart';
import '../render/palette.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import 'probe_controller.dart';

/// Diagnostic screen: finds the camera, shows what it sends and lets every
/// control command and calibration step be tried by hand.
class ProbePage extends StatefulWidget {
  const ProbePage({super.key, required this.controller});

  final ProbeController controller;

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  ProbeController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Diagnostics'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Search devices',
              icon: const Icon(Icons.usb),
              onPressed: c.busy ? null : c.refreshDevices,
            ),
            IconButton(
              tooltip: 'Export snapshot',
              icon: const Icon(Icons.ios_share),
              onPressed: c.frame == null ? null : c.exportSnapshot,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            _statusCard(),
            if (!c.streaming) _deviceList(),
            if (c.streaming) ...<Widget>[
              _imageView(),
              const SizedBox(height: 8),
              _scaleBar(),
              const SizedBox(height: 8),
              _readouts(),
              const SizedBox(height: 12),
              _modelControls(),
              const SizedBox(height: 12),
              _cameraControls(),
            ],
            const SizedBox(height: 12),
            _metadata(),
            _log(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final UvcUsbDevice? d = c.device;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                c.status,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (d != null)
                Text(
                  '${d.displayName}  •  USB ${usbId(d.vendorId, d.productId)}'
                  '${kKnownV2UsbIds.contains(usbId(d.vendorId, d.productId)) ? '  (known V2 ID)' : ''}',
                ),
              if (c.mode != null) Text('Mode ${c.mode!.label}'),
              if (c.streaming)
                Text(
                  '${c.fps.toStringAsFixed(1)} fps  •  '
                  '${c.framesReceived} frames  •  '
                  '${c.undecodableFrames} undecodable',
                ),
              if (c.lastFrameInfo.isNotEmpty) Text(c.lastFrameInfo),
              if (c.busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceList() {
    if (c.devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'No camera found. Plug in the T2S+ and tap the USB icon.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final UvcUsbDevice d in c.devices)
          ListTile(
            leading: const Icon(Icons.videocam),
            title: Text(d.displayName),
            subtitle: Text(
              'USB ${usbId(d.vendorId, d.productId)}'
              '${d.manufacturerName.isEmpty ? '' : ' • ${d.manufacturerName}'}',
            ),
            trailing: FilledButton(
              onPressed: c.busy ? null : () => c.connect(d),
              child: const Text('Connect'),
            ),
          ),
      ],
    );
  }

  Widget _imageView() {
    final T2sFrame? f = c.frame;
    if (f == null || c.image == null) {
      return const AspectRatio(
        aspectRatio: 4 / 3,
        child: Center(child: Text('Waiting for frames…')),
      );
    }
    final int turns = c.quarterTurns;
    return AspectRatio(
      aspectRatio: turns.isOdd ? f.height / f.width : f.width / f.height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          return GestureDetector(
            onTapDown: (TapDownDetails details) {
              final (double u, double v) = displayToSensor(
                details.localPosition.dx / box.maxWidth,
                details.localPosition.dy / box.maxHeight,
                turns,
              );
              c.setPoint((
                (u * f.width).floor().clamp(0, f.width - 1),
                (v * f.height).floor().clamp(0, f.height - 1),
              ));
            },
            onLongPress: () => c.setPoint(null),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                RotatedBox(
                  quarterTurns: turns,
                  child: RawImage(
                    image: c.image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                CustomPaint(
                  painter: _OverlayPainter(
                    width: f.width,
                    height: f.height,
                    stats: c.stats,
                    point: c.point,
                    quarterTurns: turns,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _scaleBar() {
    final FrameStats? s = c.stats;
    if (s == null) return const SizedBox.shrink();
    final bool temp = c.displaySource == DisplaySource.temperature &&
        !s.centerTemp.isNaN;
    String fmt(double v) =>
        temp ? '${v.toStringAsFixed(1)} °C' : v.toStringAsFixed(0);
    return Row(
      children: <Widget>[
        SizedBox(width: 72, child: Text(fmt(s.scaleLow))),
        Expanded(
          child: Container(
            height: 14,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[
                  for (int i = 0; i < 256; i += 32)
                    Color(_abgrToArgb(c.palette.rgba[i])),
                  Color(_abgrToArgb(c.palette.rgba[255])),
                ],
              ),
            ),
          ),
        ),
        SizedBox(
          width: 72,
          child: Text(fmt(s.scaleHigh), textAlign: TextAlign.right),
        ),
      ],
    );
  }

  static int _abgrToArgb(int v) =>
      (v & 0xFF00FF00) | ((v & 0xFF) << 16) | ((v >> 16) & 0xFF);

  Widget _readouts() {
    final FrameStats? s = c.stats;
    if (s == null) return const SizedBox.shrink();
    String t(double? v) =>
        v == null ? '–' : (v.isNaN ? 'NaN' : '${v.toStringAsFixed(1)} °C');
    Widget cell(String label, String value, String sub) => Expanded(
      child: Column(
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 12)),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          Text(sub, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            cell('Centre', t(s.centerTemp), 'count ${s.centerCount}'),
            cell(
              'Point',
              t(s.pointTemp),
              s.pointCount == null ? 'tap image' : 'count ${s.pointCount}',
            ),
            cell('Min', t(s.minTemp), 'count ${s.minCount}'),
            cell('Max', t(s.maxTemp), 'count ${s.maxCount}'),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'mean count ${s.meanCount.toStringAsFixed(0)}  •  '
          'std ${s.stdDev.toStringAsFixed(1)}  •  '
          'NaN entries in table ${s.nanCount}/$kTableSize',
          style: TextStyle(
            fontSize: 12,
            color: s.nanCount > 0 ? Colors.orange : null,
          ),
        ),
      ],
    );
  }

  Widget _modelControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Model'),
        const SizedBox(height: 4),
        SegmentedButton<HardwareRevision>(
          segments: const <ButtonSegment<HardwareRevision>>[
            ButtonSegment<HardwareRevision>(
              value: HardwareRevision.v1,
              label: Text('V1 (camera corrects)'),
            ),
            ButtonSegment<HardwareRevision>(
              value: HardwareRevision.v2,
              label: Text('V2 (app corrects)'),
            ),
          ],
          selected: <HardwareRevision>{c.settings.revision},
          onSelectionChanged: (Set<HardwareRevision> v) =>
              c.setRevision(v.first),
        ),
        const SizedBox(height: 8),
        SegmentedButton<ShutterSource>(
          segments: const <ButtonSegment<ShutterSource>>[
            ButtonSegment<ShutterSource>(
              value: ShutterSource.register,
              label: Text('Shutter register'),
            ),
            ButtonSegment<ShutterSource>(
              value: ShutterSource.fpa,
              label: Text('Shutter = sensor temp'),
            ),
          ],
          selected: <ShutterSource>{c.settings.shutterSource},
          onSelectionChanged: (Set<ShutterSource> v) =>
              c.setShutterSource(v.first),
        ),
        const SizedBox(height: 8),
        SegmentedButton<DisplaySource>(
          segments: const <ButtonSegment<DisplaySource>>[
            ButtonSegment<DisplaySource>(
              value: DisplaySource.temperature,
              label: Text('°C'),
            ),
            ButtonSegment<DisplaySource>(
              value: DisplaySource.correctedCounts,
              label: Text('Corrected'),
            ),
            ButtonSegment<DisplaySource>(
              value: DisplaySource.rawCounts,
              label: Text('Raw counts'),
            ),
          ],
          selected: <DisplaySource>{c.displaySource},
          onSelectionChanged: (Set<DisplaySource> v) =>
              c.setDisplaySource(v.first),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Text('Palette  '),
            DropdownButton<Palette>(
              value: c.palette,
              items: <DropdownMenuItem<Palette>>[
                for (final Palette p in Palette.all)
                  DropdownMenuItem<Palette>(value: p, child: Text(p.name)),
              ],
              onChanged: (Palette? p) {
                if (p != null) c.setPalette(p);
              },
            ),
            const Spacer(),
            Text(
              'shutter offset ${c.settings.shutterOffset.toStringAsFixed(2)}\n'
              'user offset ${c.settings.userOffset.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.right,
            ),
          ],
        ),
      ],
    );
  }

  Widget _cameraControls() {
    final bool idle = !c.busy;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        FilledButton.tonal(
          onPressed: idle ? c.runShutterCorrection : null,
          child: const Text('Shutter correction (V2)'),
        ),
        OutlinedButton(
          onPressed: idle ? c.triggerShutter : null,
          child: const Text('Shutter click'),
        ),
        OutlinedButton(
          onPressed: idle
              ? () => c.sendCommand(0x8004, 'raw mode')
              : null,
          child: const Text('Raw mode'),
        ),
        OutlinedButton(
          onPressed: idle ? c.writeDefaultParameters : null,
          child: const Text('Write ε=0.95 params'),
        ),
        OutlinedButton(
          onPressed: idle ? () => c.setRange(MeasurementRange.normal) : null,
          child: const Text('Range −20…120'),
        ),
        OutlinedButton(
          onPressed: idle ? () => c.setRange(MeasurementRange.high) : null,
          child: const Text('Range 120…450'),
        ),
        FilterChip(
          label: const Text('Anchor at model level'),
          selected: c.anchorToModel,
          onSelected: c.setAnchorToModel,
        ),
        FilterChip(
          label: const Text('Auto shutter'),
          selected: c.autoShutter,
          onSelected: c.setAutoShutter,
        ),
        FilledButton.tonal(
          onPressed: idle ? _askCalibration : null,
          child: Text(
            c.point == null ? 'Calibrate centre…' : 'Calibrate point…',
          ),
        ),
        OutlinedButton(
          onPressed: idle ? c.resetCalibration : null,
          child: const Text('Reset calibration'),
        ),
        OutlinedButton(
          onPressed: idle ? c.clearShutterCorrection : null,
          child: const Text('Clear correction'),
        ),
        OutlinedButton.icon(
          onPressed: c.rotate,
          icon: const Icon(Icons.rotate_90_degrees_cw),
          label: Text('Rotate (${c.quarterTurns * 90}°)'),
        ),
        OutlinedButton(
          onPressed: idle ? () => c.disconnect(keepLog: true) : null,
          child: const Text('Disconnect'),
        ),
      ],
    );
  }

  Future<void> _askCalibration() async {
    final TextEditingController input = TextEditingController();
    final double? value = await showDialog<double>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Known temperature'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Measure the same spot with the Xtherm app or a thermometer '
              'and enter that value. Use a large, matte surface (a wall, '
              'a book, a mug of water) and let the camera warm up for a '
              'few minutes first. Tap the image first to calibrate a '
              'point instead of the centre.',
            ),
            TextField(
              controller: input,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              decoration: const InputDecoration(suffixText: '°C'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              double.tryParse(input.text.replaceAll(',', '.')),
            ),
            child: const Text('Calibrate'),
          ),
        ],
      ),
    );
    if (value != null) await c.calibrateTo(value);
  }

  Widget _metadata() {
    final T2sFrame? f = c.frame;
    if (f == null) return const SizedBox.shrink();
    final Map<String, Object?> rows = <String, Object?>{
      'camera': c.cameraName,
      'protocol': c.family.name,
      if (f.meta != null) ...<String, Object?>{
        'fpaTemp (°C)': f.meta!.fpaTemp(f.profile!),
        'model shutter temp (°C)': c.table?.shutterTemp,
        ...f.meta!.toJson(),
      },
    };
    return ExpansionTile(
      title: const Text('Frame metadata'),
      children: <Widget>[
        for (final MapEntry<String, Object?> e in rows.entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(e.key)),
                Text(
                  e.value is double
                      ? (e.value as double).toStringAsFixed(4)
                      : '${e.value}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _log() {
    return ExpansionTile(
      title: Text('Log (${c.logLines.length})'),
      initiallyExpanded: true,
      children: <Widget>[
        for (final String line in c.logLines.reversed.take(80))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                line,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
      ],
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.width,
    required this.height,
    required this.stats,
    required this.point,
    required this.quarterTurns,
  });

  final int width;
  final int height;
  final FrameStats? stats;
  final (int, int)? point;
  final int quarterTurns;

  @override
  void paint(Canvas canvas, Size size) {
    final FrameStats? s = stats;
    if (s == null) return;
    Offset at((int, int) p) {
      final (double a, double b) = sensorToDisplay(
        (p.$1 + 0.5) / width,
        (p.$2 + 0.5) / height,
        quarterTurns,
      );
      return Offset(a * size.width, b * size.height);
    }
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    void cross(Offset o, Color color, String label) {
      stroke.color = Colors.black54;
      stroke.strokeWidth = 3;
      canvas.drawLine(o - const Offset(8, 0), o + const Offset(8, 0), stroke);
      canvas.drawLine(o - const Offset(0, 8), o + const Offset(0, 8), stroke);
      stroke.color = color;
      stroke.strokeWidth = 1.5;
      canvas.drawLine(o - const Offset(8, 0), o + const Offset(8, 0), stroke);
      canvas.drawLine(o - const Offset(0, 8), o + const Offset(0, 8), stroke);
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            shadows: const <Shadow>[Shadow(blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o + const Offset(6, 4));
    }

    String t(double v) => v.isNaN ? '' : '${v.toStringAsFixed(1)}°';
    cross(at((width ~/ 2, height ~/ 2)), Colors.white, t(s.centerTemp));
    cross(at(s.hottest), Colors.redAccent, t(s.maxTemp));
    cross(at(s.coldest), Colors.lightBlueAccent, t(s.minTemp));
    if (point != null && s.pointTemp != null) {
      cross(at(point!), Colors.yellowAccent, t(s.pointTemp!));
    }
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => true;
}


import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/scene_builder.dart';
import '../probe/probe_controller.dart';
import '../render/palette.dart';
import '../render/scene_painter.dart';
import '../overlay/visible_camera.dart';
import 'csv_logger.dart';
import 'live_server.dart';

const String kAlbum = 'thermaLab';

/// Photos, video recording and the live stream, all fed from the composed
/// scene so they show exactly what the viewer shows.
class CaptureService extends ChangeNotifier {
  CaptureService(this.controller, this.csv, this.camera) {
    controller.frameTick.addListener(_onFrame);
    liveServer.onCommand = _onRemoteCommand;
    liveServer.csvRowsProvider = (int from) => (csv.fileName, csv.rowsFrom(from));
    liveServer.csvProvider = () async {
      final String? content = await csv.currentContent();
      final String? name = csv.fileName;
      return content == null || name == null ? null : (name, content);
    };
    unawaited(_loadStreamPreferences());
  }

  final ProbeController controller;
  final CsvLogger csv;
  final VisibleCamera camera;
  static const MethodChannel _video = MethodChannel('t2s_thermal/video');

  // Recording.
  bool get recording => _recordStart != null;
  DateTime? _recordStart;
  String? _videoPath;
  Size _videoSize = const Size(480, 640);
  final Stopwatch _sinceVideoFrame = Stopwatch();
  bool _videoFrameBusy = false;
  static const Duration _videoFrameInterval = Duration(milliseconds: 66);

  Duration get recordingDuration => _recordStart == null
      ? Duration.zero
      : DateTime.now().difference(_recordStart!);

  /// Ticks once a second while recording, for the elapsed-time badge.
  Timer? _recordTicker;

  // Live stream.
  final LiveServer liveServer = LiveServer(
    page: () => rootBundle.loadString('assets/web/index.html'),
  );
  bool get streaming => liveServer.running;
  String? streamUrl;
  final Stopwatch _sinceStreamFrame = Stopwatch();
  double _streamCredit = 0;

  /// Whether viewers may control the camera from the browser.
  bool remoteControl = false;

  /// Frames per second sent to browsers.
  int streamFps = 15;

  Future<void> _loadStreamPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    remoteControl = prefs.getBool('remoteControl') ?? false;
    streamFps = prefs.getInt('streamFps') ?? 15;
    notifyListeners();
    if (prefs.getBool('streaming') ?? false) await setStreaming(true);
  }

  Future<void> setRemoteControl(bool on) async {
    remoteControl = on;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remoteControl', on);
  }

  Future<void> setStreamFps(int fps) async {
    streamFps = fps;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('streamFps', fps);
  }

  /// Output size for photos/video/stream: 480x640 in the image's aspect.
  Size _outputSize(SceneData data, {double longSide = 640}) {
    final double shortSide = longSide * 0.75;
    return data.aspectRatio < 1
        ? Size(shortSide, longSide)
        : Size(longSide, shortSide);
  }

  // ---------------------------------------------------------------------
  // Photo
  // ---------------------------------------------------------------------

  /// Saves the current view to the gallery. Returns an error message or null.
  Future<String?> takePhoto() async {
    final SceneData? data = buildScene(controller, camera: camera);
    if (data == null) return 'No image yet';
    // Render first: a permission dialog would send the app to the
    // background, where the GPU cannot rasterize.
    Uint8List? png;
    for (final double longSide in <double>[1280, 640]) {
      try {
        final ui.Image img = await renderScene(
          data,
          _outputSize(data, longSide: longSide),
        );
        final ByteData? bytes = await img.toByteData(
          format: ui.ImageByteFormat.png,
        );
        img.dispose();
        png = bytes?.buffer.asUint8List();
        if (png != null) break;
      } catch (e) {
        debugPrint('[capture] photo render at $longSide failed: $e');
      }
    }
    if (png == null) return 'Could not render the photo';
    try {
      if (!await Gal.hasAccess(toAlbum: true) &&
          !await Gal.requestAccess(toAlbum: true)) {
        return 'No permission to save to the gallery';
      }
      await Gal.putImageBytes(
        png,
        album: kAlbum,
        name: 'thermal_${_fileStamp(data.timestamp)}',
      );
      return null;
    } catch (e) {
      return 'Photo failed: $e';
    }
  }

  // ---------------------------------------------------------------------
  // Video
  // ---------------------------------------------------------------------

  Future<String?> startRecording() async {
    final SceneData? data = buildScene(controller, camera: camera);
    if (data == null) return 'No image yet';
    try {
      if (!await Gal.hasAccess(toAlbum: true) &&
          !await Gal.requestAccess(toAlbum: true)) {
        return 'No permission to save to the gallery';
      }
      final Directory dir = await getTemporaryDirectory();
      _videoSize = _outputSize(data);
      _videoPath = '${dir.path}/thermal_${_fileStamp(DateTime.now())}.mp4';
      await _video.invokeMethod<void>('start', <String, Object>{
        'path': _videoPath!,
        'width': _videoSize.width.round(),
        'height': _videoSize.height.round(),
        'fps': 15,
      });
      _recordStart = DateTime.now();
      _sinceVideoFrame
        ..reset()
        ..start();
      _recordTicker?.cancel();
      _recordTicker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => notifyListeners(),
      );
      notifyListeners();
      return null;
    } catch (e) {
      _recordStart = null;
      return 'Recording failed: $e';
    }
  }

  /// Stops recording and saves the video. Returns an error message or null.
  Future<String?> stopRecording() async {
    if (!recording) return null;
    _recordStart = null;
    _recordTicker?.cancel();
    _recordTicker = null;
    notifyListeners();
    try {
      final String? path = await _video.invokeMethod<String>('stop');
      if (path == null) return 'Recording produced no file';
      await Gal.putVideo(path, album: kAlbum);
      await File(path).delete();
      return null;
    } catch (e) {
      return 'Saving the video failed: $e';
    }
  }

  // ---------------------------------------------------------------------
  // Live stream
  // ---------------------------------------------------------------------

  Future<String?> setStreaming(bool on) async {
    try {
      if (on) {
        await liveServer.start();
        streamUrl = await liveServer.url();
        _sinceStreamFrame
          ..reset()
          ..start();
      } else {
        await liveServer.stop();
        streamUrl = null;
      }
      notifyListeners();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('streaming', on);
      return null;
    } catch (e) {
      notifyListeners();
      return 'Live stream failed: $e';
    }
  }

  // ---------------------------------------------------------------------
  // Frame fan-out
  // ---------------------------------------------------------------------

  void _onFrame() {
    if (recording &&
        !_videoFrameBusy &&
        _sinceVideoFrame.elapsed >= _videoFrameInterval) {
      _sinceVideoFrame
        ..reset()
        ..start();
      unawaited(_sendVideoFrame());
    }
    if (liveServer.hasViewers) {
      // Frame credit: the camera delivers 25 fps, so a plain minimum
      // interval would round 15 fps down to every second frame (12.5).
      _streamCredit = (_streamCredit +
              _sinceStreamFrame.elapsedMicroseconds * streamFps / 1e6)
          .clamp(0.0, 2.0);
      _sinceStreamFrame
        ..reset()
        ..start();
      if (_streamCredit >= 1) {
        _streamCredit -= 1;
        _sendStreamFrame();
      }
    }
  }

  Future<void> _sendVideoFrame() async {
    final SceneData? data = buildScene(controller, camera: camera);
    if (data == null) return;
    _videoFrameBusy = true;
    try {
      final ui.Image img = await renderScene(data, _videoSize);
      final ByteData? rgba = await img.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      img.dispose();
      if (rgba != null && recording) {
        await _video.invokeMethod<void>('frame', rgba.buffer.asUint8List());
      }
    } catch (e) {
      debugPrint('[capture] video frame failed: $e');
    } finally {
      _videoFrameBusy = false;
    }
  }

  /// Sends the latest frame to every viewer that has drawn the previous one.
  void _sendStreamFrame() {
    final List<LiveClient> ready = liveServer.clients
        .where((LiveClient c) => c.ready)
        .toList();
    if (ready.isEmpty) return;
    final SceneData? scene = buildScene(controller, camera: camera);
    final Int16List? grid = controller.temperatureGrid();
    if (scene == null || grid == null) return;
    final Int16List temps = deltaEncodeTenths(grid, scene.sensorWidth);

    final Map<String, Object?> header = <String, Object?>{
      'w': scene.sensorWidth,
      'h': scene.sensorHeight,
      'lo': scene.scaleLow,
      'hi': scene.scaleHigh,
      'time': formatTimestamp(scene.timestamp),
      'markers': <Map<String, Object?>>[
        for (final SceneMarker m in scene.markers)
          <String, Object?>{
            'k': m.kind.name,
            'x': m.x,
            'y': m.y,
            't': m.temperature == null || m.temperature!.isNaN
                ? null
                : m.temperature,
            if (m.label != null) 'l': m.label,
          },
      ],
      'points': <int>[
        for (final MeasurePoint p in controller.measurePoints) p.id,
      ],
      'settings': controller.viewSettings(),
      'palettes': <String>[for (final Palette p in Palette.all) p.name],
      'remote': remoteControl,
      'recording': recording,
      'recordSeconds': recordingDuration.inSeconds,
      'busy': controller.busy,
      'csv': <String, Object?>{
        'enabled': csv.enabled,
        'recording': csv.recording,
        'rows': csv.rows,
        'hasData': csv.hasData,
        'downloadable': csv.downloadable,
        'log': csv.fileName,
        'tableRows': csv.tableRows,
        'interval': csv.interval,
      },
    };
    final String palette = controller.palette.name;
    for (final LiveClient c in ready) {
      final Map<String, Object?> h = Map<String, Object?>.of(header);
      if (c.paletteSent != palette) {
        // Colour table as 0xRRGGBB, sent once per palette change.
        h['lut'] = <int>[
          for (final int v in controller.palette.rgba)
            ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF),
        ];
        c.paletteSent = palette;
      }
      c.sendFrame(encodeFrame(h, temps));
    }
  }

  /// Executes a command from a browser viewer. Returns a message for it.
  Future<String?> _onRemoteCommand(Map<String, dynamic> cmd) async {
    if (!remoteControl) return 'Remote control is switched off on the phone';
    int? intArg(String k) => (cmd[k] as num?)?.round();
    final int? width = controller.frame?.width;
    final int? height = controller.frame?.height;
    (int, int)? sensorPoint() {
      final int? x = intArg('x');
      final int? y = intArg('y');
      if (x == null || y == null || width == null || height == null) {
        return null;
      }
      return (x.clamp(0, width - 1), y.clamp(0, height - 1));
    }

    switch (cmd['c']) {
      case 'shutter':
        unawaited(controller.runShutterCorrection());
        return null;
      case 'photo':
        return await takePhoto() ?? 'Photo saved on the phone';
      case 'record':
        if (recording) {
          return await stopRecording() ?? 'Video saved on the phone';
        }
        return await startRecording();
      case 'add':
        final (int, int)? p = sensorPoint();
        if (p == null) return null;
        return controller.addMeasurePoint(p.$1, p.$2) == null
            ? 'At most ${ProbeController.maxMeasurePoints} points'
            : null;
      case 'move':
      case 'remove':
        final int? id = intArg('id');
        final MeasurePoint? point = controller.measurePoints
            .where((MeasurePoint m) => m.id == id)
            .firstOrNull;
        if (point == null) return null;
        if (cmd['c'] == 'remove') {
          controller.removeMeasurePoint(point);
        } else {
          final (int, int)? p = sensorPoint();
          if (p != null) controller.moveMeasurePoint(point, p.$1, p.$2);
        }
        return null;
      case 'csv':
        if (!csv.enabled) return 'CSV logging is switched off on the phone';
        await csv.toggle();
        return csv.recording ? 'CSV logging running' : 'CSV logging paused';
      case 'csvNew':
        if (!csv.hasData) return null;
        await csv.finish();
        return 'Log closed. The next CSV recording starts a new file.';
      case 'set':
        final Object? key = cmd['k'];
        final Object? value = cmd['v'];
        if (key == 'csvEnabled' && value is bool) {
          await csv.setEnabled(value);
        } else if (key == 'csvInterval' && value is num) {
          await csv.setInterval(value.toDouble().clamp(0.2, 600));
        } else if (key is String) {
          await controller.applySetting(key, value);
        }
        return null;
    }
    return null;
  }

  String _fileStamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  @override
  void dispose() {
    controller.frameTick.removeListener(_onFrame);
    _recordTicker?.cancel();
    unawaited(liveServer.stop());
    if (recording) unawaited(stopRecording());
    super.dispose();
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../probe/probe_controller.dart';
import '../render/scene_painter.dart' show formatTimestamp;

/// Logs hottest, coldest, centre and measurement-point temperatures over
/// time into a CSV file on the phone.
///
/// File layout: comment lines start with `#`. Whenever the set or position
/// of measurement points changes, a `# points:` line with their sensor
/// pixel positions and a new column header follow.
class CsvLogger extends ChangeNotifier {
  CsvLogger(this.controller) {
    unawaited(_loadPreferences());
  }

  final ProbeController controller;

  /// Shows the CSV buttons in the app and the web viewer.
  bool enabled = false;

  /// Seconds between two rows.
  double interval = 1.0;

  bool get recording => _timer != null;
  bool get hasData => _file != null;
  int rows = 0;
  DateTime? _started;
  File? _file;

  /// The last finished log, still offered for download.
  File? _lastFile;
  IOSink? _sink;
  Timer? _timer;
  String? _pointSignature;

  /// Name of the log offered for download (current, else last finished).
  String? get fileName => (_file ?? _lastFile)?.uri.pathSegments.last;

  /// A log (current or last finished) can be downloaded.
  bool get downloadable => _file != null || _lastFile != null;

  Duration get elapsed =>
      _started == null ? Duration.zero : DateTime.now().difference(_started!);

  Future<void> _loadPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('csvEnabled') ?? false;
    interval = prefs.getDouble('csvInterval') ?? 1.0;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    if (!value && recording) pause();
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('csvEnabled', value);
  }

  Future<void> setInterval(double seconds) async {
    interval = seconds;
    if (recording) {
      _timer?.cancel();
      _timer = _newTimer();
    }
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('csvInterval', seconds);
  }

  /// Starts a new log, or resumes / pauses the current one.
  Future<void> toggle() async {
    if (recording) {
      pause();
      return;
    }
    if (_file == null) await _openNewFile();
    _sink!.writeln('# resumed ${formatTimestamp(DateTime.now())}');
    _timer = _newTimer();
    _writeRow();
    notifyListeners();
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _sink?.writeln('# paused ${formatTimestamp(DateTime.now())}');
    unawaited(_sink?.flush());
    notifyListeners();
  }

  /// Closes the current log and returns its file (null if there is none).
  /// The next [toggle] starts a new file.
  Future<File?> finish() async {
    _timer?.cancel();
    _timer = null;
    final File? file = _file;
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _lastFile = file;
    _file = null;
    _started = null;
    _pointSignature = null;
    rows = 0;
    notifyListeners();
    return file;
  }

  /// Current content of the log being written (for the web download).
  Future<String?> currentContent() async {
    final File? file = _file ?? _lastFile;
    if (file == null) return null;
    if (identical(file, _file)) await _sink?.flush();
    return file.readAsString();
  }

  Timer _newTimer() => Timer.periodic(
    Duration(milliseconds: (interval * 1000).round()),
    (_) => _writeRow(),
  );

  Future<void> _openNewFile() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}/csv');
    await dir.create(recursive: true);
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final String stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    _file = File('${dir.path}/thermal_$stamp.csv');
    _sink = _file!.openWrite();
    _started = now;
    rows = 0;
    _pointSignature = null;
    final f = controller.frame;
    _sink!
      ..writeln('# T2S+ Thermal temperature log')
      ..writeln('# started ${formatTimestamp(now)}')
      ..writeln('# interval_s ${interval.toStringAsFixed(1)}')
      ..writeln('# point positions are sensor pixels'
          '${f == null ? '' : ' (x 0..${f.width - 1}, y 0..${f.height - 1})'}'
          ', unrotated camera orientation')
      ..writeln('# temperatures in degrees Celsius, empty = no value');
  }

  void _writeRow() {
    final IOSink? sink = _sink;
    final FrameStats? s = controller.stats;
    if (sink == null || s == null) return;
    final List<MeasurePoint> points = controller.measurePoints;
    final String signature = points
        .map((MeasurePoint p) => '${p.id}:${p.x},${p.y}')
        .join(';');
    if (signature != _pointSignature) {
      _pointSignature = signature;
      sink.writeln(
        '# points: ${points.isEmpty ? 'none' : <String>[
                for (int i = 0; i < points.length; i++)
                  'P${i + 1}=(${points[i].x},${points[i].y})',
              ].join(' ')}',
      );
      sink.writeln(<String>[
        'time',
        'elapsed_s',
        'hottest_C',
        'coldest_C',
        'centre_C',
        for (int i = 0; i < points.length; i++) 'P${i + 1}_C',
      ].join(','));
    }
    String t(double? v) => v == null || v.isNaN ? '' : v.toStringAsFixed(2);
    final DateTime now = DateTime.now();
    sink.writeln(<String>[
      formatTimestamp(now),
      (now.difference(_started!).inMilliseconds / 1000).toStringAsFixed(1),
      t(s.maxTemp),
      t(s.minTemp),
      t(s.centerTemp),
      for (final MeasurePoint p in points) t(controller.temperatureAt(p.x, p.y)),
    ].join(','));
    rows++;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_sink?.close());
    super.dispose();
  }
}

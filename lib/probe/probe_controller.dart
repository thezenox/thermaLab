import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../render/palette.dart';
import '../render/scene_layout.dart';
import '../t2s/camera_catalog.dart';
import '../t2s/flat_field.dart';
import '../t2s/shutter_correction.dart';
import '../t2s/t2s_commands.dart';
import '../t2s/t2s_frame.dart';
import '../t2s/temperature_model.dart';
import '../t2s/tiny1c_commands.dart';

/// USB IDs of cameras known to be T2S+ V2 units.
final Set<String> kKnownV2UsbIds = <String>{
  for (final KnownCamera c in kKnownCameras)
    if (c.revision == HardwareRevision.v2) c.usbId,
};

enum DisplaySource { temperature, correctedCounts, rawCounts }

String usbId(int vendorId, int productId) =>
    '${vendorId.toRadixString(16).padLeft(4, '0')}:'
    '${productId.toRadixString(16).padLeft(4, '0')}';

/// Statistics of one processed frame.
class FrameStats {
  const FrameStats({
    required this.minCount,
    required this.maxCount,
    required this.meanCount,
    required this.stdDev,
    required this.centerCount,
    required this.minTemp,
    required this.maxTemp,
    required this.centerTemp,
    required this.centerTempAlt,
    required this.pointTempAlt,
    required this.pointCount,
    required this.pointTemp,
    required this.hottest,
    required this.coldest,
    required this.nanCount,
    required this.scaleLow,
    required this.scaleHigh,
  });

  final int minCount;
  final int maxCount;
  final double meanCount;
  final double stdDev;
  final int centerCount;
  final double minTemp;
  final double maxTemp;
  final double centerTemp;

  /// Same spots evaluated with the other [ShutterSource], for comparison.
  final double centerTempAlt;
  final double? pointTempAlt;
  final int? pointCount;
  final double? pointTemp;
  final (int, int) hottest;
  final (int, int) coldest;
  final int nanCount;
  final double scaleLow;
  final double scaleHigh;
}

class ProbeController extends ChangeNotifier {
  ProbeController() {
    _deviceEventsSub = _camera.deviceEvents.listen((UvcDeviceEvent event) {
      log('USB ${event.type.name}: ${event.device.displayName} '
          '(${usbId(event.device.vendorId, event.device.productId)})');
      if (event.type == UvcDeviceEventType.detached &&
          event.device.deviceId == device?.deviceId) {
        unawaited(disconnect(keepLog: true));
        refreshDevices();
      } else if (event.type == UvcDeviceEventType.attached && !streaming) {
        unawaited(autoConnect());
      } else {
        refreshDevices();
      }
    });
    _streamErrorSub = _camera.streamErrors.listen((UvcStreamError e) {
      log('Stream error: ${e.message}');
    });
  }

  final UvcCamera _camera = uvcCamera;
  StreamSubscription<UvcDeviceEvent>? _deviceEventsSub;
  StreamSubscription<UvcStreamError>? _streamErrorSub;

  // Connection state.
  List<UvcUsbDevice> devices = <UvcUsbDevice>[];
  UvcUsbDevice? device;
  List<UvcCameraMode> modes = <UvcCameraMode>[];
  UvcCameraMode? mode;
  bool get streaming => _pollTimer != null;
  bool busy = false;
  String status = 'Not connected';

  // Processing state.
  // Wall measurements (2026-11-06): with the closed shutter anchored at the
  // model level, taking the shutter temperature from the sensor reads about
  // 5 °C above the shutter register, matching the vendor app.
  ModelSettings settings = const ModelSettings(
    revision: HardwareRevision.v2,
    shutterSource: ShutterSource.fpa,
  );
  DisplaySource displaySource = DisplaySource.temperature;
  Palette palette = Palette.iron;

  /// Clockwise quarter turns applied to the displayed image.
  int quarterTurns = 1;

  /// Smallest temperature span the colour scale is stretched over, so a
  /// uniform scene does not turn into colourful sensor noise.
  double minSpan = 10.0;

  /// User measurement points in sensor coordinates.
  final List<MeasurePoint> measurePoints = <MeasurePoint>[];
  int _nextPointId = 1;
  static const int maxMeasurePoints = 8;

  /// Incremented whenever a new [image] is ready; capture and streaming
  /// listen to this instead of to every state change.
  final ValueNotifier<int> frameTick = ValueNotifier<int>(0);

  /// Colour scale of the latest frame, in °C.
  double scaleLow = 0;
  double scaleHigh = 1;

  /// Fixed colour scale instead of following the scene.
  bool fixedScale = false;
  double fixedMin = 15;
  double fixedMax = 40;

  /// Which overlay elements are shown and where clock and scale sit.
  SceneLayout layout = const SceneLayout();

  /// Outline around marker labels: 0 shadow only, 1 normal, 2 thick.
  int labelOutline = 1;

  /// Lens shading correction measured on a uniform surface (per camera).
  FlatField? flatField;
  bool flatFieldEnabled = true;

  /// Shutter-corrected counts before the lens shading correction, used to
  /// measure the shading.
  Uint16List? _preFlatCounts;

  /// Flip the thermal image horizontally (after rotation).
  bool mirror = false;

  /// Hottest/coldest marker positions in sensor pixels, smoothed so they
  /// glide instead of jumping across evenly warm areas.
  (double, double)? hotMarker;
  (double, double)? coldMarker;
  (int, int)? _hotTarget;
  (int, int)? _coldTarget;

  /// A new hottest/coldest pixel takes over only if it beats the current
  /// one by this much.
  static const double markerHysteresis = 0.2;

  /// Fraction of the remaining distance a marker moves per frame.
  static const double markerSmoothing = 0.35;
  ShutterCorrection? correction;
  T2sFrame? frame;
  Uint16List? processedCounts;
  TemperatureTable? table;
  FrameStats? stats;
  ui.Image? image;
  (int, int)? point;
  double fps = 0;
  int framesReceived = 0;
  int undecodableFrames = 0;
  String lastFrameInfo = '';

  final List<String> logLines = <String>[];

  Timer? _pollTimer;
  int _ticksAtLastStats = 0;
  int _lastSequence = -1;
  final Stopwatch _fpsWatch = Stopwatch();
  int _fpsFrames = 0;
  bool _rendering = false;
  bool _holdShutter = false;

  /// A shutter correction has been attempted since connecting.
  bool _correctionAttempted = false;

  /// Stream layout of the connected camera.
  CameraFamily family = CameraFamily.xtherm;

  /// Catalogue entry of the connected camera, null if unknown.
  KnownCamera? knownModel;

  /// Display name of the connected camera.
  String cameraName = '';

  /// Xtherm camera of unknown revision: decided from the first frames.
  bool _revisionPending = false;

  late final Tiny1cCommands _tiny1c = Tiny1cCommands(_camera.controlTransfer);

  /// Whether the app can trigger the camera's shutter (Tiny1-C modules
  /// calibrate on their own and offer no known command for it).
  bool get canTriggerShutter => family == CameraFamily.xtherm;

  /// True while a V2 camera streams but has no shutter reference yet: the
  /// image would still show the raw stripes, so it is not shown.
  bool get calibrationPending =>
      streaming &&
      family == CameraFamily.xtherm &&
      (_revisionPending ||
          (settings.revision == HardwareRevision.v2 &&
              correction == null &&
              !_correctionAttempted));

  /// Repeat the shutter correction on its own as the camera drifts.
  bool autoShutter = true;

  /// Anchor corrected frames at the model's shutter level (true) or at the
  /// reference mean (false, the IR-Py-Thermal behaviour).
  bool anchorToModel = true;
  double _correctionFpa = double.nan;
  final Stopwatch _correctionAge = Stopwatch();
  final Stopwatch _connectedFor = Stopwatch();

  /// The shutter takes a moment to open again; frames in that window still
  /// show the shutter and are not displayed.
  final Stopwatch _shutterReleased = Stopwatch();

  /// Sensor temperature change that triggers a new shutter correction.
  static const double reNucFpaDelta = 0.3;

  /// Minimum time between two automatic shutter corrections.
  static const Duration minReNucInterval = Duration(seconds: 20);

  void log(String message) {
    final DateTime now = DateTime.now();
    final String ts =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    logLines.add('$ts $message');
    if (logLines.length > 300) logLines.removeAt(0);
    debugPrint('[probe] $message');
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------

  Future<void> refreshDevices() async {
    try {
      devices = await _camera.listUsbDevices();
      for (final UvcUsbDevice d in devices) {
        log('Found ${d.displayName} ${usbId(d.vendorId, d.productId)} '
            'manufacturer="${d.manufacturerName}" product="${d.productName}" '
            'serial="${d.serialNumber}"');
      }
      if (devices.isEmpty) log('No UVC device found');
    } catch (e) {
      log('Listing devices failed: $e');
    }
    notifyListeners();
  }

  /// Lists devices and connects right away when exactly one known T2S+
  /// (or exactly one camera at all) is attached.
  Future<void> loadPreferences() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    quarterTurns = prefs.getInt('quarterTurns') ?? 1;
    minSpan = prefs.getDouble('minSpan') ?? 10.0;
    autoShutter = prefs.getBool('autoShutter') ?? true;
    fixedScale = prefs.getBool('fixedScale') ?? false;
    fixedMin = prefs.getDouble('fixedMin') ?? 15;
    fixedMax = prefs.getDouble('fixedMax') ?? 40;
    final String? layoutJson = prefs.getString('layout');
    final int? oldCorner = prefs.getInt('timestampCorner');
    layout = layoutJson != null
        ? SceneLayout.fromJson(jsonDecode(layoutJson) as Map<String, dynamic>)
        : (oldCorner != null
              ? SceneLayout.fromTimestampCorner(oldCorner)
              : const SceneLayout());
    labelOutline = prefs.getInt('labelOutline') ?? 1;
    mirror = prefs.getBool('mirror') ?? false;
    flatFieldEnabled = prefs.getBool('flatFieldEnabled') ?? true;
    final String? paletteName = prefs.getString('palette');
    palette = Palette.all.firstWhere(
      (Palette p) => p.name == paletteName,
      orElse: () => Palette.iron,
    );
    notifyListeners();
  }

  /// Display settings shared with the web remote.
  Map<String, Object> viewSettings() => <String, Object>{
    'palette': palette.name,
    'quarterTurns': quarterTurns,
    'minSpan': minSpan,
    'fixedScale': fixedScale,
    'fixedMin': fixedMin,
    'fixedMax': fixedMax,
    'layout': layout.toJson(),
    'labelOutline': labelOutline,
    'autoShutter': autoShutter,
    'mirror': mirror,
    'flatField': flatFieldEnabled,
    'flatFieldCalibrated': flatField != null,
  };

  /// Applies one display setting by name (from the settings page or the
  /// web remote) and persists it. Unknown keys are ignored.
  Future<void> applySetting(String key, Object? value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    double? asDouble() => value is num ? value.toDouble() : null;
    int? asInt() => value is num ? value.round() : null;
    switch (key) {
      case 'palette':
        final Palette? p = Palette.all
            .where((Palette p) => p.name == value)
            .firstOrNull;
        if (p != null) await setPalette(p);
        return;
      case 'quarterTurns':
        final int? v = asInt();
        if (v == null) return;
        quarterTurns = v % 4;
        await prefs.setInt('quarterTurns', quarterTurns);
      case 'minSpan':
        final double? v = asDouble();
        if (v == null) return;
        minSpan = v.clamp(0, 50).toDouble();
        await prefs.setDouble('minSpan', minSpan);
      case 'fixedScale':
        if (value is! bool) return;
        fixedScale = value;
        await prefs.setBool('fixedScale', value);
      case 'fixedMin':
        final double? v = asDouble();
        if (v == null) return;
        fixedMin = v;
        await prefs.setDouble('fixedMin', v);
      case 'fixedMax':
        final double? v = asDouble();
        if (v == null) return;
        fixedMax = v;
        await prefs.setDouble('fixedMax', v);
      case 'layout':
        if (value is! Map) return;
        await setLayout(
          SceneLayout.fromJson(Map<String, dynamic>.from(value), layout),
        );
        return;
      case 'labelOutline':
        final int? v = asInt();
        if (v == null) return;
        labelOutline = v.clamp(0, 2);
        await prefs.setInt('labelOutline', labelOutline);
      case 'autoShutter':
        if (value is bool) await setAutoShutter(value);
        return;
      case 'flatField':
        if (value is! bool) return;
        flatFieldEnabled = value;
        await prefs.setBool('flatFieldEnabled', value);
      case 'mirror':
        if (value is! bool) return;
        mirror = value;
        await prefs.setBool('mirror', value);
      default:
        return;
    }
    notifyListeners();
  }

  /// Changes the overlay layout; [persist] false while dragging.
  Future<void> setLayout(SceneLayout value, {bool persist = true}) async {
    layout = value;
    notifyListeners();
    if (!persist) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('layout', jsonEncode(value.toJson()));
  }

  Future<void> setMinSpan(double value) async {
    minSpan = value;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('minSpan', value);
  }

  // ---------------------------------------------------------------------
  // Measurement points
  // ---------------------------------------------------------------------

  MeasurePoint? addMeasurePoint(int x, int y) {
    if (measurePoints.length >= maxMeasurePoints) return null;
    final MeasurePoint p = MeasurePoint(_nextPointId++, x, y);
    measurePoints.add(p);
    notifyListeners();
    return p;
  }

  void moveMeasurePoint(MeasurePoint p, int x, int y) {
    p
      ..x = x
      ..y = y;
    notifyListeners();
  }

  void removeMeasurePoint(MeasurePoint p) {
    measurePoints.remove(p);
    notifyListeners();
  }

  /// Temperature of the 3x3 neighbourhood around a sensor pixel.
  double? temperatureAt(int x, int y) {
    final T2sFrame? f = frame;
    final Uint16List? counts = processedCounts;
    final TemperatureTable? t = table;
    if (f == null || counts == null || t == null) return null;
    return t.lookup(_spotCount(counts, f.width, f.height, (x, y)));
  }

  /// Per-pixel temperatures of the latest frame in 1/50 °C (sensor
  /// orientation), -32768 where the model has no value. Used by the web
  /// viewer, which colours the image itself.
  Int16List? temperatureGrid() {
    final Uint16List? counts = processedCounts;
    final TemperatureTable? t = table;
    if (counts == null || t == null) return null;
    final Int16List lut = Int16List(kTableSize);
    for (int c = 0; c < kTableSize; c++) {
      final double v = t.values[c];
      lut[c] = v.isNaN ? -32768 : (v * 50).round().clamp(-32767, 32767);
    }
    final Int16List out = Int16List(counts.length);
    for (int i = 0; i < counts.length; i++) {
      out[i] = lut[counts[i].clamp(0, kTableSize - 1)];
    }
    return out;
  }

  Future<void> autoConnect() async {
    await refreshDevices();
    if (streaming || busy) return;
    final List<UvcUsbDevice> known = devices
        .where((UvcUsbDevice d) =>
            knownCamera(usbId(d.vendorId, d.productId)) != null)
        .toList();
    final List<UvcUsbDevice> pick = known.isNotEmpty ? known : devices;
    if (pick.length == 1) {
      log('Auto-connecting to ${pick.first.displayName}');
      await connect(pick.first);
    }
  }

  Future<void> connect(UvcUsbDevice target) async {
    if (busy) return;
    busy = true;
    status = 'Opening ${target.displayName}…';
    notifyListeners();
    try {
      await disconnect(keepLog: true);
      device = target;
      final String id = usbId(target.vendorId, target.productId);
      final KnownCamera? known = knownCamera(id);
      knownModel = known;
      log('Opening $id (${known?.name ?? 'model not in the catalogue'})');
      // Android requires CAMERA before it grants USB access to a UVC device.
      final bool cameraGranted = await _camera.ensureCameraPermission();
      log('Camera permission ${cameraGranted ? 'granted' : 'DENIED'}');
      if (!cameraGranted) {
        status = 'Camera permission denied';
        return;
      }
      await _camera.openUsbDevice(target.deviceId);
      log('USB device opened');

      modes = _camera.supportedModes();
      for (final UvcCameraMode m in modes) {
        log('Mode: ${m.label} (format ${m.frameFormat})');
      }
      final StreamChoice? choice = chooseStream(<OfferedMode>[
        for (int i = 0; i < modes.length; i++)
          OfferedMode(modes[i].formatName, modes[i].width, modes[i].height, i),
      ], known);
      if (choice == null) {
        status = 'Camera not supported';
        log('No supported stream layout among the offered modes');
        return;
      }
      mode = modes[choice.modeIndex];
      family = choice.family;
      log('Protocol ${family.name}: ${choice.reason}');
      if (family == CameraFamily.tiny1c) {
        // The module corrects itself; nothing to wait for.
        settings = settings.copyWith(revision: HardwareRevision.v1);
        _revisionPending = false;
        _correctionAttempted = true;
        cameraName = known?.name ?? 'Tiny1-C thermal camera';
      } else {
        final HardwareRevision? rev = known?.revision;
        _revisionPending = rev == null;
        if (rev != null) settings = settings.copyWith(revision: rev);
        cameraName = known?.name ?? 'Xtherm thermal camera';
      }
      log('Starting ${mode!.label}');
      final UvcPreviewStartResult result = await _camera.startPreview(
        mode!,
        policy: UvcPreviewPolicy.sequenceOnly,
        timeout: const Duration(seconds: 6),
      );
      log('Preview start: success=${result.success} '
          'frames=${result.validFrameCount} errors=${result.errorCount} '
          '${result.lastError ?? ''}');
      if (!result.success) {
        status = 'Stream did not start';
        return;
      }
      _startPolling();
      _connectedFor
        ..reset()
        ..start();
      await _loadCalibration();
      status = 'Streaming';
      notifyListeners();

      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (family == CameraFamily.xtherm) {
        sendCommand(T2sCommand.rawMode, 'raw mode');
      } else {
        await _setupTiny1c();
      }
    } catch (e) {
      status = 'Connect failed';
      log('Connect failed: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
    if (!streaming || family != CameraFamily.xtherm) return;
    // Let the raw stream settle, then decide the revision if needed: V2
    // frames are unusable without a shutter reference taken by the app,
    // V1 cameras correct themselves and only need a shutter click.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!streaming) return;
    if (_revisionPending) {
      _detectRevision();
      await _loadCalibration();
    }
    if (settings.revision == HardwareRevision.v2) {
      await runShutterCorrection();
    } else {
      triggerShutter();
      _correctionAttempted = true;
      notifyListeners();
    }
  }

  /// Uncorrected V2 frames show strong pixel-to-pixel stripes, frames a V1
  /// camera has corrected itself do not.
  void _detectRevision() {
    final T2sFrame? f = frame;
    _revisionPending = false;
    if (f == null) {
      settings = settings.copyWith(revision: HardwareRevision.v2);
      log('No frame to judge the revision; assuming V2');
      return;
    }
    double sum = 0;
    int n = 0;
    for (int y = 0; y < f.height; y += 2) {
      final int row = y * f.width;
      for (int x = 1; x < f.width; x++) {
        sum += (f.counts[row + x] - f.counts[row + x - 1]).abs();
        n++;
      }
    }
    final double pixelNoise = sum / n;
    final HardwareRevision rev =
        pixelNoise > 40 ? HardwareRevision.v2 : HardwareRevision.v1;
    settings = settings.copyWith(revision: rev);
    log('Revision ${rev.name} detected (pixel-to-pixel noise '
        '${pixelNoise.toStringAsFixed(1)} counts)');
  }

  Future<void> _setupTiny1c() async {
    try {
      await _tiny1c.setEmissivity(0.95);
      log('Tiny1-C: emissivity 0.95');
    } catch (e) {
      log('Tiny1-C setup command failed: $e');
    }
  }

  Future<void> disconnect({bool keepLog = false}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _holdShutter = false;
    try {
      if (_camera.isPreviewing) await _camera.stopPreview();
      if (_camera.openedDeviceId != null) await _camera.closeUsbDevice();
    } catch (e) {
      log('Disconnect: $e');
    }
    frame = null;
    _correctionAttempted = false;
    _revisionPending = false;
    hotMarker = null;
    coldMarker = null;
    _hotTarget = null;
    _coldTarget = null;
    processedCounts = null;
    table = null;
    stats = null;
    image = null;
    correction = null;
    framesReceived = 0;
    undecodableFrames = 0;
    _lastSequence = -1;
    status = 'Not connected';
    if (!keepLog) logLines.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------

  bool sendCommand(int value, String label, {bool quiet = false}) {
    try {
      final Stopwatch sw = Stopwatch()..start();
      _camera.setControl(UvcControlId.zoomAbs, value);
      final int ms = sw.elapsedMilliseconds;
      if (!quiet) log('Sent $label (0x${value.toRadixString(16)}) in $ms ms');
      if (quiet && ms > 100) {
        debugPrint('[probe] slow control transfer $label: $ms ms');
      }
      return true;
    } catch (e) {
      log('Command $label (0x${value.toRadixString(16)}) failed: $e');
      return false;
    }
  }

  void triggerShutter() => sendCommand(T2sCommand.shutter, 'shutter');

  void setRange(MeasurementRange range) {
    if (family == CameraFamily.tiny1c) {
      // High gain = normal range, low gain = high temperature range.
      _tiny1c
          .setHighGain(range == MeasurementRange.normal)
          .then((_) => log('Tiny1-C: range ${range.name}'))
          .catchError((Object e) => log('Tiny1-C range command failed: $e'));
    } else {
      sendCommand(
        range == MeasurementRange.high
            ? T2sCommand.rangeHigh
            : T2sCommand.rangeNormal,
        'range ${range.name}',
      );
    }
    settings = settings.copyWith(range: range);
    notifyListeners();
  }

  /// Writes emissivity 0.95, 20 °C ambient/reflected, 1 m distance and
  /// commits them. Needed once on units that still report emissivity 0.02.
  Future<void> writeDefaultParameters() async {
    final List<(String, List<int>)> writes = <(String, List<int>)>[
      ('emissivity 0.95', encodeFloat(T2sParameter.emissivity, 0.95)),
      ('reflected 20 °C', encodeFloat(T2sParameter.reflectedTemp, 20)),
      ('air 20 °C', encodeFloat(T2sParameter.airTemp, 20)),
      ('distance 1 m', encodeUint16(T2sParameter.distance, 1)),
    ];
    for (final (String label, List<int> words) in writes) {
      bool ok = true;
      for (final int w in words) {
        ok &= sendCommand(w, label, quiet: true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      log('Parameter $label ${ok ? 'sent' : 'FAILED'}');
    }
    sendCommand(T2sCommand.saveParameters, 'save parameters');
  }

  /// Closes the shutter, waits until the picture stops changing and
  /// averages several frames into a per-pixel reference (V2 only).
  ///
  /// Uncorrected V2 frames carry a strong sensor gradient and column
  /// stripes that stay when the shutter is closed, so "uniform" cannot be
  /// tested directly. Instead: the picture jumps when the shutter moves in,
  /// then holds still. The difference to the open picture is logged as
  /// evidence that the shutter really closed.
  Future<void> runShutterCorrection() async {
    if (family == CameraFamily.tiny1c) {
      log('Tiny1-C cameras run their shutter calibration on their own');
      return;
    }
    if (settings.revision == HardwareRevision.v1) {
      triggerShutter();
      return;
    }
    if (busy || frame == null) return;
    busy = true;
    status = 'Shutter correction…';
    notifyListeners();
    try {
      final T2sFrame open = frame!;
      _holdShutter = true;
      unawaited(_keepShutterClosed());

      final Stopwatch settle = Stopwatch()..start();
      Uint16List? previous;
      int stable = 0;
      double change = double.nan;
      while (settle.elapsed < const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final T2sFrame? f = frame;
        if (f == null || identical(f.counts, previous)) continue;
        if (previous != null) {
          change = blockStdDev(_diff(f.counts, previous), f.width, f.height);
        }
        final double vsOpen =
            blockStdDev(_diff(f.counts, open.counts), f.width, f.height);
        debugPrint('[probe]   t=${settle.elapsedMilliseconds} ms '
            'change=${change.toStringAsFixed(1)} '
            'vsOpen=${vsOpen.toStringAsFixed(1)} '
            'mean=${countsMean(f.counts).toStringAsFixed(1)}');
        previous = f.counts;
        final bool still = change.isFinite && change < 4.0;
        stable = settle.elapsedMilliseconds > 600 && still ? stable + 1 : 0;
        if (stable >= 3) break;
      }
      final T2sFrame closed = frame!;
      final double vsOpen = blockStdDev(
        _diff(closed.counts, open.counts),
        closed.width,
        closed.height,
      );
      final double meanShift =
          countsMean(closed.counts) - countsMean(open.counts);
      log('Shutter ${stable >= 3 ? 'settled' : 'NOT settled'} after '
          '${settle.elapsedMilliseconds} ms; closed vs open: structure '
          '${vsOpen.toStringAsFixed(1)}, mean shift '
          '${meanShift.toStringAsFixed(1)}');

      final List<Uint16List> refs = <Uint16List>[];
      final Stopwatch collect = Stopwatch()..start();
      while (refs.length < 15 &&
          collect.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final T2sFrame? f = frame;
        if (f == null) continue;
        if (refs.isNotEmpty && identical(refs.last, f.counts)) continue;
        refs.add(f.counts);
      }
      if (refs.length < 5) {
        log('Shutter correction failed: only ${refs.length} frames '
            'in ${collect.elapsedMilliseconds} ms');
        return;
      }
      correction = ShutterCorrection.fromFrames(
        refs,
        closed.width,
        closed.height,
      );
      _correctionFpa = closed.meta!.fpaTemp(closed.profile!);
      _correctionAge
        ..reset()
        ..start();
      log('Reference from ${refs.length} frames, mean '
          '${correction!.referenceMean.toStringAsFixed(1)}, '
          '${correction!.deadPixels.length} dead pixels');
    } catch (e) {
      log('Shutter correction failed: $e');
    } finally {
      _holdShutter = false;
      if (!_correctionAttempted) {
        // The last rendered image is still the raw, striped one; drop it so
        // the loading screen stays until the first corrected frame. (Not
        // disposed here: a pending paint may still hold it.)
        image = null;
      }
      _correctionAttempted = true;
      _shutterReleased
        ..reset()
        ..start();
      busy = false;
      status = 'Streaming';
      notifyListeners();
    }
  }

  static Int32List _diff(Uint16List a, Uint16List b) {
    final Int32List out = Int32List(a.length);
    for (int i = 0; i < a.length; i++) {
      out[i] = a[i] - b[i];
    }
    return out;
  }

  Future<void> _keepShutterClosed() async {
    while (_holdShutter) {
      sendCommand(T2sCommand.shutter, 'shutter', quiet: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// V2 frames drift as the camera warms up. Take a new reference when the
  /// sensor temperature moved, or after a while: every minute during the
  /// first five minutes, every three minutes after that.
  void _maybeReNuc(T2sFrame f) {
    if (!autoShutter ||
        busy ||
        correction == null ||
        settings.revision != HardwareRevision.v2) {
      return;
    }
    final T2sMetadata? meta = f.meta;
    if (meta == null) return;
    final double fpa = meta.fpaTemp(f.profile!);
    final Duration interval = _connectedFor.elapsed < const Duration(minutes: 5)
        ? const Duration(minutes: 1)
        : const Duration(minutes: 3);
    final bool fpaMoved =
        _correctionFpa.isFinite && (fpa - _correctionFpa).abs() > reNucFpaDelta;
    final bool tooOld = _correctionAge.elapsed > interval;
    // While the camera warms up right after plugging in, the sensor moves
    // fast; never click the shutter more often than this.
    final bool tooSoon = _correctionAge.elapsed < minReNucInterval;
    if (!tooSoon && (fpaMoved || tooOld)) {
      log('Auto shutter correction (${fpaMoved ? 'sensor ${_correctionFpa.toStringAsFixed(2)} → ${fpa.toStringAsFixed(2)} °C' : 'after ${_correctionAge.elapsed.inSeconds} s'})');
      unawaited(runShutterCorrection());
    }
  }

  void setAnchorToModel(bool value) {
    anchorToModel = value;
    log('Shutter anchor: ${value ? 'model level' : 'reference mean'}');
  }

  Future<void> setAutoShutter(bool value) async {
    autoShutter = value;
    log('Auto shutter correction ${value ? 'on' : 'off'}');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoShutter', value);
  }

  void clearShutterCorrection() {
    correction = null;
    log('Shutter correction cleared');
  }

  // ---------------------------------------------------------------------
  // Model settings and calibration
  // ---------------------------------------------------------------------

  void setRevision(HardwareRevision revision) {
    settings = settings.copyWith(revision: revision);
    log('Model revision set to ${revision.name}');
    _loadCalibration();
  }

  void setShutterSource(ShutterSource source) {
    settings = settings.copyWith(shutterSource: source);
    log('Shutter temperature source: ${source.name}');
    _loadCalibration();
  }

  void setDisplaySource(DisplaySource source) {
    displaySource = source;
    notifyListeners();
  }

  Future<void> setPalette(Palette p) async {
    palette = p;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('palette', p.name);
  }

  Future<void> rotate() async {
    quarterTurns = (quarterTurns + 1) % 4;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('quarterTurns', quarterTurns);
  }

  void setPoint((int, int)? p) {
    point = p;
    notifyListeners();
  }

  String get _calibrationKey {
    final UvcUsbDevice? d = device;
    final String unit = d == null
        ? 'unknown'
        : '${usbId(d.vendorId, d.productId)}.${d.serialNumber}';
    return 'calibration.$unit.${settings.revision.name}.'
        '${settings.shutterSource.name}';
  }

  String get _flatFieldKey {
    final UvcUsbDevice? d = device;
    return d == null
        ? 'flatField.unknown'
        : 'flatField.${usbId(d.vendorId, d.productId)}.${d.serialNumber}';
  }

  Future<void> _loadFlatField() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? json = prefs.getString(_flatFieldKey);
    flatField = null;
    if (json == null) return;
    final Map<String, dynamic> m = jsonDecode(json) as Map<String, dynamic>;
    flatField = FlatField.fromCoefficients(
      (m['w'] as num).toInt(),
      (m['h'] as num).toInt(),
      <double>[for (final Object? v in m['c'] as List<dynamic>) (v! as num).toDouble()],
    );
    log('Loaded lens shading correction');
  }

  Future<void> resetFlatField() async {
    flatField = null;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_flatFieldKey);
    log('Lens shading correction removed');
  }

  /// Measures the lens shading on a uniform surface. Returns a message for
  /// the user.
  Future<String> calibrateFlatField() async {
    if (!streaming || frame == null) return 'No camera image';
    if (settings.revision == HardwareRevision.v2) {
      await runShutterCorrection();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    busy = true;
    status = 'Measuring lens shading…';
    notifyListeners();
    try {
      final List<Uint16List> frames = <Uint16List>[];
      final Stopwatch sw = Stopwatch()..start();
      Uint16List? last;
      while (frames.length < 25 && sw.elapsed < const Duration(seconds: 6)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final Uint16List? c = _preFlatCounts;
        if (c == null || identical(c, last)) continue;
        last = c;
        frames.add(c);
      }
      final T2sFrame? f = frame;
      if (frames.length < 10 || f == null) return 'Not enough frames';
      final FlatField? ff = FlatField.fit(frames, f.width, f.height);
      if (ff == null) return 'Could not fit the shading';
      flatField = ff;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _flatFieldKey,
        jsonEncode(<String, Object>{
          'w': ff.width,
          'h': ff.height,
          'c': ff.coefficients,
        }),
      );
      // Express the correction in °C around the current centre level.
      final TemperatureTable? t = table;
      String size = '${ff.maxOffset.toStringAsFixed(0)} counts';
      if (t != null && processedCounts != null) {
        final int centre =
            _spotCount(processedCounts!, f.width, f.height, (f.width ~/ 2, f.height ~/ 2));
        final double dT =
            (t.lookup(centre + ff.maxOffset.round()) - t.lookup(centre)).abs();
        if (dT.isFinite) size = '${dT.toStringAsFixed(1)} °C';
      }
      log('Lens shading measured from ${frames.length} frames, '
          'largest correction $size');
      return 'Lens shading corrected (up to $size at the edges)';
    } finally {
      busy = false;
      status = 'Streaming';
      notifyListeners();
    }
  }

  Future<void> _loadCalibration() async {
    await _loadFlatField();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? json = prefs.getString(_calibrationKey);
    double shutterOffset = 0;
    double userOffset = 0;
    if (json != null) {
      final Map<String, dynamic> m = jsonDecode(json) as Map<String, dynamic>;
      shutterOffset = (m['shutterOffset'] as num?)?.toDouble() ?? 0;
      userOffset = (m['userOffset'] as num?)?.toDouble() ?? 0;
      log('Loaded calibration: shutterOffset=$shutterOffset '
          'userOffset=$userOffset');
    }
    settings = settings.copyWith(
      shutterOffset: shutterOffset,
      userOffset: userOffset,
    );
    notifyListeners();
  }

  Future<void> _saveCalibration() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _calibrationKey,
      jsonEncode(<String, double>{
        'shutterOffset': settings.shutterOffset,
        'userOffset': settings.userOffset,
      }),
    );
  }

  /// One-point calibration: makes the measured spot (tap point, else the
  /// centre) read [knownCelsius].
  Future<void> calibrateTo(double knownCelsius) async {
    final T2sFrame? f = frame;
    final Uint16List? counts = processedCounts;
    if (f == null || counts == null) return;
    final (int, int) at = point ?? (f.width ~/ 2, f.height ~/ 2);
    final int count = _spotCount(counts, f.width, f.height, at);
    if (settings.revision == HardwareRevision.v2 && f.meta != null) {
      final double? solved = solveShutterOffset(
        meta: f.meta!,
        profile: f.profile!,
        settings: settings,
        count: count,
        targetCelsius: knownCelsius,
      );
      if (solved == null) {
        log('Calibration failed: model gives no value (NaN). '
            'Write default parameters first.');
        return;
      }
      settings = settings.copyWith(shutterOffset: solved, userOffset: 0);
      log('Calibrated: shutterOffset=${solved.toStringAsFixed(2)} '
          'for ${knownCelsius.toStringAsFixed(1)} °C at $at');
    } else {
      final TemperatureTable t = _tableFor(f, settings.copyWith(userOffset: 0));
      final double current = t.lookup(count);
      if (current.isNaN) {
        log('Calibration failed: model gives no value (NaN).');
        return;
      }
      settings = settings.copyWith(userOffset: knownCelsius - current);
      log('Calibrated: userOffset=${settings.userOffset.toStringAsFixed(2)}');
    }
    await _saveCalibration();
    notifyListeners();
  }

  Future<void> resetCalibration() async {
    settings = settings.copyWith(shutterOffset: 0, userOffset: 0);
    await _saveCalibration();
    log('Calibration reset');
  }

  // ---------------------------------------------------------------------
  // Frame loop
  // ---------------------------------------------------------------------

  void _startPolling() {
    _fpsWatch
      ..reset()
      ..start();
    _fpsFrames = 0;
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _poll(),
    );
  }

  void _poll() {
    final UvcRawFrame? raw = _camera.copyLatestRawFrame();
    if (raw == null || raw.sequence == _lastSequence) return;
    _lastSequence = raw.sequence;
    framesReceived++;
    _fpsFrames++;
    if (_fpsWatch.elapsedMilliseconds > 1000) {
      fps = _fpsFrames * 1000 / _fpsWatch.elapsedMilliseconds;
      _fpsFrames = 0;
      _fpsWatch
        ..reset()
        ..start();
    }
    lastFrameInfo =
        'format ${raw.frameFormat}, ${raw.width}x${raw.height}, '
        '${raw.bytes.length} bytes, seq ${raw.sequence}';
    final T2sFrame? decoded = family == CameraFamily.tiny1c
        ? T2sFrame.decodeTiny1c(raw.bytes, raw.width, raw.height)
        : T2sFrame.decode(raw.bytes, raw.width, raw.height);
    if (decoded == null) {
      undecodableFrames++;
      if (undecodableFrames == 1 || undecodableFrames % 100 == 0) {
        log('Cannot decode frame: $lastFrameInfo');
      }
      return;
    }
    frame = decoded;
    _process(decoded);
  }

  /// Count-to-°C table for a frame: the radiometric model for Xtherm
  /// cameras, a plain linear table for cameras that deliver temperatures.
  TemperatureTable _tableFor(T2sFrame f, ModelSettings s) => f.meta == null
      ? TemperatureTable.linear(s)
      : TemperatureTable.build(f.meta!, f.profile!, s);

  void _process(T2sFrame f) {
    // While the shutter is closed the picture shows only the shutter; keep
    // the last image on screen like commercial cameras do.
    if (_holdShutter || _shutterReleased.isRunning &&
        _shutterReleased.elapsed < const Duration(milliseconds: 800)) {
      return;
    }
    _shutterReleased.stop();
    _maybeReNuc(f);
    final TemperatureTable t = _tableFor(f, settings);
    table = t;
    final bool useCorrection =
        settings.revision == HardwareRevision.v2 && correction != null;
    // Anchor the closed-shutter level where the model expects the shutter
    // temperature, instead of at the drifting reference mean.
    Uint16List counts = useCorrection
        ? correction!.apply(
            f.counts,
            level: anchorToModel ? t.shutterLevel : null,
          )
        : f.counts;
    _preFlatCounts = counts;
    final FlatField? ff = flatField;
    if (flatFieldEnabled &&
        ff != null &&
        ff.width == f.width &&
        ff.height == f.height) {
      counts = ff.apply(counts);
    }
    processedCounts = counts;
    final TemperatureTable alt = f.meta == null
        ? t
        : TemperatureTable.build(
            f.meta!,
            f.profile!,
            settings.copyWith(
              shutterSource: settings.shutterSource == ShutterSource.register
                  ? ShutterSource.fpa
                  : ShutterSource.register,
            ),
          );

    final int n = f.width * f.height;
    int minC = 1 << 30;
    int maxC = -1;
    int minI = 0;
    int maxI = 0;
    double sum = 0;
    double sumSq = 0;
    final Uint32List histogram = Uint32List(kTableSize);
    for (int i = 0; i < n; i++) {
      final int v = counts[i].clamp(0, kTableSize - 1);
      histogram[v]++;
      sum += v;
      sumSq += v.toDouble() * v;
      if (v < minC) {
        minC = v;
        minI = i;
      }
      if (v > maxC) {
        maxC = v;
        maxI = i;
      }
    }
    final double mean = sum / n;
    final double std = math.sqrt(math.max(0, sumSq / n - mean * mean));

    // Robust display range: 0.5 % / 99.5 % percentiles of the counts.
    final int lowCount = _percentile(histogram, n, 0.005);
    final int highCount = _percentile(histogram, n, 0.995);

    final (int, int) center = (f.width ~/ 2, f.height ~/ 2);
    final int centerCount = _spotCount(counts, f.width, f.height, center);
    int? pointCount;
    if (point != null) {
      pointCount = _spotCount(counts, f.width, f.height, point!);
    }

    final bool showTemp =
        displaySource == DisplaySource.temperature &&
        !t.lookup(centerCount).isNaN;
    double low = t.lookup(lowCount);
    double high = t.lookup(highCount);
    if (low > high) (low, high) = (high, low);
    if (fixedScale && fixedMax > fixedMin) {
      low = fixedMin;
      high = fixedMax;
    } else if (high - low < minSpan) {
      final double mid = (high + low) / 2;
      low = mid - minSpan / 2;
      high = mid + minSpan / 2;
    }
    scaleLow = low;
    scaleHigh = high;
    _trackExtremes(counts, f.width, t, maxI, minI);

    stats = FrameStats(
      minCount: minC,
      maxCount: maxC,
      meanCount: mean,
      stdDev: std,
      centerCount: centerCount,
      minTemp: t.lookup(minC),
      maxTemp: t.lookup(maxC),
      centerTemp: t.lookup(centerCount),
      centerTempAlt: alt.lookup(centerCount),
      pointTempAlt: pointCount == null ? null : alt.lookup(pointCount),
      pointCount: pointCount,
      pointTemp: pointCount == null ? null : t.lookup(pointCount),
      hottest: (maxI % f.width, maxI ~/ f.width),
      coldest: (minI % f.width, minI ~/ f.width),
      nanCount: t.nanCount,
      scaleLow: showTemp ? low : lowCount.toDouble(),
      scaleHigh: showTemp ? high : highCount.toDouble(),
    );

    if (framesReceived % 75 == 0) {
      final int ticksNow = frameTick.value;
      final T2sMetadata? meta = f.meta;
      final String detail = meta == null
          ? 'family=${family.name} '
          : 'fpa=${meta.fpaTemp(f.profile!).toStringAsFixed(2)} '
                'shutterRaw=${meta.shutterRaw} '
                'shutterV2=${meta.shutterTempV2.toStringAsFixed(2)} '
                'cal00=${meta.cal00} '
                'level=${t.shutterLevel.toStringAsFixed(0)} '
                'refMean=${correction?.referenceMean.toStringAsFixed(0)} '
                'eps=${meta.emissivity.toStringAsFixed(3)} ';
      debugPrint('[probe] stats fps=${fps.toStringAsFixed(1)} '
          'rendered=${frameTick.value - _ticksAtLastStats} '
          'mean=${mean.toStringAsFixed(0)} std=${std.toStringAsFixed(1)} '
          'structure=${blockStdDev(counts, f.width, f.height).toStringAsFixed(1)} '
          'centre=${t.lookup(centerCount).toStringAsFixed(2)}C '
          'centreAlt=${alt.lookup(centerCount).toStringAsFixed(2)}C '
          'min=${t.lookup(minC).toStringAsFixed(1)} '
          'max=${t.lookup(maxC).toStringAsFixed(1)} '
          '$detail'
          'corr=${correction != null} rev=${settings.revision.name}');
      _ticksAtLastStats = ticksNow;
    }

    final Uint16List shown = displaySource == DisplaySource.rawCounts
        ? f.counts
        : counts;
    _render(shown, f.width, f.height, t, showTemp, low, high);
  }

  /// Moves the hottest/coldest markers: a new extreme only takes over when
  /// it beats the current spot by [markerHysteresis], and the drawn
  /// position glides towards its target.
  void _trackExtremes(
    Uint16List counts,
    int width,
    TemperatureTable t,
    int maxIndex,
    int minIndex,
  ) {
    double tempAt((int, int) p) => t.lookup(counts[p.$2 * width + p.$1]);
    final (int, int) newHot = (maxIndex % width, maxIndex ~/ width);
    final (int, int) newCold = (minIndex % width, minIndex ~/ width);
    final (int, int)? hot = _hotTarget;
    if (hot == null || tempAt(newHot) - tempAt(hot) > markerHysteresis) {
      _hotTarget = newHot;
    }
    final (int, int)? cold = _coldTarget;
    if (cold == null || tempAt(cold) - tempAt(newCold) > markerHysteresis) {
      _coldTarget = newCold;
    }
    hotMarker = _glide(hotMarker, _hotTarget!);
    coldMarker = _glide(coldMarker, _coldTarget!);
  }

  static (double, double) _glide((double, double)? from, (int, int) to) {
    if (from == null) return (to.$1.toDouble(), to.$2.toDouble());
    return (
      from.$1 + (to.$1 - from.$1) * markerSmoothing,
      from.$2 + (to.$2 - from.$2) * markerSmoothing,
    );
  }

  int _percentile(Uint32List histogram, int total, double q) {
    final int target = (total * q).round();
    int acc = 0;
    for (int i = 0; i < histogram.length; i++) {
      acc += histogram[i];
      if (acc > target) return i;
    }
    return histogram.length - 1;
  }

  /// Mean count of the 3x3 neighbourhood around [at].
  int _spotCount(Uint16List counts, int w, int h, (int, int) at) {
    int sum = 0;
    int k = 0;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        final int x = (at.$1 + dx).clamp(0, w - 1);
        final int y = (at.$2 + dy).clamp(0, h - 1);
        sum += counts[y * w + x];
        k++;
      }
    }
    return sum ~/ k;
  }

  void _render(
    Uint16List counts,
    int w,
    int h,
    TemperatureTable t,
    bool byTemperature,
    double lo,
    double hi,
  ) {
    if (_rendering) return;
    final Uint32List colors = palette.rgba;
    final Uint32List pixels = Uint32List(w * h);
    if (byTemperature) {
      final double span = math.max(hi - lo, 0.5);
      // Colour per count, then per pixel.
      final Uint32List lut = Uint32List(kTableSize);
      for (int c = 0; c < kTableSize; c++) {
        final double temp = t.values[c];
        lut[c] = temp.isNaN
            ? 0xFF000000
            : colors[(((temp - lo) / span) * 255).round().clamp(0, 255)];
      }
      for (int i = 0; i < w * h; i++) {
        pixels[i] = lut[counts[i].clamp(0, kTableSize - 1)];
      }
    } else {
      // Plain counts, auto-ranged over this frame.
      int lo = 1 << 30;
      int hi = -1;
      for (final int v in counts) {
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
      final double span = math.max(1, hi - lo).toDouble();
      for (int i = 0; i < w * h; i++) {
        pixels[i] = colors[(((counts[i] - lo) / span) * 255).round().clamp(
          0,
          255,
        )];
      }
    }
    _rendering = true;
    ui.decodeImageFromPixels(
      pixels.buffer.asUint8List(),
      w,
      h,
      ui.PixelFormat.rgba8888,
      (ui.Image img) {
        image?.dispose();
        image = img;
        _rendering = false;
        frameTick.value++;
        notifyListeners();
      },
    );
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  /// Writes the current raw frame plus a JSON report and opens the share
  /// sheet, so the data can be analysed elsewhere.
  Future<void> exportSnapshot() async {
    final T2sFrame? f = frame;
    if (f == null) {
      log('Nothing to export yet');
      return;
    }
    try {
      final Directory dir = await getTemporaryDirectory();
      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final File bin = File('${dir.path}/t2s_frame_$stamp.bin');
      await bin.writeAsBytes(f.rawBytes);
      final List<File> files = <File>[bin];
      if (correction != null) {
        final File ref = File('${dir.path}/t2s_shutter_reference_$stamp.f32');
        await ref.writeAsBytes(correction!.reference.buffer.asUint8List());
        files.add(ref);
      }

      final TemperatureTable? t = table;
      final FrameStats? s = stats;
      final Map<String, Object?> report = <String, Object?>{
        'app': 'thermaLab diagnostics',
        'timestamp': DateTime.now().toIso8601String(),
        'device': device == null
            ? null
            : <String, Object?>{
                'usbId': usbId(device!.vendorId, device!.productId),
                'manufacturer': device!.manufacturerName,
                'product': device!.productName,
                'serial': device!.serialNumber,
              },
        'modes': modes.map((UvcCameraMode m) => m.label).toList(),
        'mode': mode?.label,
        'frame': <String, Object?>{
          'width': f.width,
          'imageHeight': f.height,
          'bytes': f.rawBytes.length,
          'fps': fps,
          'framesReceived': framesReceived,
          'undecodableFrames': undecodableFrames,
        },
        'settings': <String, Object?>{
          'revision': settings.revision.name,
          'range': settings.range.name,
          'shutterOffset': settings.shutterOffset,
          'userOffset': settings.userOffset,
          'shutterCorrection': correction != null,
          'deadPixels': correction?.deadPixels.length,
        },
        'family': family.name,
        'camera': cameraName,
        'metadata': f.meta?.toJson(),
        'fpaTemp': f.meta?.fpaTemp(f.profile!),
        'model': t == null
            ? null
            : <String, Object?>{
                'shutterTempUsed': t.shutterTemp,
                'nanCount': t.nanCount,
                'samples': <String, double>{
                  for (int c = 0; c < kTableSize; c += 1024)
                    '$c': t.values[c],
                },
              },
        'stats': s == null
            ? null
            : <String, Object?>{
                'minCount': s.minCount,
                'maxCount': s.maxCount,
                'meanCount': s.meanCount,
                'stdDev': s.stdDev,
                'centerCount': s.centerCount,
                'centerTemp': s.centerTemp,
                'centerTempAlt': s.centerTempAlt,
                'minTemp': s.minTemp,
                'maxTemp': s.maxTemp,
                'point': point == null ? null : <int>[point!.$1, point!.$2],
                'pointTemp': s.pointTemp,
                'pointTempAlt': s.pointTempAlt,
              },
        'log': logLines,
      };
      final File json = File('${dir.path}/t2s_report_$stamp.json');
      await json.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      files.add(json);

      final ui.Image? img = image;
      if (img != null) {
        final ByteData? png = await img.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png != null) {
          final File pngFile = File('${dir.path}/t2s_image_$stamp.png');
          await pngFile.writeAsBytes(png.buffer.asUint8List());
          files.add(pngFile);
        }
      }

      await SharePlus.instance.share(
        ShareParams(
          files: files.map((File file) => XFile(file.path)).toList(),
          text: 'thermaLab diagnostics snapshot $stamp',
        ),
      );
      log('Exported ${files.length} files');
    } catch (e) {
      log('Export failed: $e');
    }
  }

  @override
  void dispose() {
    frameTick.dispose();
    _pollTimer?.cancel();
    _deviceEventsSub?.cancel();
    _streamErrorSub?.cancel();
    image?.dispose();
    unawaited(disconnect(keepLog: true));
    super.dispose();
  }
}

/// A user measurement point, in sensor coordinates.
class MeasurePoint {
  MeasurePoint(this.id, this.x, this.y);

  final int id;
  int x;
  int y;
}

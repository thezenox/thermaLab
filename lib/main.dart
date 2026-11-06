import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/viewer_page.dart';
import 'capture/capture_service.dart';
import 'capture/csv_logger.dart';
import 'overlay/overlay_engine.dart';
import 'overlay/visible_camera.dart';
import 'probe/probe_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The thermal view turns on its own (edit mode); the app frame stays put.
  SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const T2sThermalApp());
}

class T2sThermalApp extends StatefulWidget {
  const T2sThermalApp({super.key});

  @override
  State<T2sThermalApp> createState() => _T2sThermalAppState();
}

class _T2sThermalAppState extends State<T2sThermalApp> {
  final ProbeController controller = ProbeController();
  late final CsvLogger csv = CsvLogger(controller);
  final VisibleCamera camera = VisibleCamera();
  late final CaptureService capture = CaptureService(controller, csv, camera);
  late final OverlayEngine overlay = OverlayEngine(controller, camera);

  @override
  void initState() {
    super.initState();
    controller.loadPreferences().then((_) => controller.autoConnect());
  }

  @override
  void dispose() {
    overlay.dispose();
    camera.dispose();
    capture.dispose();
    csv.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'thermaLab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: ViewerPage(
        controller: controller,
        capture: capture,
        overlay: overlay,
      ),
    );
  }
}

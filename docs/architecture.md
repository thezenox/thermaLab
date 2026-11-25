# Architecture

Flutter app, Android only. Dart in `lib/`, a little Kotlin in `android/`,
USB through the vendored `packages/flutter_ffi_uvc` (libuvc, raw frames).

## Startup and data flow

`lib/main.dart` creates the long-lived objects and passes them down:

```
ProbeController ──frames──▶ buildScene() ──SceneData──▶ ScenePainter
 (USB, decoding,             lib/app/scene_builder.dart   screen, photo, video, stream
  markers, settings)
      │
      ├──▶ CsvLogger        temperature log
      └──▶ CaptureService   photo, video (Kotlin encoder), LiveServer (browser)
VisibleCamera + OverlayEngine   phone-camera overlay, switched off
```

Everything visible is drawn from one `SceneData`, so screen, photo, video and
stream always match. Settings persist through `shared_preferences`: display
and camera settings in `ProbeController`, capture, log
and stream settings in `CaptureService` and `CsvLogger`.

## Files

| Path | Contents |
|---|---|
| `lib/t2s/` | Pure Dart, unit tested, no Flutter UI. |
| `t2s_frame.dart` | Xtherm frame layout, metadata, `CameraFamily`, `SensorProfile` |
| `temperature_model.dart` | Radiometric model, counts → °C lookup table |
| `camera_catalog.dart` | Known USB IDs, choice of protocol and video mode |
| `t2s_commands.dart`, `tiny1c_commands.dart` | Command words of the two protocols |
| `shutter_correction.dart` | V2 software shutter (non-uniformity) correction |
| `flat_field.dart` | Lens shading correction |
| `lib/probe/` | |
| `probe_controller.dart` | **Central state**, the largest file: connection, frame loop, stats, measurement points, display settings, preferences |
| `probe_page.dart` | Diagnostics screen |
| `lib/render/` | |
| `scene_painter.dart` | `SceneData`, `SceneMarker`, `ScenePainter`: draws a frame with all overlays |
| `scene_layout.dart` | Which elements show and where the movable ones sit |
| `geometry.dart` | Rotation and mirroring of sensor coordinates |
| `palette.dart` | Colour maps |
| `lib/app/` | |
| `viewer_page.dart` | Main screen, gestures, release button |
| `edit_panel.dart` | Edit mode controls |
| `settings_page.dart` | Settings screen |
| `scene_builder.dart` | `buildScene()`: controller state → `SceneData` |
| `overlay_calibration_page.dart` | Overlay calibration (hidden feature) |
| `lib/capture/` | |
| `capture_service.dart` | Photo, video, stream, remote commands from the browser; method channel `t2s_thermal/video` |
| `csv_logger.dart` | CSV temperature log |
| `live_server.dart` | HTTP and WebSocket server, see [web-protocol.md](web-protocol.md) |
| `lib/overlay/` | Phone-camera overlay (edges or blend, automatic alignment), switched off in `overlay_feature.dart`: too slow, and with the cameras ~10 cm apart and no depth data one calibration fits one distance only. `visible_camera.dart` (phone camera), `alignment.dart` (image matching), `overlay_engine.dart` (calibration and tracking) |
| `assets/web/index.html` | Browser viewer, one file, no external resources |
| `android/app/src/main/kotlin/…/` | `MainActivity.kt` (channel), `VideoEncoder.kt` (H.264) |
| `packages/flutter_ffi_uvc/` | Vendored libuvc plugin; changes listed in its `FORK.md` |
| `test/` | Unit tests, mostly for `lib/t2s/` and `lib/render/`; `t2s_fixture.dart` builds fake frames |
| `tools/make_icon.py` | Generates the app icon |

## Where to change things

- New camera model: `camera_catalog.dart`, then [cameras.md](cameras.md).
- New display setting: state and preference in `probe_controller.dart`,
  drawing in `scene_painter.dart`, control in `edit_panel.dart`, remote
  `set` key in `capture_service.dart` and `assets/web/index.html`.
- New marker or overlay element: `SceneData` and `ScenePainter`, layout in
  `scene_layout.dart`.
- New remote command: `capture_service.dart` (handler) and
  `assets/web/index.html`; the wire format is in `live_server.dart`.

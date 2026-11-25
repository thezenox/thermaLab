# Agent notes

Flutter app (Android) for InfiRay USB thermal cameras. Read only the doc you need:

- `docs/architecture.md`: code map, data flow, where to change things. Start here.
- `docs/cameras.md`: camera protocols, frame formats, temperature model (`lib/t2s/`)
- `docs/web-protocol.md`: browser stream and remote control (`lib/capture/`, `assets/web/`)
- `docs/development.md`: build, signing, on-device debugging
- `README.md`: user-facing features and usage only

While working: `flutter analyze` and `flutter test` (fast). Analyze must add no new issues; the `package:flutter/material.dart` deprecation infos are known, leave them. Build the APK once at the end, it is slow: `flutter build apk --release --target-platform android-arm64`.

`packages/flutter_ffi_uvc/` is a vendored USB plugin, mostly third-party C, kept out of search by `.ignore`. The app only uses it through `uvc_camera_api.dart`; read `FORK.md` before changing it. Never read `flutter_ffi_uvc_bindings_generated.dart` (generated).

## Keep the docs current

After finishing a feature or change, update the docs in the same commit:

- Added, moved or renamed a file: update the table in `docs/architecture.md`.
- Changed data flow, a protocol, a command or a build step: update the matching doc.
- Changed what users see or do: update `README.md`.
- Level of detail: name folders, files and central classes; say what each is for and why it is built that way. Leave out methods, fields, setting keys, constants and line numbers: they change too often. Exception: exact values that are external contracts (camera commands, frame and wire formats) belong in `docs/cameras.md` and `docs/web-protocol.md`.
- Replace or delete outdated text instead of appending to it.
- Developer detail goes in `docs/`, never in `README.md`.
- `test/docs_test.dart` fails when a source file is missing from `docs/architecture.md` or a named path or class no longer exists. It can't check that descriptions are still true; that is on you.

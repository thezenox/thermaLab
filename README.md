# T2S+ Thermal

Android app for the InfiRay / Xinfrared / Xtherm **T2S+** USB-C thermal
camera, aiming at a real temperature scale without the vendor app.

Current state: **probe app.** It connects to the camera, shows what the
camera sends and lets every control command and calibration step be tried
by hand. The goal is to confirm the hardware revision and the temperature
model on real units before building the actual viewer.

## How the camera works

- It is a USB Video Class device streaming YUY2 frames of 256x196. After
  the raw-mode command, those bytes are little-endian 16-bit words: 192 rows
  of 14-bit sensor counts plus 4 rows of metadata (factory calibration
  constants, focal-plane and shutter temperatures, emissivity, distance, ...).
- Control commands go through the standard UVC "Zoom, Absolute" control:
  `0x8004` raw mode, `0x8000` shutter, `0x8020`/`0x8021` range,
  `0x80FF` save parameters, and parameter writes as `(offset+i) << 8 | byte`.
- Temperatures come from a radiometric model fed by the metadata, evaluated
  into a 16384-entry lookup table per frame.
- **V2 units** stream uncorrected counts: the app closes the shutter and
  subtracts a reference frame, and their shutter temperature register needs
  a one-point calibration against a known temperature.

## Using the probe

1. Plug in the camera, open the app, tap **Connect**. The app selects the
   256x196 mode and sends raw mode.
2. If the table shows NaN entries, tap **Write ε=0.95 params** once.
3. V2: tap **Shutter correction (V2)**; the image should turn from noisy to
   clean.
4. Compare the centre reading with the vendor app on the same object, or use
   **Calibrate centre…** with a surface of known temperature.
5. **Export** (share icon) writes the raw frame, a JSON report with all
   metadata and the log, and a PNG.

Developing needs wireless debugging (`adb pair` / `adb connect`), since the
phone's USB port is taken by the camera.

## Build

```bash
flutter build apk --release --target-platform android-arm64
```

## Credits and licence

- Frame layout, commands and temperature model are ported from
  [IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal) (GPL-3.0).
- V2 findings (parameter commit, shutter offset, shutter settling) from
  [t2s-thermal-macos](https://github.com/dzaczek/t2s-thermal-macos) and
  [Dmytro Engineering](https://dmytroengineering.com/content/projects/t2s-plus-thermal-camera-hacking).
- USB access via a vendored fork of
  [flutter_ffi_uvc](https://github.com/cornpip/flutter_ffi_uvc) (BSD-3-Clause),
  see `packages/flutter_ffi_uvc/FORK.md`.

This app is licensed under the GNU General Public License v3.0, see `LICENSE`.

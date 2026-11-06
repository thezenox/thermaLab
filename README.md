<p align="center">
  <img src="assets/icon/icon.png" width="128" alt="thermaLab icon">
</p>

# thermaLab

An Android app for the **InfiRay / Xinfrared T2S+** USB-C thermal camera
that works without the vendor app. It shows real temperatures, takes
photos, videos and temperature logs, and streams a live view with remote
control to any browser in your Wi-Fi.

<img width="300" alt="image" src="https://github.com/user-attachments/assets/04cb02fd-67e5-496b-9afa-c2e3e9b3a9ab" />


## Features

- **Live thermal view** with centre, hottest and coldest spot, a colour scale
  and a timestamp in the picture
- **Measurement points**: long-press to add, drag to move, drag onto the bin to
  delete (up to 8)
- **Real temperatures** from the camera's factory calibration; no manual
  calibration needed. Readings agree with the vendor app to within about 2 °C.
- **Automatic shutter correction**, repeated on its own while the camera
  warms up
- **Lens shading correction** against warmer edges and a cooler centre
- **Photo and video** (H.264) into the gallery album *thermaLab*, including all
  markers
- **CSV temperature log** of hottest, coldest, centre and every measurement
  point over time
- **Live stream in the browser**: a sharp view drawn in the browser itself,
  temperature under the mouse pointer, live table and line graph of the
  temperature log, photo and CSV download with your own file name patterns
- **Remote control** from the browser: set and move points, trigger the
  shutter, take photos, record video and CSV, change display settings.
  Files are always saved on the phone.
- Display options: palettes (Iron, White hot, Rainbow), rotation, mirroring,
  minimum or fixed colour scale span, timestamp corner, label outlines

## Supported hardware

| Camera | USB ID | Status |
|---|---|---|
| InfiRay / Xinfrared T2S+ V2 ("T2S+_A2") | `04b4:0100` | tested |
| T2S+ V2, other IDs seen in the wild | `1514:0001`, `3474:6002` | should work, untested |

Any Android phone with USB-C host support and Android 7.0 or newer should do.
Development and testing happened on a Xiaomi phone with Android 16.

## Installation

Download the APK from the
[releases page](https://github.com/thezenox/thermaLab/releases) and install
it. Android asks you to allow installing apps from this source.

Or build it yourself, see [Building](#building).

## Using the app

### First start

1. Plug in the camera. Android offers to open thermaLab; tick "always" if you
   like.
2. Allow **camera** access (Android only grants USB access to video devices to
   apps with this permission) and **USB** access to the T2S+.
3. The app connects on its own and runs a shutter correction. After a few
   seconds you see a clean image.

The camera needs one to two minutes to warm up. During that time it drifts
quickly; the app re-calibrates more often, so expect a few shutter clicks.

### Main screen

| Button | Action |
|---|---|
| **Shutter** | Closes the shutter and re-calibrates the image. Use it if the picture gets streaky or after big temperature changes. |
| **Photo** | Saves the current view with all markers to the gallery. |
| **Video** | Records the view, markers included, until you tap Stop. |
| **Settings** | All options, see below. |

In the picture:

- **+** centre temperature
- **▲** (red) hottest and **▽** (blue) coldest spot. They follow the scene
  smoothly and ignore changes below 0.2 °C, so they do not jump around on
  evenly warm surfaces.
- **Numbered yellow discs** are your measurement points.

### Measurement points

- **Long-press** anywhere in the image to add a point. Keep your finger down to
  place it precisely.
- **Drag** a point to move it.
- **Drag a point onto the bin** that appears at the bottom to delete it.

### Temperature log (CSV)

Enable it in *Settings → Temperature log* and choose the interval (0.5 to 10 s).
A second row of buttons appears:

- **CSV** starts, pauses and resumes the recording.
- **Save CSV** closes the file and opens the share sheet, so you can save it to
  your files, cloud storage or send it.

Each file starts with comment lines (`#`) describing the log. Whenever
measurement points are added or moved, a line lists their positions, followed
by a fresh column header:

```
# points: P1=(120,80) P2=(40,150)
time,elapsed_s,hottest_C,coldest_C,centre_C,P1_C,P2_C
2026-11-06 09:40:01,3.0,26.14,23.71,24.95,24.80,25.10
```

Point positions are sensor pixels (x 0–255, y 0–191) in the camera's own,
unrotated orientation.

### Live stream and remote control

*Settings → Live stream → Stream to browsers* starts a web server on the phone.
The address (for example `http://192.168.178.31:8080/`) is shown with copy and
share buttons. Open it in any browser in the same Wi-Fi.

The browser view offers:

- the live image, drawn sharply at any size, with **Fit / 75 % / 50 %** size and
  **Fullscreen**
- the **temperature under the mouse pointer**
- **Table**: the temperature log beside the image, newest row on top, with an
  optional **line graph** below
- **⤓ Download**: photo and CSV download with a file name pattern (see below)

With *Allow remote control* switched on, the browser can also trigger the
shutter, take photos, record video, start, pause and close CSV logs, change
display settings and work with measurement points (long-press or double-click
to add, drag to move, drag onto the bin to delete). Everything is saved on the
phone.

*Stream frame rate* (5 to 25 fps) limits the network load.

> **Privacy:** the stream has no password. Anyone in the same network who
> knows the address can watch, and with remote control enabled also control
> the camera. Switch the stream off on networks you do not trust.

#### File name patterns

In the browser's download panel you can enter a pattern such as
`Measurement_with_fan_`. With *Append date and time* on, the current date and
time are added, for example `Measurement_with_fan_2026-11-06_14-30-05.png`. A
preview line shows the resulting name. The **?** button lists all placeholders:

| Placeholder | Example |
|---|---|
| `{date}` `{time}` `{datetime}` | `2026-11-06`, `14-30-05`, `2026-11-06_14-30-05` |
| `{yyyy}` `{yy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}` | date and time parts |
| `{n}`, `{n:3}` | running number, optionally zero-padded (`007`) |
| `{max}` `{min}` `{centre}` | temperatures, e.g. `41.2C` |
| `{p1}` `{p2}` … | temperature of a measurement point |
| `{palette}` | colour palette name |

### Settings

- **Display**: palette, mirror, rotation, fixed temperature scale (min/max),
  minimum colour span (keeps evenly warm scenes calm instead of showing sensor
  noise), timestamp position, outline around marker labels
- **Shutter**: automatic shutter, lens shading correction, *Measure lens
  shading*
- **Temperature log**: CSV logging and interval
- **Live stream**: stream on/off, remote control, frame rate, address
- **Advanced → Diagnostics**: raw sensor data, model options, manual
  calibration against a known temperature, log and raw frame export

### Lens shading correction

The lens and its housing make the edges of the picture read warmer than the
centre (typically 2–3 °C). To correct this once per camera:

1. Point the camera at a surface that has the same temperature everywhere: a
   plain wall, a closed door, or a sheet of paper a few centimetres in front of
   the lens (blurry is fine).
2. *Settings → Measure lens shading*, hold still for about three seconds.

The centre readings stay as they are; the rest of the image is evened out to
match. The size of the effect depends a little on how warm the camera is
compared to the scene, so very hot or cold scenes are corrected approximately.

### Accuracy

- Temperatures assume an emissivity of 0.95, which suits most matte, painted
  or organic surfaces. Bare and polished metal reads far too cold.
- Readings matched the vendor app within about 2 °C on a mug of hot water and
  within about 1.5 °C on a room-temperature wall.
- Give the camera a few minutes after plugging in before taking measurements
  that matter.

### Troubleshooting

| Problem | Fix |
|---|---|
| "Plug in the T2S+ camera" although it is plugged in | Tap *Connect*; check that camera and USB access were allowed. Close the vendor app; only one app can use the camera. |
| Image striped or noisy | Tap **Shutter**. |
| Readings drift after plugging in | Normal during warm-up; the automatic shutter catches up. |
| Browser shows "Connection lost" | Phone and computer must be in the same Wi-Fi; keep the app in the foreground. |

## For developers

### How the camera works

The T2S+ is a USB Video Class device. The app talks to it with its own copy of
libuvc, not through Android's camera API.

- **Raw frames:** after the command `0x8004` the camera streams 256×196 YUY2
  frames whose bytes are really little-endian 16-bit words: 192 rows of 14-bit
  sensor counts plus 4 rows of metadata (factory calibration constants
  `cal00`…`cal05`, focal-plane and shutter temperature, emissivity, distance,
  humidity, …). Converting the stream to RGB, as every webcam viewer does,
  destroys this data.
- **Commands** go through the standard UVC "Zoom, Absolute" control (camera
  terminal selector `0x0B`), which the firmware uses as a register channel:

  | Value | Meaning |
  |---|---|
  | `0x8000` | close the shutter (sent repeatedly it stays closed) |
  | `0x8004` | raw 16-bit mode |
  | `0x8020` / `0x8021` | range −20…120 °C / 120…450 °C |
  | `0x80FF` | commit radiometric parameters |
  | `(offset + i) << 8 \| byte` | write parameter bytes (emissivity, distance, …) |

- **Temperatures** come from a radiometric model: the metadata feed a
  Planck-style inversion with atmospheric transmission, evaluated into a
  16384-entry table that maps every count to °C.
- **V2 units** stream uncorrected counts. The app closes the shutter, averages a
  reference frame and subtracts it. The closed-shutter level is anchored at the
  count where the model returns the shutter temperature, and that temperature
  is taken from the focal-plane sensor, because the V2 shutter register does
  not track the real shutter.
- **Lens shading** is a degree-4 polynomial surface fitted to a uniform scene
  and subtracted relative to the image centre.

### Project layout

```
lib/
  t2s/        frame decoding, commands, temperature model, shutter and
              lens shading correction (pure Dart, unit tested)
  probe/      camera controller (connection, frame loop, settings, markers)
              and the diagnostics screen
  render/     palettes, geometry (rotation, mirror) and the scene painter
              shared by screen, photo, video and stream
  app/        main viewer, settings and scene assembly
  capture/    photo, video, CSV logger, live stream server and remote control
  overlay/    phone camera overlay (hidden, see below)
assets/web/   the browser viewer (one HTML file, no external resources)
android/      app module, H.264 encoder (VideoEncoder.kt)
packages/flutter_ffi_uvc/  vendored libuvc plugin with raw frame access
test/         unit tests
```

### Building

Requirements: Flutter 3.35 or newer, Android SDK 36, NDK 27.0.12077973.

```bash
flutter pub get
flutter test
flutter build apk --release --target-platform android-arm64
```

The app icon is generated by `tools/make_icon.py` (Python with numpy and
Pillow) and turned into launcher icons with
`dart run flutter_launcher_icons`.

The APK is in `build/app/outputs/flutter-apk/app-release.apk`.

### Release signing

Without a keystore, release builds are signed with the debug key, which is
fine for testing. For releases, create a key once (`keytool` comes with
the JDK) and keep it, together with its passwords, safe and outside the
repository: Android only installs updates signed with the same key.

```bash
keytool -genkeypair -v -keystore ~/keys/thermalab-release.jks -alias thermalab -keyalg RSA -keysize 4096 -validity 10000
```

Then create `android/key.properties` (ignored by git):

```properties
storeFile=C:/Users/you/keys/thermalab-release.jks
storePassword=...
keyAlias=thermalab
keyPassword=...
```

`flutter build apk --release` picks it up automatically.

### Debugging on the phone

The phone's USB port is taken by the camera, so use wireless debugging
(Android 11+): enable *Developer options → Wireless debugging*, then

```bash
adb pair PHONE_IP:PAIRING_PORT
```

```bash
adb connect PHONE_IP:PORT
```

The app logs to logcat with the prefixes `[probe]`, `[capture]` and
`[overlay]`; every 75 frames it prints a line with frame rate, sensor and
shutter temperatures and the centre reading. *Diagnostics → Export* shares a
raw frame, the shutter reference and a JSON report with all metadata.

### Web viewer protocol

The phone serves `assets/web/index.html` and a WebSocket at `/ws`.

- **Phone → browser:** one binary message per frame:
  `[uint32 LE header length][header JSON][pad to even][int16 LE grid]`. The
  grid holds temperatures in 0.1 °C in sensor orientation, row-delta coded so
  that WebSocket compression shrinks it well. The header carries scale,
  markers, timestamp, settings, recording and CSV state, and the palette as a
  colour table whenever it changes.
- **Browser → phone:** JSON commands, `{"c": "ack"}` after each frame (flow
  control, at most two frames in flight) and remote-control commands such as
  `shutter`, `photo`, `record`, `csv`, `csvNew`, `add`, `move`, `remove` and
  `set` (key/value display settings).
- **HTTP:** `/csv` returns the current or last CSV log, `/csvdata?from=N` the
  log rows from index N as JSON for the live table.

### Camera overlay (hidden)

An overlay of the phone's own camera (edges or blend, with automatic
alignment) is implemented in `lib/overlay/` but switched off in
`lib/overlay/overlay_feature.dart`: it costs too much performance, and one
calibration only fits one distance, because the two cameras are about 10 cm
apart and there is no depth information.

## Credits

- Frame layout, commands and the radiometric model are ported from
  [IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal) (GPL-3.0).
- V2 findings from [t2s-thermal-macos](https://github.com/dzaczek/t2s-thermal-macos)
  and [Dmytro Engineering](https://dmytroengineering.com/content/projects/t2s-plus-thermal-camera-hacking).
- USB access through a modified copy of
  [flutter_ffi_uvc](https://github.com/cornpip/flutter_ffi_uvc) (BSD-3-Clause),
  see `packages/flutter_ffi_uvc/FORK.md`.

## Licence

GNU General Public License v3.0, see [LICENSE](LICENSE). The vendored
flutter_ffi_uvc plugin keeps its BSD-3-Clause licence.

InfiRay, Xinfrared and Xtherm are trademarks of their respective owners. This
project is not affiliated with them.

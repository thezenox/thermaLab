<p align="center">
  <img src="assets/icon/icon.png" width="128" alt="thermaLab icon">
</p>

# thermaLab

An Android app for USB-C thermal cameras of the **InfiRay** family, made for
the **T2S+** and also supporting the **P2 Pro**, **Topdon TC001** and related
models. It works without the vendor apps. It shows real temperatures, takes
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
- **Edit mode with live preview**: show or hide clock, colour bar and each
  marker, drag clock and colour bar where you want them, rotate and mirror the
  image, choose the palette, turn the whole display for landscape use, set the
  label outline
- Fixed or automatic colour scale with a minimum span

## Supported hardware

The app recognises the camera on its own: first by its USB ID, otherwise by
the shape of the video stream it offers.

| Camera | USB ID | Protocol | Status |
|---|---|---|---|
| InfiRay / Xinfrared T2S+ V2 ("T2S+_A2") | `04b4:0100` | Xtherm | tested |
| T2S+ V2, other IDs seen in the wild | `1514:0001`, `3474:6002` | Xtherm | should work, untested |
| InfiRay P2 Pro | `0bda:5830` | Tiny1-C | tested |
| Topdon TC001 (same module and USB ID as the P2 Pro) | `0bda:5830` | Tiny1-C | should work, untested |
| Other Xtherm cameras: T2S+ V1, T2L, T3S, T3Pro, HT-301 (256, 384 or 640 px wide) | various | Xtherm | detected by stream size, untested |
| Other Tiny1-C modules (picture and temperatures in one double-height stream) | various | Tiny1-C | detected by stream size, untested |

Reports from owners of the untested cameras are very welcome: *Settings →
Diagnostics → Export* produces a file with everything needed.

Any Android phone with USB-C host support and Android 7.0 or newer should do.
Development and testing happened on a Xiaomi phone with Android 16.

## Installation

Download the APK from the
[releases page](https://github.com/thezenox/thermaLab/releases) and install
it. Android asks you to allow installing apps from this source.

Or build it yourself, see [Development](docs/development.md#building).

## Using the app

### First start

1. Plug in the camera. Android offers to open thermaLab; tick "always" if you
   like.
2. Allow **camera** access (Android only grants USB access to video devices to
   apps with this permission) and **USB** access to the camera.
3. The app recognises the camera and connects on its own. A T2S+ first runs a
   shutter correction; a loading screen shows until the image is clean.
4. On the very first start the app offers to set up the lens shading
   correction (see below). You can also do it later.

The camera needs one to two minutes to warm up. During that time it drifts
quickly; the app re-calibrates more often, so expect a few shutter clicks.

### Main screen

| Control | Action |
|---|---|
| **PHOTO / VIDEO** | Chooses what the release button does. |
| **Release button** | White: takes a photo (a short flash confirms it). Red dot: starts a video; a red square stops it, the elapsed time shows above. Photos and videos include all markers and go to the gallery album *thermaLab*. |
| **Shutter** | Closes the shutter and re-calibrates the image. Use it if the picture gets streaky or after big temperature changes. Greyed out for cameras that calibrate on their own (P2 Pro). |
| **Settings** | Scale, shutter, temperature log, live stream and diagnostics. |
| **Gear with pencil** (top right) | Edit mode, see below. |

In the picture:

- **+** centre temperature
- **▲** (red) hottest and **▽** (blue) coldest spot. They follow the scene
  smoothly and ignore changes below 0.2 °C, so they do not jump around on
  evenly warm surfaces.
- **Numbered yellow discs** are your measurement points.

### Edit mode

The gear with the pencil at the top right opens a panel above the image. Every
change shows live:

- **Show**: clock, colour bar, centre, max and min marker on or off
- **Image**: rotate in 90° steps, mirror, colour palette
- **View**: turn the whole display (image, colour bar, clock and markers
  together) for holding the phone in landscape. Photos, videos and the browser
  get the picture in this reading direction.
- **Label outline**: shadow, normal or thick outline around marker labels

While the panel is open, drag the clock or the colour bar in the image to move
it; both snap to the edges and the centre. **Done** saves the layout,
**Reset layout** restores the default.

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

- **Display**: fixed temperature scale (min/max) and minimum colour span
  (keeps evenly warm scenes calm instead of showing sensor noise). Everything
  else about the look is in the edit mode.
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
| "Plug in the camera" although it is plugged in | Tap *Connect*; check that camera and USB access were allowed. Close the vendor app; only one app can use the camera. |
| Image striped or noisy | Tap **Shutter**. |
| Readings drift after plugging in | Normal during warm-up; the automatic shutter catches up. |
| Browser shows "Connection lost" | Phone and computer must be in the same Wi-Fi; keep the app in the foreground. |

## For developers

- [Architecture](docs/architecture.md): code layout, data flow, where to
  change things
- [Development](docs/development.md): building, release signing, debugging
  on the phone
- [How the cameras work](docs/cameras.md): frame formats, commands,
  temperature model
- [Web viewer protocol](docs/web-protocol.md)

## Credits

- Frame layout, commands and the radiometric model are ported from
  [IR-Py-Thermal](https://github.com/diminDDL/IR-Py-Thermal) (GPL-3.0).
- The Tiny1-C stream layout and vendor commands follow
  [P2Pro-Viewer](https://github.com/LeoDJ/P2Pro-Viewer) and
  [PyThermalCamera](https://github.com/leswright1977/PyThermalCamera).
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

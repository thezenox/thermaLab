# How the cameras work

All supported cameras are USB Video Class devices. The app talks to them with
its own copy of libuvc, not through Android's camera API. There are two
protocol families. Code: `lib/t2s/`.

## Xtherm (T2S+ and relatives)

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
- **V1 or V2:** known USB IDs decide; otherwise the app measures the
  pixel-to-pixel noise of the first frames. Uncorrected V2 frames show strong
  stripes, frames a V1 camera has corrected itself do not.

## Tiny1-C (P2 Pro, TC001)

- The camera offers a 256×384 YUY2 stream: the upper half is a ready-coloured
  picture, the lower half holds 16-bit temperatures, T(°C) = raw / 64 − 273.15.
- The module runs its own shutter calibration; the app has no command to
  trigger it, so the Shutter button is disabled.
- Commands are vendor control transfers (request `0x45` out, `0x44` in, value
  `0x78`, the command address in wIndex), followed by polling until the module
  reports ready. The app uses them to set emissivity and to switch the gain
  (high gain = normal range, low gain = high-temperature range).

## Both

- **Lens shading** is a degree-4 polynomial surface fitted to a uniform scene
  and subtracted relative to the image centre.
- Inside the app, temperatures from Tiny1-C cameras are stored as counts on a
  linear scale (0.05 °C steps) so the same pipeline serves both families.

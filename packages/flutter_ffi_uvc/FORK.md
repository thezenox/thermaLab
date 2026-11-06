# Vendored fork of flutter_ffi_uvc

Upstream: https://github.com/cornpip/flutter_ffi_uvc (BSD 3-Clause, see
`LICENSE`), commit `9c7440ea35ff14c596445dea4db1c3e6d3c6f35a` (version 1.1.2).

Trimmed to the plugin itself (no example app, tests or screenshots).

## Changes

- **Raw frame access.** The native frame callback keeps a verbatim copy of
  every uncompressed frame payload (`store_latest_raw_locked`) next to the
  RGBA conversion. New exports `uvc_latest_raw_frame_bytes` and
  `uvc_copy_latest_frame_raw`, hand-written Dart bindings, and
  `UvcCamera.copyLatestRawFrame()` returning a `UvcRawFrame`.
  Needed because thermal cameras such as the InfiRay T2S+ pack 16-bit sensor
  data into a YUYV stream, which the RGB conversion destroys.
- **Android build:** `compileSdk` 36 and NDK `27.0.12077973` to match the
  locally installed SDK.

The raw path is implemented in the libuvc backend only (Android, Linux and
Windows builds that use it).

# Web viewer protocol

The phone serves `assets/web/index.html` and a WebSocket at `/ws`.
Code: `lib/capture/live_server.dart`, `lib/capture/capture_service.dart`.

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

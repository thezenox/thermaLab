/// The phone-camera overlay is shelved for now (2026-11-06): it slowed the
/// app down noticeably, and a single calibration only fits one distance;
/// without depth information the parallax between the two cameras cannot be
/// corrected reliably. The code stays, the UI is hidden.
///
/// Notes for picking it up again: the thermal lens has a fairly wide field
/// of view, so the calibration search should not allow strong zoom (small
/// matches), otherwise it latches onto close-ups of things that are not
/// there; process camera frames off the UI isolate.
const bool kCameraOverlayEnabled = false;

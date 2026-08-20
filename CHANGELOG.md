# Changelog

All notable changes to KVCameraKit are documented in this file.

## Unreleased

Nothing yet.

## 1.1.0 - 2026-08-20

### Added

- **Scanner mode.** A third `CameraMode` beside photo and video, with a live outline that
  tracks the page and a shutter that captures, flattens and stores it. Artifacts come back
  as `.document` so the host can file a receipt somewhere other than the camera roll.

  Detection runs on the `FrameSource` added in 1.0.0 — its first real consumer, which is
  what that port existed for. `VNDetectDocumentSegmentationRequest` rather than
  `VNDetectRectanglesRequest`, because a table edge, a laptop and a window frame are all
  excellent rectangles. Not `VNDocumentCameraViewController` either: that is Apple's entire
  scanner in a modal view controller, which cannot be themed and cannot share this screen's
  zoom, torch and Camera Control.

  Two decisions worth knowing. **The capture re-detects on the full-resolution still**
  rather than reusing the quad from the live overlay — the preview stream and the photo
  output can differ in aspect ratio and field of view, so a normalised quad from one does
  not describe the same region of the other, and the result would be a scan cropped a few
  percent off every single time. And **the tone pass is deliberately mild**: thresholding
  hard to black-and-white looks superb on clean printed text and irreversibly destroys a
  pencil note or a receipt shot in warm light, which for a vault means destroying the only
  copy.

  A failed detection surfaces an alert instead of silently saving the uncorrected frame. A
  scanner that quietly hands back a skewed photo of a desk teaches the user the mode is
  unreliable without ever saying what went wrong.

### Fixed

- The mode switcher no longer runs off the edge of a small screen. The pill is
  `.fixedSize()`, and `DIGITALIZAR` and `SCANSIONE` are twice the width of `PHOTO`.

### Notes

`VNDetectDocumentSegmentationRequest` returns confident nonsense on synthetic images —
measured: a flat colour yields the whole frame at confidence 0.0, flat white or black
yields a meaningless band at 0.83–0.97, and a white rectangle drawn on a dark ground yields
that same band at 0.99, nowhere near the rectangle. It is trained on photographs. So the
geometry guards (`DocumentQuad.isUsable()`) are unit-tested and the detector itself is not:
verifying it needs a device pointed at real paper.

## 1.0.0 - 2026-08-20

First release. Extracted from an encrypted-vault app, where the camera had grown to
~2 500 lines inside the app target and kept reaching for things it had no business
knowing — a font, an import use case. A grep cannot see "the camera just used
`AppFont`", so the boundary became a package and the compiler became the enforcement.

### Added

- `CameraScreen` — a full-screen SwiftUI camera. Photo and video, multi-lens zoom with a
  pill that can be dragged, pinch zoom, tap-to-focus and long-press for AE/AF lock,
  exposure compensation, self-timer, grid, torch, front/back switching, and a capture
  animation that flies a sharp frame the moment the sensor answers rather than waiting for
  encryption to finish.

- `CameraArtifactHandler` — the whole boundary. The host says where bytes go and gets
  `CaptureArtifact` values back; the package knows nothing about storage, vaults, routing
  or the library. Dismissal is the host's too, because a package that owns a router cannot
  be dropped into a project that routes differently.

- `FrameSource` — frames off the sensor, separate from the viewfinder. An
  `AVCaptureVideoPreviewLayer` renders the session straight into a `CALayer`, so the app
  never sees a pixel; this is the port for the things that need pixels, such as a scanner,
  a Metal preview, an `AVAssetWriter` recorder or live filters. The
  `AVCaptureVideoDataOutput` attaches only when someone subscribes, so a screen that only
  takes photos pays nothing — adding that output is a session reconfiguration that on some
  devices lowers maximum photo dimensions or disables zero-shutter-lag.

  A delivered frame is valid **only inside its callback**. AVFoundation hands back buffers
  from a fixed pool; retain one and it leaves the pool, and when the pool empties delivery
  simply stops — no error, no log, the viewfinder freezes and the bug looks like it lives
  somewhere else.

- `FrameStatistics` — delivered, dropped, frames per second, pixel format and dimensions,
  measured from the buffers' own presentation timestamps. A tap that quietly runs at 22 fps
  or drops a third of its frames looks exactly like one that does not, until a number says
  otherwise.

- `CameraMode` — `photo` and `video` as an enum rather than an `isPhotoMode` flag, with the
  reasons attached to it (`needsAudio`, `isContinuousCapture`) instead of spread across
  negations at call sites. The mode switcher is built from `allCases`, so a third mode
  appears in the UI by existing.

- Camera Control support for iPhone 16 and later: a lens picker, an exposure slider and the
  self-timer. Each reports back rather than writing to the device behind the ViewModel's
  back, so the on-screen pill and the hardware button cannot disagree about zoom.

- Rotation driven by one `AVCaptureDevice.RotationCoordinator` for both the viewfinder and
  what is written to disk. Every connection used to be pinned to `.portrait`, which is why
  a landscape photo came out rotated.

- Session interruption handling — a phone call, another app taking the camera, Split View —
  surfaced as state so the screen can say what happened instead of showing a black
  rectangle. `mediaServicesWereReset` is recovered by restarting rather than treated as
  fatal.

- 19 languages, in the package's own `.strings` tables. A `LocalizedStringResource` literal
  resolves against `Bundle.main` — the *host app* — so a package whose text resolves from
  the host renders bare keys (`PHOTO`, `VIDEO`, `AE/AF LOCK`) in any other project. Nothing
  crashes and nothing logs, which is why `LocalizedStringResource.cameraKit(_:)` is a named
  bridge rather than a convention to remember.

- Simulator stand-ins (`SimulatedCapture`, `SimulatedFrameSource`). A simulator never
  starts a session, so without them the screen cannot be inspected and anything built on
  frames becomes device-only work. They say nothing about performance, which only a device
  can answer.

- 44 tests, none of which need a camera.

### Fixed

Carried over from the app this was extracted from, and all measured rather than reasoned
about:

- **The zoom ladder is derived from the hardware, not hard-coded.** `videoZoomFactor` is
  relative to the *widest* constituent of a virtual device, so on a triple camera `1.0` is
  the ultra wide and the wide sits at a switch-over factor. Three separate bugs lived here:
  `1×` mapped onto the telephoto on a wide+tele dual camera; the 15× ceiling was clamped in
  device space, which put `5×` near the top of the range on a phone whose wide lens sits at
  2.0; and `AVCaptureDevice.DiscoverySession` does not order its results by the device types
  requested, so an iPhone 16 handed back the plain wide angle — which has no constituent
  lenses — and `0,5×` vanished from the pill. An iPhone SE has one lens and now gets an
  empty list, rather than a `0,5` that clamped back to 1× and lied about it.

- **The capture preview is no longer resampled to nine times its size.** `uprightJPEG`
  rendered through a default `UIGraphicsImageRenderer`, which draws at the *screen* scale,
  so the ~1 MP preview frame was upsampled to ~9 MP and JPEG-encoded at that size — on the
  one path between the shutter closing and the first frame of feedback.

- **HEIC is no longer written to disk named `.jpg`.** Capturing HEVC yields an HEIC
  container; the extension is now sniffed from the bytes instead of assumed from the codec
  request.

- **The microphone is attached only in video mode.** Adding it at session setup put the
  orange in-use indicator on screen and switched the audio session to `.playAndRecord`,
  which stops whatever the user was listening to — on a screen that may only ever take one
  photo.

- **A tap no longer locks focus for the rest of the session.** Subject-area monitoring is
  what hands control back to continuous focus; without it, one tap held a one-shot result
  forever. Long-press keeps it, which is what AE/AF lock means.

- **A second shutter tap while a frame is in flight is dropped** rather than overwriting the
  pending continuation, which either crashed on a double resume or hung the dropped one
  forever.

- **Pinch cannot promise zoom the lens does not have.** The view used to clamp with its own
  `0.5...10` guess while the device clamped to something else.

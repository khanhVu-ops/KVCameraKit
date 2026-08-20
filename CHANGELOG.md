# Changelog

All notable changes to KVCameraKit are documented in this file.

## 1.5.0 - 2026-08-20

### Added

- **Filters — the tone stage & Photographic Styles UI.** A strip of looks (Original · Vivid ·
  Warm · Cool · Mono) applied live to the viewfinder via Metal shader and baked into captured photos.
  Redesigned as a modern Photographic Styles bottom carousel with Liquid Glass cards and active style badges.

  The design decision worth knowing: **the look is one 4×4 matrix, and both paths use it.**
  Exposure, white balance, saturation and contrast are each affine in RGB, so all four compose
  into a single matrix built in `CameraTone`. The shader multiplies by it; `CIColorMatrix`
  multiplies the still by it.

### Fixed

- **Zero-stall startup and atomic hardware controls.** `CameraHardwareControls` is now installed
  atomically inside `configureSessionLocked()` and `swapCameraLocked()` before `session.startRunning()`,
  completely eliminating the 3–5s capture pipeline stall caused by reconfiguring an active session.

- **Tone filter thumbnail orientation.** `ToneRenderer.downscale` now applies
  `CaptureRotation.imageTransform` and translation normalization, ensuring all filter preview
  thumbnails are rendered upright in portrait.

- **Video recording start latency.** `CapturePosterRenderer` now reuses a thread-safe `CIContext`
  and generates poster frames asynchronously off `writerQueue`, eliminating the 100–200ms freeze on the
  first video frame.

- **Front-to-back camera flip glitch.** `PendingFrame` in `CameraPreviewRenderer` preserves its own
  `isMirrored` state, preventing the last front-camera frame from visibly un-mirroring before the back-camera frame arrives.

- **Gesture conflict on viewfinder.** Scoped the root mode-switching drag gesture to the viewfinder area
  and guarded against mode switches while the filter shelf is open or video is recording.

- **The first capture or zoom on the camera screen took seconds.** The preview came up, and
  then nothing responded for about five.

  `CameraFrameTap` attaches its `AVCaptureVideoDataOutput` on first subscription, which is the
  right default — a screen that only takes photos should not pay for an output it never reads.
  But with the Metal preview the *preview itself* is that first subscriber, and it subscribes a
  moment after the session is already running. Adding an output to a running session is not a
  cheap edit: AVFoundation rebuilds the capture pipeline, and with a 48 MP sensor,
  zero-shutter-lag and responsive capture that rebuild takes seconds — during which every
  shutter tap and every zoom sits behind it on the session queue.

  Anything certain to want frames now gets its output during the session's *first*
  configuration, before it starts running, where the same output costs nothing measurable.
  `CameraFrameTap.pin(to:)`, driven by `CameraPreviewEngine.needsFrames` and
  `CameraRecordingEngine.usesSampleBuffers`, and a pinned output is not torn down when its last
  consumer leaves.

- **`AVCaptureDevice` is no longer read from the main actor.** `availableZoomLevels()`,
  `zoomRange()` and the HUD's zoom reading each took a device property lock that the session
  queue also holds while reconfiguring — from the thread that draws, at exactly the moment the
  session is being built. The ladder is read once on the session queue where the device changes
  hands and cached; a diagnostic that measures stalls must not cause them.

- **`maxPhotoQualityPrioritization` no longer asks for more than any shot uses.** It was
  `.quality` while every capture requests `.balanced`. The ceiling is not free — the output
  allocates for the level it is told it may be asked for — so that bought a deeper pipeline and
  a slower first capture in exchange for a quality level nothing here requests.

- **A slow capture no longer shows a black screen.** The shutter curtain was
  `captureStage == .exposing ? 1 : 0`, tying an opaque black overlay to however long the sensor
  took: correct for the tens of milliseconds it exists to cover, and a black screen for
  anything longer. It is a blink now — closes, holds, opens, on its own clock — and the card
  still flies whenever the frame actually lands. A failed capture no longer leaves it up either.

- **Zoom did nothing for the first second on the camera screen.** Bringing a session up on a
  phone takes the better part of a second and the screen is interactive throughout, so every
  zoom in that window hit `guard let device = activeDevice else { return }` and vanished —
  while the pill moved, because the screen's own state had already changed. The request is now
  remembered and applied when the lens arrives. And when the capabilities land, the factor the
  user chose is *clamped* into the new range instead of being reset to 1×, which is what
  visibly snapped the pill back.

  A range of exactly `1…1` is also no longer treated as a clamp: that is what the ladder
  reports when it could not make sense of the hardware, and clamping every request to 1× on
  the strength of a failed read is the same bug as dropping it.

- **Rotating the device spun the preview inside the frame.** The Metal viewfinder was fed
  `videoRotationAngleForHorizonLevelCapture` — the angle that keeps a *recording* level with
  gravity, so it tracks the device as it turns. Applied to a preview inside a view UIKit has
  already rotated, it turns the picture a second time. A preview needs the compensation for
  where the *interface* is, which is what the system camera does and what
  `CaptureRotation.previewAngle(for:)` now computes; the view reads its own window's
  orientation, being the thing that got rotated.

- **The video thumbnail faced 180° away from its video.** Core Image's y runs up and a video
  track's transform is in the image's y-down space, so handing `CapturePosterRenderer` the
  recorder's matrix turned the poster the opposite way. It takes the angle now.

- **A photo capture turned the Metal preview black until the shutter finished.** The renderer
  cleared its frame as soon as it had been drawn, so a redraw was impossible without a new
  frame from the camera — and a `CAMetalLayer` hands back an empty drawable pool whenever its
  size changes, which the capture-flight overlay triggers. A still capture is exactly when
  AVFoundation stops sending frames, so the cleared layer stayed black for as long as the
  photo took, and only for photos. The last frame is now held until the next one replaces it,
  which is what this file always claimed it did.

### Added

- `CaptureRotation` — the y-down and y-up conventions in one place, named after the spaces
  they belong to rather than after whichever caller needed one first. Three bugs came out of
  mixing them: an upside-down viewfinder, a preview that spun with the device, and a thumbnail
  facing away from its own video. Using the wrong one is never subtly wrong; it is exactly
  180° wrong, which fills the frame correctly and looks like a rotation that was applied.

### Changed

- **`SimulatedFrameSource` now delivers landscape buffers with an orientation marker.** It
  produced upright portrait frames needing no rotation, which is why an upside-down viewfinder
  could only be seen on a phone — the simulator was exercising a path no device takes. A
  device hands back the sensor's own landscape buffer and leaves the turn to whoever draws it,
  so the stand-in does too, and a yellow square marks the buffer's top-left corner: in a
  correctly turned portrait preview it belongs at the top-right of the screen.

### Fixed (previously)

- **The Metal viewfinder was upside down on a device.** Both cameras, 180° out, with a
  perfectly smooth stream — which is what made it look like anything but a rotation that had
  been applied, and had.

  AVFoundation's rotation angle describes a turn in the *image's* coordinate space, where y
  runs down — the same convention `CGAffineTransform(rotationAngle:)` uses, which is why the
  recorder takes the same angle unchanged and tags its files upright. Metal's clip space has
  y **up**, so the identical angle turned the quad the other way, and a quarter turn the
  wrong way is 180° from a quarter turn the right way.

  What let it ship is worth more than the fix: every rotation test compared `hypot` or `abs`,
  so all of them pinned how far the quad was scaled and none of them pinned which way it
  turned. There are now three that assert direction, plus one that ties the preview's matrix
  to the recorder's transform — if someone "corrects" one convention without the other, the
  preview and the file it records disagree about which way is up.

### Added

- **The debug HUD now reports zoom: asked → measured · raw.** Three numbers, because each
  pair rules out a different story when zoom appears not to respond — the request never
  reached the lens, the lens moved but the frames are not being cropped, or the ladder's base
  factor is wrong for this hardware and both UI numbers agree while the lens sits somewhere
  else. It turns amber when the first two disagree.

  Same reasoning as the frame counter beside it: zoom that silently fails to apply looks
  exactly like zoom that applied, and only a device can tell you which you have.

  The HUD is two rows now. The readings are monospaced and unbounded, and it spans the top of
  the narrowest phone the app supports — the mode switcher already ran off the edge of a small
  screen once for that reason.

## 1.4.0 - 2026-08-20

### Added

- **A recording can now be written without ever existing as a file.**
  `CameraRecordingEngine.streamingAssetWriter` runs `AVAssetWriter` in fragmented mode and
  hands each segment to the host through a new optional boundary, `CaptureVideoSink`:

  ```swift
  func makeVideoSink() async throws -> (any CaptureVideoSink)?   // nil = give me a file
  ```

  This is what 1.3.0 existed to make possible. With `AVCaptureMovieFileOutput` the app never
  sees a byte, so the only way to encrypt a recording was to let AVFoundation finish a
  plaintext file and read it back: for a five-minute 4K clip, a gigabyte of plaintext on disk
  plus two more copies of it in memory, inside an app whose entire promise is that there are
  none. Peak memory is now one segment, and nothing unencrypted is written at all.

  `makeVideoSink` is defaulted to `nil`, so every existing host compiles unchanged and keeps
  receiving finished `CaptureArtifact` values.

- `CaptureVideoSummary` — the facts about a recording that only exist once it has stopped:
  duration, byte count, oriented dimensions, and a poster frame. It arrives at `finish`,
  which is the whole difference from `CaptureArtifact`: a streaming host has to be able to
  open a destination *before* any of them are known.

- `CapturePosterRenderer`. The poster used to come from `AVAssetImageGenerator` decoding the
  finished file; a streamed recording is encrypted by the time it lands, so there is nothing
  to decode. It is now taken from the first frame that goes *into* the file — which is also
  the better frame, being the moment the user pressed record.

### Changed

- **`CameraCapturing.startRecording`/`stopRecording` take and return a destination rather
  than a URL.** `RecordingDestination` is `.file` or `.stream`; `RecordingOutput` is
  `.file(URL)` or `.stream(CaptureVideoSummary)`. Two cases rather than an optional URL so
  the compiler makes every caller say what it does with a streamed recording — there is no
  file to fall back on.

- **Leaving the camera or backgrounding the app while recording now finishes the recording
  instead of dropping it.** It used to flip `isRecording` to `false` and stop the session,
  which silently lost the clip — and with a streaming destination would also leave the host
  holding an item nobody ever completes. All three ways of ending a recording go through one
  function now.

- A destination that **fails to open** refuses the recording, with an alert. Only `nil` —
  "this host does not do streaming" — falls back to a file. The distinction matters more than
  it looks: the fallback for a host that *meant* to stream and could not would be writing the
  user's video to disk in the clear, which is exactly the case a locked vault produces.

### Notes

Measured rather than assumed, because both would have failed quietly:

`AVAssetWriter`'s HLS profile does accept audio and video in one fragmented file. The CMAF
profile's one-track-per-file rule would have split a recording in two and left the audio to
be re-muxed later, and the failure mode of picking wrong is a recording with no sound. There
is a test that concatenates the segments and asserts two tracks.

Segments are two seconds. That interval is the unit of everything about streaming — how much
plaintext is in memory at once, how much is lost if the app dies mid-recording, and how often
the encoder is forced to emit a keyframe. What a simulator cannot answer is what the extra
per-segment keyframes cost in bitrate on real hardware, or how a host's disk writes behave
while a 4K encode is running: the segment pump is unbounded precisely because sealing a
segment is memory-speed work, and that assumption wants measuring on a device.

A sink that fails mid-recording is reported at `stop`, not at the moment it happens — so a
disk that fills at second three of a five-minute recording is discovered at the end. Stopping
a recording early on the host's behalf needs a way to tell the user *why* the camera stopped,
and that is a screen change rather than a writer change.

## 1.3.0 - 2026-08-20

### Added

- **An `AVAssetWriter` recorder, behind a flag.** `CameraRecordingEngine` selects between
  `AVCaptureMovieFileOutput` (`.movieFile`, the default) and appending samples ourselves
  (`.assetWriter`). Pass it to `CameraScreen(recordingEngine:)`.

  Same reasoning as the preview engine, with more at stake. With `AVCaptureMovieFileOutput`
  the app never sees the bytes, so it can neither record filtered frames nor encrypt as it
  writes — only wait for a finished plaintext file and re-read it. Both of those are
  upcoming, and both are impossible on the old path. But a viewfinder that regresses is
  obvious immediately, while a recorder that regresses is discovered *after* the moment is
  gone, so the working path stays the default.

- `CameraAudioTap`, an `AVCaptureAudioDataOutput`. The movie-file output took audio straight
  off the session input; a writer has to be handed the samples.

### Changed

- **The two recording engines are now mutually exclusive on the session.**
  `AVCaptureMovieFileOutput` and `AVCaptureVideoDataOutput` coexisting is a constraint that
  varies by device and configuration, and the failure is silent: `canAddOutput` returns
  `false` and the frame tap never attaches, so a Metal preview shows black and a scanner
  never finds a page with nothing logged. Only the outputs the chosen engine needs go on the
  session, which removes the question rather than hoping about it. This closes a latent risk
  introduced in 1.0.0, when the frame tap could attach alongside the movie output.

- **Video recording now works on a simulator.** The asset-writer path takes its frames from
  `FrameSource`, which is simulated where there is no camera — so unlike every previous
  recorder it produces a real, playable file on a machine with no hardware. Audio is the only
  part that cannot be faked, and the writer is told so rather than left to create a track
  nothing fills: an `AVAssetWriterInput` cannot be added after `startWriting`, so an audio
  track has to be committed to before any audio arrives, and one that receives nothing is a
  file some players open and others refuse.

### Notes

Three guards worth knowing about, each against a way a real-time writer produces something
that looks like success:

`stop()` returns `nil` when no sample was ever appended. `AVAssetWriter` will happily finish
a *valid* file with no tracks, and storing that gives the user an unplayable item
indistinguishable from a real recording until they tap it.

The session starts on the first **video** sample, never on audio. A microphone warms up
faster than a camera, so the first buffers are reliably audio, and starting on them opens the
file with sound over no picture — which every player shows as black.

Rotation is a track transform, not rotated pixels: one matrix in the container header rather
than a full-frame copy thirty times a second.

Bitrate scales with pixel count from a 6 Mbps reference at 1080p, clamped at both ends. What
this cannot answer without a device is thermal behaviour and sustained write throughput at
4K, which is what the flag exists to let you measure.

## 1.2.0 - 2026-08-20

### Added

- **A Metal viewfinder, behind a flag.** `CameraPreviewEngine` selects between
  `AVCaptureVideoPreviewLayer` (`.system`, the default) and an `MTKView` fed from
  `FrameSource` (`.metal`). Pass it to `CameraScreen(previewEngine:)`.

  The reason is not speed. `AVCaptureVideoPreviewLayer` renders the session straight into a
  `CALayer` and nothing can be placed in front of it — no LUT, no tone curve, no beauty
  pass. Live filtering is impossible until the app draws its own frames, so owning the
  preview is the precondition for that work rather than an optimisation of this screen.

  It ships **off**, and that is the point of the flag. A viewfinder is the one part of a
  camera a user cannot work around when it is wrong: dropped frames, shifted colour, changed
  framing or a laggy shutter are not things you route around, and reverting has to be one
  line rather than a hotfix. It also costs a real `AVCaptureVideoDataOutput` on the session,
  which on some devices lowers maximum photo dimensions or disables zero-shutter-lag — a
  trade worth measuring against the other engine on the same device, minutes apart.

  Both pixel formats are handled rather than one being forced. `CameraFrameTap` deliberately
  sets no `videoSettings`, so a device delivers bi-planar YCbCr — the sensor's own format at
  1.5 bytes per pixel — while the simulated source produces BGRA. Requesting BGRA from
  AVFoundation would be a conversion of every frame bought before knowing anything needs it,
  and would leave the simulator exercising a path no device takes. The YCbCr shader carries
  both the full-range and video-range matrices, because using the wrong one looks *almost*
  right — slightly washed out or slightly crushed — which is how it ships.

  Rotation, aspect fill and front-camera mirroring compose into one transform, so there is a
  single place they can disagree instead of three. Aspect **fill**, matching what the system
  layer was doing: switching engines must not change how much of the scene is visible, or
  the framing someone composed a shot with moves under them.

- `CameraCapturing.isUsingFrontCamera`, and `CameraState.isUsingFrontCamera` beside it.
  Needed only by the Metal path: `AVCaptureVideoPreviewLayer` mirrors the front camera
  itself, so nothing above this ever had to know. An unmirrored selfie preview is reported by
  users as "the camera is backwards".

### Notes

Two things this release cannot verify on a simulator, both of which want a device:

The preview currently rotates by the horizon-level **capture** angle, which is what the
frame tap is told. On a portrait-locked screen that is the same as the preview angle; if they
diverge under device rotation, the tap should report the preview angle as well.

And the cost. 30 fps with zero drops and working capture is what a simulator can show; what
a video data output does to thermals, battery, photo dimensions and zero-shutter-lag on real
hardware is exactly the measurement the flag exists to make possible.

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

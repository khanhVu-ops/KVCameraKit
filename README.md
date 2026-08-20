# KVCameraKit

A camera that knows how to capture and nothing about where the bytes go.

iOS 18+ · Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`) · no dependencies

```swift
.package(url: "https://github.com/khanhVu-ops/KVCameraKit.git", from: "1.0.0")
```

## What it is

A full-screen SwiftUI camera — photo and video, multi-lens zoom, tap and long-press
focus with AE/AF lock, exposure compensation, a self-timer, grid, torch, Camera Control
support on iPhone 16 and later, and a capture animation that starts the moment there is a
sharp frame to fly rather than after encryption finishes.

The Metal viewfinder also carries a complete look pipeline: photographic styles, `.cube`
and Hald CLUT 3D LUTs, five film simulations with grain/light leaks, and skin-aware beauty
controls for smoothing, brightening, rosy tone and definition. Tone, LUT and beauty are
composed in one fragment pass; captured stills use the same matrix and LUT recipe through the
GPU-backed Core Image path.

What it deliberately does **not** know is storage. The host passes in a
`CameraArtifactHandler` and gets `CaptureArtifact` values back:

```swift
CameraScreen(
    handler: myHandler,          // where the bytes go — a vault, a folder, a server
    controlTitles: titles,       // Camera Control HUD labels, already localized
    onDismiss: { ... },          // closing is the host's business, not the package's
    onOpenLibrary: { ... }       // optional
)
```

For video there is a second, optional shape of that boundary. A host that encrypts what it
stores can implement `makeVideoSink()` and receive the recording **as it is made** —
fragmented-MP4 segments, one at a time — instead of a finished file:

```swift
func makeVideoSink() async throws -> (any CaptureVideoSink)? {
    MySink()                      // write(_:) per segment, then finish(summary)
}                                 // nil — the default — means "hand me a file instead"
```

The difference is not an optimisation. `AVCaptureMovieFileOutput` never lets the app see a
byte, so the only way to encrypt a recording was to let AVFoundation finish a plaintext file
and read it back — which for a five-minute 4K clip means a gigabyte of plaintext on disk plus
two more copies of it in memory. With a sink, peak memory is one segment and nothing
unencrypted is ever written. It needs `CameraRecordingEngine.streamingAssetWriter`.

That boundary is the reason the package exists. It was extracted from an encrypted-vault
app once it became clear the camera would keep growing — modes, live filters, a scanner,
editing — and that in a single module nothing stops a camera reaching for the app's fonts
or its import use case. A grep cannot see "the camera just used `AppFont`"; a package
makes the compiler the enforcement.

## Design notes

Most of what is interesting here is written next to the code it explains, because most of
it is a bug that was paid for once. A few of the load-bearing ones:

**The zoom ladder is derived, not hard-coded.** `videoZoomFactor` is relative to the
*widest* constituent of a virtual device, so on a triple camera `1.0` is the ultra wide
and the wide sits at a switch-over factor — the number the user sees and the number the
device wants are different, and the mapping differs per device. An iPhone SE has one lens
and gets an empty list, because offering `0,5×` there meant a chip that clamped back to
1× and lied about it. `CameraZoomLadder` is pure arithmetic so all of this is testable
without three different phones on a desk.

**Frames are separate from the viewfinder.** `AVCaptureVideoPreviewLayer` renders the
session straight into a `CALayer`, so the app never sees a pixel. `FrameSource` is the
port for the things that need pixels — a scanner, a Metal preview, an `AVAssetWriter`
recorder, live filters — and it attaches an `AVCaptureVideoDataOutput` only when someone
actually subscribes. A screen that only takes photos pays nothing.

**A recording can be written without ever existing as a file.** `.streamingAssetWriter`
runs `AVAssetWriter` in fragmented mode: an initialization segment and then self-contained
media segments, handed to the host's `CaptureVideoSink` as the encoder produces them, so
concatenating what arrives *is* the file. A `.mov` cannot do this — it is finalised by
rewriting its header at the end — which is why the streamed container is an fMP4. The
`.mpeg4AppleHLS` profile is the one that permits audio and video in the same segment;
that is asserted in the tests rather than trusted, because the alternative profile would
silently produce a recording with no sound.

**There are three recording engines, and the default is the oldest one.** A viewfinder that
regresses is obvious immediately; a recorder that regresses is discovered after the moment is
gone. `.movieFile` (AVFoundation owns everything) ships as the default, `.assetWriter` writes
the file itself, `.streamingAssetWriter` streams it — and moving between them is one line, in
either direction.

**A delivered frame is valid only inside its callback.** `AVCaptureVideoDataOutput` hands
back buffers from a fixed pool; retain one and it leaves the pool, and when the pool
empties AVFoundation simply stops delivering. No error, no log — the viewfinder freezes
and the bug looks like it lives somewhere else.

**The package carries its own string tables.** A `LocalizedStringResource` literal
resolves against `Bundle.main`, which is the *host app* — so a package whose text
resolves from the host renders bare keys (`PHOTO`, `VIDEO`, `AE/AF LOCK`) in any other
project. Nothing crashes and nothing logs, which is exactly why it needs a named bridge
rather than a convention to remember. 19 languages ship with the package.

**The microphone is attached only in video mode.** Adding it at session setup put the
orange in-use indicator on screen and switched the audio session to `.playAndRecord`,
which stops whatever the user was listening to — on a screen that may only ever take one
photo.

## Layout

```
Capture/
  CameraService            the CameraCapturing façade: session, device, queue
  Device/                  zoom ladder · device discovery · focus/exposure/torch
  Output/                  photo capture · look/LUT render · movie recording · segment pump
  Session/                 audio · rotation · interruptions · Camera Control
  Frames/                  FrameSource · frame tap · statistics
Core/                      artifacts · modes · tone · LUT · beauty · film · theme · haptics
UI/                        CameraScreen · CameraViewModel · components
Resources/                 19 × Localizable.strings
```

`CameraCapturing` is a protocol for one reason: the ViewModel owns a capture *pipeline* —
a stage machine, off-main sealing, an error surface — and none of that is assertable if
the only implementation needs a device. On a simulator the session never starts, so
`SimulatedCapture` and `SimulatedFrameSource` stand in; they prove nothing about
performance, which only a device can answer, but they keep the screen inspectable.

## Tests

181 tests, none of which need a camera — including a recording written, streamed, and read
back as a playable asset entirely from synthesised sample buffers.

```bash
xcodebuild -scheme KVCameraKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Licence

MIT

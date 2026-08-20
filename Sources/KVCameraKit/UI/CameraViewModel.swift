import Foundation
import CoreGraphics

/// Whether the viewfinder may run.
///
/// A `Bool` could not tell "not asked yet" from "refused", so the screen flashed
/// the permission prompt for one frame on every appearance before the answer came
/// back. `.checking` is a state, not the absence of one.
enum CameraAuthorization: Equatable, Sendable {
    case checking
    case authorized
    case denied
}

/// The frame the capture animation flies.
///
/// `id` comes first so `Equatable` short-circuits on it instead of memcmp-ing the
/// image on every unrelated state change.
struct CaptureFlight: Equatable, Sendable, Identifiable {
    let id: UUID
    let imageData: Data
}

/// Where a capture is between the shutter and the vault.
///
/// The animation used to start *after* encryption finished, which is why it felt
/// late: a 12 MP frame is a few hundred milliseconds of AES-GCM, and the flight was
/// queued behind it. Splitting them lets each cover what it is good at — the
/// curtain hides sensor latency, the flight starts the instant there is a sharp
/// frame to fly, and the vault write reports itself separately through `isSealing`.
enum CaptureStage: Equatable, Sendable {
    /// Viewfinder live, nothing in the pipeline.
    case idle
    /// Shutter closed, waiting for the sensor. The curtain is down.
    case exposing
    /// A frame is on its way to the thumbnail.
    case flying(CaptureFlight)
}

struct CameraState: Equatable, Sendable {
    var authorization: CameraAuthorization = .checking
    var mode: CameraMode = .photo
    var isRecording: Bool = false
    var recordingDurationSeconds: Int = 0
    var flashMode: CameraFlashMode = .auto
    var isTorchOn: Bool = false
    var currentZoom: CGFloat = 1.0
    /// Read from the hardware once the session is up, not hard-coded. An iPhone SE has
    /// one lens and gets an empty list, which hides the pill instead of offering a `0,5`
    /// that clamps straight back to 1x.
    var zoomLevels: [CGFloat] = []
    /// `nil` until the session answers. A permissive default would be a guess and a
    /// narrow one silently kills pinch, so "not known yet" is spelled out and simply
    /// does not clamp.
    var zoomRange: ClosedRange<CGFloat>?
    var isGridEnabled: Bool = false
    /// The look being applied. Photo mode only — see `CameraMode.supportsFilters`.
    var filter: CameraFilter = .original
    /// The filter strip is open. State rather than a `@State` flag in the view, for the same
    /// reason the timer menu is: picking a filter closes it in the same update.
    var isFilterPickerOpen: Bool = false
    /// Privacy face censoring mode (Off / Mosaic / Blur / Censor Bar).
    var censorMode: CameraCensorMode = .off
    /// Whether the censor mode picker shelf is open.
    var isCensorPickerOpen: Bool = false
    /// Whether this build can censor at all — a fact about the preview and recording engines,
    /// read once on appear. See `CameraService.isCensorSupported`.
    ///
    /// No `detectedFaces` beside it, deliberately. The geometry used to live here, pushed in
    /// from a Vision callback so a SwiftUI overlay could draw it, and that was the wrong shape
    /// twice over: it put a 30 Hz stream of `[CGRect]` through a main-actor state update, and
    /// the overlay it fed could not touch the camera's pixels, so the preview and the recorded
    /// file disagreed. The censor is now a stage in the pixel pipeline and the geometry never
    /// enters `CameraState`.
    var isCensorSupported: Bool = false
    /// Whether the horizon level indicator is active.
    var isHorizonLevelEnabled: Bool = true
    /// Current tilt angle of the device relative to horizon (in degrees).
    var horizonAngle: Double = 0.0
    /// Whether the device is currently level (within ±0.75°).
    var isHorizonLevel: Bool = false
    var timerDelaySeconds: Int = 0
    /// The delay menu is open. State, not a `@State` flag in the view: closing it happens
    /// in the same update as choosing a delay, and a local flag written next to a
    /// state mutation in one button action did not survive the re-render.
    var isTimerMenuOpen: Bool = false
    var timerCountdown: Int = 0
    var focusTapPoint: CGPoint?
    /// A long press pinned focus and exposure. Shown as a badge, because a camera that
    /// has silently stopped metering is the kind of thing a user discovers in the photo.
    var isFocusLocked: Bool = false
    /// Which camera is live. Only the Metal preview needs it — to mirror — but it belongs in
    /// state rather than being read off the service in a view, like everything else here.
    var isUsingFrontCamera: Bool = false
    /// The lens is being swapped. Held in state so the viewfinder transition covers the
    /// real reconfiguration rather than a guessed delay.
    var isSwitchingCamera: Bool = false
    var exposureBias: Float = 0.0
    var captureStage: CaptureStage = .idle
    /// Encryption and the vault write are still running. Drives the ring around the
    /// thumbnail, which is the honest way to say "this is not saved yet" now that the
    /// animation no longer waits for it.
    var isSealing: Bool = false
    var latestCapturedThumbnailData: Data?
    /// A phone call, another app taking the camera, Split View. The viewfinder is frozen
    /// and the screen has to say so rather than showing a black rectangle.
    var isSessionInterrupted: Bool = false
    /// The Camera Control HUD is over the screen. Apple's guidance is to get out of its
    /// way, and two sets of controls arguing for the same corner is worse than one.
    var isHardwareHUDVisible: Bool = false
    var alert: CameraAlert?

    var isAuthorized: Bool { authorization == .authorized }

    /// The shutter is unavailable while a frame is in the pipeline: two taps used to
    /// overwrite the pending capture continuation.
    var isCaptureBusy: Bool { captureStage != .idle }

    /// The self-timer delays offered, in the order they are shown.
    static let timerDelayOptions: [Int] = CameraTimerOption.all

    var formattedDuration: String {
        let mins = recordingDurationSeconds / 60
        let secs = recordingDurationSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

@MainActor
@Observable
final class CameraViewModel {
    typealias State = CameraState

    enum Action {
        case onAppear
        case onDisappear
        case setMode(CameraMode)
        case toggleFlash
        case toggleTorch
        case toggleGrid
        case toggleTimerMenu
        case setTimerDelay(Int)
        case setZoom(CGFloat, animated: Bool)
        case toggleFilterPicker
        case setFilter(CameraFilter)
        case toggleCensorPicker
        case setCensorMode(CameraCensorMode)
        case toggleHorizonLevel
        case focusAt(devicePoint: CGPoint, viewPoint: CGPoint, locked: Bool)
        case clearFocusLock
        case setExposureBias(Float)
        case switchCamera
        case shutterTapped
        case captureFlightCompleted
        /// Backgrounding does not fire `onDisappear`, so the session would keep the
        /// camera (and the mic, in video mode) while the app was not on screen.
        case scenePhaseChanged(isActive: Bool)
        /// Sent once the view can resolve the HUD titles, which needs the language store.
        case installHardwareControls(CameraControlLabels)
        case dismissAlert
        case dismiss
    }

    private(set) var state = CameraState()

    /// `@ObservationIgnored` on every dependency below, and it is not a formality: without
    /// it the macro synthesises tracking for `let`s that can never change, so a view reading
    /// `cameraService.session` registers a dependency on a constant and pays for it on every
    /// access.
    @ObservationIgnored let cameraService: any CameraCapturing

    /// Everything the camera used to know about storage now lives behind this.
    @ObservationIgnored private let handler: any CameraArtifactHandler
    /// Dismissal is the host's: a package that owns a router cannot be dropped into a
    /// project that routes differently. Opening the library is the *view's* business and
    /// does not pass through here at all — same reason the repo keeps `pushView` out of
    /// ViewModels.
    @ObservationIgnored private let onDismiss: () -> Void

    /// For the captured still, not the live overlay — the overlay owns its own, because
    /// pushing a quad through `state` at detection rate would invalidate every view reading
    /// it. See `DocumentScanOverlay`.
    @ObservationIgnored private let documentDetector = DocumentDetector()

    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    /// Whether a recording streams to the host or produces a file. Kept here as well as in
    /// the service because the *destination* is opened before recording starts, and only the
    /// screen can ask the host for one.
    @ObservationIgnored private let recordingEngine: CameraRecordingEngine
    /// The host's destination for the recording in flight.
    @ObservationIgnored private var videoSink: (any CaptureVideoSink)?
    /// Opening the destination is asynchronous — a key to generate, a file to create — so a
    /// stop can arrive before the start finished. Awaiting this is what stops a recording
    /// being started after it was ended.
    @ObservationIgnored private var recordingStartTask: Task<Void, Never>?

    init(
        handler: any CameraArtifactHandler,
        onDismiss: @escaping () -> Void,
        cameraService: (any CameraCapturing)? = nil,
        recordingEngine: CameraRecordingEngine = .movieFile,
        previewEngine: CameraPreviewEngine = .system
    ) {
        self.handler = handler
        self.onDismiss = onDismiss
        self.recordingEngine = recordingEngine
        // The engine reaches the service at construction because it decides which outputs go
        // on the session, which cannot be changed once a recording is in flight.
        let service = cameraService ?? CameraService(
            recordingEngine: recordingEngine,
            previewEngine: previewEngine
        )
        self.cameraService = service
        // Read at construction rather than on appear, because it is a fact about how the
        // service was configured and cannot change while the screen is alive. Read on appear,
        // the censor control would be missing from the first render of every launch.
        self.state.isCensorSupported = service.isCensorSupported
        refreshZoomCapabilities()
    }

    func send(_ action: Action) {
        switch action {
        case .onAppear:
            cameraService.onAvailabilityChange = { [weak self] isAvailable in
                Task { @MainActor in
                    self?.state.isSessionInterrupted = !isAvailable
                }
            }
            cameraService.onHorizonMotion = { [weak self] angle, isLevel in
                Task { @MainActor in
                    self?.state.horizonAngle = angle
                    self?.state.isHorizonLevel = isLevel
                }
            }
            cameraService.startMotionObserver()
            Task {
                let authorized = await cameraService.setupSession()
                state.authorization = authorized ? .authorized : .denied
                if authorized {
                    refreshZoomCapabilities()
                    state.isUsingFrontCamera = cameraService.isUsingFrontCamera
                }
            }
            cameraService.onHardwareControlChange = { [weak self] change in
                Task { @MainActor in
                    self?.handle(change)
                }
            }
            Task {
                // Reading the newest thumbnail means a disk read plus an AES-GCM
                // decrypt. Doing it inline hitched the first frame of the screen.
                if let data = await handler.latestThumbnail() {
                    state.latestCapturedThumbnailData = data
                }
            }

        case .onDisappear:
            stopCountdown()
            cameraService.stopMotionObserver()
            // A recording in flight is *finished*, not abandoned. It used to be dropped, which
            // silently lost the clip; with a streaming destination it would also leave the
            // host holding a half-written item nobody ever completes. The session is stopped
            // afterwards, because stopping it first races the writer — and only then, because
            // with nothing recording there is nothing to wait for.
            if state.isRecording {
                Task {
                    await finishRecordingIfNeeded()
                    cameraService.stopSession()
                }
            } else {
                stopRecordingTimer()
                cameraService.stopSession()
            }

        case .scenePhaseChanged(let isActive):
            if isActive {
                Task {
                    let authorized = await cameraService.setupSession()
                    state.authorization = authorized ? .authorized : .denied
                    if authorized {
                        refreshZoomCapabilities()
                        state.isSessionInterrupted = false
                    }
                }
            } else {
                stopCountdown()
                if state.isRecording {
                    Task {
                        await finishRecordingIfNeeded()
                        cameraService.stopSession()
                    }
                } else {
                    stopRecordingTimer()
                    cameraService.stopSession()
                }
            }

        case .setMode(let mode):
            guard !state.isRecording, mode != state.mode else { return }
            state.mode = mode
            // A mode that cannot carry the look loses it, rather than showing a filtered
            // viewfinder over a file that will not have it. Video on the default engine never
            // passes through this app at all, and a warmed-up scan is a document somebody
            // adjusted.
            if !mode.supportsFilters {
                state.filter = .original
                state.isFilterPickerOpen = false
            }
            if mode.isContinuousCapture {
                state.isTorchOn = false
            }
            // The microphone is attached here and nowhere else. Adding it at setup put the
            // orange in-use indicator on screen and stopped the user's music, on a screen
            // that may only ever take a photo.
            Task { await cameraService.setAudioEnabled(mode.needsAudio) }
            CameraHaptic.selection.play()

        case .toggleFlash:
            switch state.flashMode {
            case .auto: state.flashMode = .on
            case .on: state.flashMode = .off
            case .off: state.flashMode = .auto
            }
            cameraService.flashMode = state.flashMode
            CameraHaptic.selection.play()

        case .toggleTorch:
            state.isTorchOn.toggle()
            cameraService.setTorch(on: state.isTorchOn)
            CameraHaptic.selection.play()

        case .toggleGrid:
            state.isGridEnabled.toggle()
            CameraHaptic.selection.play()

        case .toggleTimerMenu:
            state.isTimerMenuOpen.toggle()
            CameraHaptic.light.play()

        case .setTimerDelay(let seconds):
            // Chosen from a list, not cycled. Three taps to get back to Off was the kind
            // of control that only works if you already know how many stops it has.
            guard CameraState.timerDelayOptions.contains(seconds) else { return }
            state.timerDelaySeconds = seconds
            state.isTimerMenuOpen = false
            if seconds == 0 {
                stopCountdown()
            }
            CameraHaptic.selection.play()

        case .toggleFilterPicker:
            state.isFilterPickerOpen.toggle()
            if state.isFilterPickerOpen {
                state.isCensorPickerOpen = false
            }
            CameraHaptic.selection.play()

        case .setFilter(let filter):
            guard state.mode.supportsFilters else { return }
            state.filter = filter
            state.isFilterPickerOpen = false
            CameraHaptic.selection.play()

        case .toggleCensorPicker:
            guard state.isCensorSupported else { return }
            state.isCensorPickerOpen.toggle()
            if state.isCensorPickerOpen {
                state.isFilterPickerOpen = false
                state.isTimerMenuOpen = false
            }
            CameraHaptic.selection.play()

        case .setCensorMode(let mode):
            // Refused rather than accepted-and-ignored. A censor mode this build cannot honour
            // is not a degraded feature, it is a screen telling the user their face is covered
            // while it records it.
            guard state.isCensorSupported else { return }
            state.censorMode = mode
            cameraService.censorMode = mode
            state.isCensorPickerOpen = false
            CameraHaptic.selection.play()

        case .toggleHorizonLevel:
            state.isHorizonLevelEnabled.toggle()
            CameraHaptic.selection.play()

        case .setZoom(let factor, let animated):
            // Clamped here rather than in the view, which had its own 0.5...10 guess and
            // let the pinch gesture promise zoom the lens could not deliver.
            let clamped: CGFloat
            if let range = state.zoomRange {
                clamped = min(max(factor, range.lowerBound), range.upperBound)
            } else {
                clamped = factor
            }
            state.currentZoom = clamped
            cameraService.setZoom(factor: clamped, animated: animated)

        case .focusAt(let devicePoint, let viewPoint, let locked):
            state.focusTapPoint = viewPoint
            state.isFocusLocked = locked
            cameraService.focus(at: devicePoint, locked: locked)
            if locked {
                CameraHaptic.rigid.play()
            } else {
                CameraHaptic.light.play()
            }

        case .clearFocusLock:
            guard state.isFocusLocked else { return }
            state.isFocusLocked = false
            state.exposureBias = 0
            state.focusTapPoint = nil
            cameraService.resetFocusAndExposure()
            CameraHaptic.light.play()

        case .setExposureBias(let bias):
            state.exposureBias = bias
            cameraService.setExposureBias(bias)

        case .switchCamera:
            guard !state.isSwitchingCamera else { return }
            CameraHaptic.medium.play()
            state.isSwitchingCamera = true

            // Everything the *old* camera was holding goes with it. The new device comes up at
            // its own defaults — 1× zoom, no torch, no exposure compensation, metering
            // continuously — and every one of these left behind is a control whose label
            // describes a camera that is no longer there: a torch button lit with nothing lit,
            // a pill saying 3× on a lens sitting at 1×, an exposure badge for a bias the new
            // device never received. Focus was already cleared here; the rest belong with it.
            state.isFocusLocked = false
            state.focusTapPoint = nil
            state.isTorchOn = false
            state.exposureBias = 0

            Task {
                await cameraService.switchCamera()
                // The front camera has a different set of lenses; re-reading is the only
                // way the pill stops advertising the back camera's. Reset rather than clamped:
                // the service puts the new device at 1×, so keeping the old factor would leave
                // the number on the pill disagreeing with the lens.
                refreshZoomCapabilities(resettingZoom: true)
                state.isUsingFrontCamera = cameraService.isUsingFrontCamera
                state.isSwitchingCamera = false
            }

        case .shutterTapped:
            handleShutterTap()

        case .captureFlightCompleted:
            state.captureStage = .idle

        case .installHardwareControls(let labels):
            cameraService.setHardwareControlLabels(labels)
            Task { await cameraService.installHardwareControls(labels: labels) }

        case .dismissAlert:
            state.alert = nil

        case .dismiss:
            CameraHaptic.light.play()
            onDismiss()
        }
    }

    // MARK: - Camera Control

    /// The lens picker has already moved the device by the time this runs — it applies the
    /// factor itself so the HUD feels attached to the button — so the index is recorded
    /// rather than re-applied. Exposure and the timer have no such shortcut and go through
    /// the ordinary actions.
    private func handle(_ change: CameraHardwareControlChange) {
        switch change {
        case .lensIndex(let index):
            guard state.zoomLevels.indices.contains(index) else { return }
            state.currentZoom = state.zoomLevels[index]

        case .exposureBias(let bias):
            send(.setExposureBias(bias))

        case .timerOptionIndex(let index):
            guard CameraState.timerDelayOptions.indices.contains(index) else { return }
            send(.setTimerDelay(CameraState.timerDelayOptions[index]))

        case .hudFullscreen(let isVisible):
            state.isHardwareHUDVisible = isVisible
        }
    }

    // MARK: - Capture

    private func handleShutterTap() {
        guard !state.isSwitchingCamera else { return }
        switch state.mode {
        case .photo:
            guard !state.isCaptureBusy else { return }
            if state.timerDelaySeconds > 0 {
                startCountdownThenCapture()
            } else {
                capturePhoto()
            }

        case .video:
            if state.isRecording {
                stopVideoRecording()
            } else {
                startVideoRecording()
            }

        case .scan:
            guard !state.isCaptureBusy else { return }
            captureScan()
        }
    }

    private func startCountdownThenCapture() {
        state.timerCountdown = state.timerDelaySeconds
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while state.timerCountdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if state.timerCountdown > 1 {
                    state.timerCountdown -= 1
                    CameraHaptic.light.play()
                } else {
                    state.timerCountdown = 0
                    capturePhoto()
                    break
                }
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        state.timerCountdown = 0
    }

    private func capturePhoto() {
        // The curtain drops on this line, not when the sensor answers. It is the only
        // thing standing between the tap and the first visible frame of feedback.
        state.captureStage = .exposing
        state.isSealing = true
        CameraHaptic.rigid.play()

        Task {
            do {
                guard let shot = try await cameraService.capturePhoto() else {
                    state.captureStage = .idle
                    state.isSealing = false
                    return
                }

                // The look is baked in here, off the main actor, from the same matrix the
                // viewfinder drew with. The *preview* is filtered too — it is what the flight
                // card flies, and a card that does not match the photo it represents is the
                // one frame of feedback the user gets telling them the wrong thing.
                let tone = state.filter.tone
                let filtered = await Task.detached(priority: .userInitiated) {
                    (
                        full: ToneRenderer.apply(tone, to: shot.data),
                        preview: shot.preview.flatMap { ToneRenderer.apply(tone, to: $0) }
                    )
                }.value

                guard let full = filtered.full else {
                    // Refused rather than stored unfiltered: a photo that silently ignores the
                    // look the user picked is worse than one that says it failed.
                    state.captureStage = .idle
                    state.isSealing = false
                    state.alert = CameraAlert(
                        title: .cameraKit("Error"),
                        message: .cameraKit("Photo could not be saved")
                    )
                    CameraHaptic.error.play()
                    return
                }

                let artifact = CaptureArtifact(
                    kind: .photo,
                    data: full.data,
                    fileExtension: full.fileExtension,
                    previewData: filtered.preview?.data
                )
                // `preview` is a ~1 MP frame from the same capture, so the card is sharp
                // without waiting for encryption.
                try await seal(artifact, flying: filtered.preview?.data ?? full.data)
            } catch {
                // A capture already in the air is left to land; only the seal failed.
                if state.captureStage == .exposing {
                    state.captureStage = .idle
                }
                state.isSealing = false
                state.alert = CameraAlert(title: .cameraKit("Error"), message: .cameraKit("Photo could not be saved"))
                CameraHaptic.error.play()
            }
        }
    }

    /// Capture, flatten, store.
    ///
    /// The curtain and the haptic are the same as a photo, because to the user this is still
    /// one shutter press. What differs is that the bytes are transformed before anyone sees
    /// them, so the card that flies is the *finished page* rather than the frame — landing a
    /// skewed photo of a desk and replacing it a moment later would read as a glitch.
    private func captureScan() {
        state.captureStage = .exposing
        state.isSealing = true
        CameraHaptic.rigid.play()

        Task {
            do {
                guard let shot = try await cameraService.capturePhoto() else {
                    state.captureStage = .idle
                    state.isSealing = false
                    return
                }

                // Off the main actor: detection plus a perspective warp on a 12 MP frame is
                // tens of milliseconds at best, and it is happening while the curtain is
                // down.
                let detector = documentDetector
                let page = await Task.detached(priority: .userInitiated) {
                    DocumentPageRenderer.scan(data: shot.data, detector: detector)
                }.value

                guard let page else {
                    // Deliberately not falling back to the uncorrected frame. A scanner that
                    // quietly saves a skewed photo of a desk teaches the user the mode is
                    // unreliable without ever saying what went wrong.
                    state.captureStage = .idle
                    state.isSealing = false
                    state.alert = CameraAlert(
                        title: .cameraKit("Error"),
                        message: .cameraKit("Could not read the document")
                    )
                    CameraHaptic.error.play()
                    return
                }

                let artifact = CaptureArtifact(
                    kind: .document,
                    data: page,
                    fileExtension: "jpg",
                    previewData: page
                )
                try await seal(artifact, flying: page)
            } catch {
                if state.captureStage == .exposing {
                    state.captureStage = .idle
                }
                state.isSealing = false
                state.alert = CameraAlert(
                    title: .cameraKit("Error"),
                    message: .cameraKit("Could not read the document")
                )
                CameraHaptic.error.play()
            }
        }
    }

    /// The tail every still capture shares.
    ///
    /// Extracted because the *order* is the subtle part, not the steps: the display
    /// thumbnail is tens of milliseconds and the encrypted write is hundreds, so asking in
    /// that order means the image is already under the card by the time the flight lands and
    /// the cross-fade has something to fade onto. Written out twice, one copy loses it.
    private func seal(_ artifact: CaptureArtifact, flying flightImage: Data) async throws {
        state.captureStage = .flying(CaptureFlight(id: UUID(), imageData: flightImage))

        if let thumbnail = await handler.displayThumbnail(for: [artifact]) {
            state.latestCapturedThumbnailData = thumbnail
        }

        let receipt = try await handler.store([artifact])
        if let thumbnail = receipt.thumbnailData {
            state.latestCapturedThumbnailData = thumbnail
        }
        state.isSealing = false
        CameraHaptic.success.play()
    }

    private func startVideoRecording() {
        // The UI commits to recording on this line, before the destination is open. The
        // opposite order would mean a shutter that does nothing for as long as it takes the
        // host to generate a key and create a file — and `recordingStartTask` is what keeps a
        // stop in that window honest.
        state.isRecording = true
        state.recordingDurationSeconds = 0
        CameraHaptic.medium.play()

        recordingStartTask = Task {
            do {
                cameraService.startRecording(to: try await makeRecordingDestination())
            } catch {
                // Refused rather than diverted. The one destination this must never silently
                // fall back to is a plaintext file, which is exactly what a locked vault would
                // have produced.
                state.isRecording = false
                stopRecordingTimer()
                state.alert = CameraAlert(
                    title: .cameraKit("Error"),
                    message: .cameraKit("Video could not be saved")
                )
                CameraHaptic.error.play()
            }
        }

        recordingTask?.cancel()
        recordingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                state.recordingDurationSeconds += 1
            }
        }
    }

    /// Where this recording's bytes go.
    ///
    /// Streaming is asked for by the engine and granted by the host: an engine that streams
    /// still falls back to a file when `makeVideoSink` returns `nil`, because a host that has
    /// not implemented one is not an error. A host that *throws* is — that is a destination
    /// it meant to provide and could not, and the recording is refused.
    private func makeRecordingDestination() async throws -> RecordingDestination {
        guard recordingEngine.streamsToHost else {
            return .file(Self.temporaryRecordingURL())
        }
        guard let sink = try await handler.makeVideoSink() else {
            return .file(Self.temporaryRecordingURL())
        }
        videoSink = sink
        return .stream(sink)
    }

    private func stopVideoRecording() {
        Task { await finishRecordingIfNeeded() }
    }

    /// Ends the recording in flight and commits it. Safe to call when there is none.
    ///
    /// One function rather than three, because leaving the screen, backgrounding the app and
    /// tapping the shutter all have to do exactly the same thing — and the two that used to
    /// take a shortcut simply lost the clip.
    private func finishRecordingIfNeeded() async {
        guard state.isRecording else { return }

        stopRecordingTimer()
        state.isRecording = false
        CameraHaptic.medium.play()
        state.isSealing = true

        // A stop can overtake the start: the destination is opened asynchronously.
        await recordingStartTask?.value
        recordingStartTask = nil

        let sink = videoSink
        videoSink = nil

        do {
            guard let output = try await cameraService.stopRecording() else {
                // Nothing was recorded — not an error, but the destination that was opened for
                // it has to be discarded or the host keeps an empty item.
                await sink?.cancel()
                state.isSealing = false
                return
            }

            switch output {
            case .file(let url):
                let artifact = try await VideoArtifactReader.consume(at: url)
                if let poster = artifact.previewData {
                    state.latestCapturedThumbnailData = poster
                    state.captureStage = .flying(CaptureFlight(id: UUID(), imageData: poster))
                }
                let receipt = try await handler.store([artifact])
                if let thumbnail = receipt.thumbnailData {
                    state.latestCapturedThumbnailData = thumbnail
                }

            case .stream(let summary):
                guard let sink else {
                    state.isSealing = false
                    return
                }
                // The poster was taken from the first frame of the recording, so unlike the
                // file path there is nothing to decode and the card can fly immediately.
                if let poster = summary.posterData {
                    state.latestCapturedThumbnailData = poster
                    state.captureStage = .flying(CaptureFlight(id: UUID(), imageData: poster))
                }
                let receipt = try await sink.finish(summary)
                if let thumbnail = receipt.thumbnailData {
                    state.latestCapturedThumbnailData = thumbnail
                }
            }

            state.isSealing = false
            CameraHaptic.success.play()
        } catch {
            // Whatever reached the host is incomplete, and a truncated recording that looks
            // stored is worse than one that failed loudly.
            await sink?.cancel()
            state.isSealing = false
            state.alert = CameraAlert(title: .cameraKit("Error"), message: .cameraKit("Video could not be saved"))
            CameraHaptic.error.play()
        }
    }

    private func stopRecordingTimer() {
        recordingTask?.cancel()
        recordingTask = nil
    }

    /// `resettingZoom` is the difference between the two callers, and it matters.
    ///
    /// On appearance the capabilities arrive a second *after* the screen did, so a zoom the
    /// user chose in that second has to survive — clamped into the range that has only now
    /// been read. On a camera switch the device has genuinely been put back to 1×, so keeping
    /// the old number would leave the pill describing the previous lens.
    private func refreshZoomCapabilities(resettingZoom: Bool = false) {
        let range = cameraService.zoomRange()
        state.zoomLevels = cameraService.availableZoomLevels()
        // A range of exactly 1…1 is what `CameraZoomLadder` returns when it could not make
        // sense of the hardware, not a camera that genuinely cannot zoom. Treated as "not
        // known yet" rather than as a clamp, because clamping every request to 1× on the
        // strength of a failed read is the same bug as dropping it: the device clamps
        // properly on its own, so passing the request through is strictly better.
        state.zoomRange = range.lowerBound < range.upperBound ? range : nil
        // Clamped, not reset. This runs when the session finishes coming up — a second or so
        // after the screen appeared — and it used to overwrite the factor with 1×, so a zoom
        // chosen during that second was visibly snapped back. The pill now keeps what the
        // user picked, and only the range it is clamped into is news.
        let target = resettingZoom ? 1.0 : state.currentZoom
        state.currentZoom = min(max(target, range.lowerBound), range.upperBound)
    }

    // MARK: - Helpers

    private static func temporaryRecordingURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("REC_\(UUID().uuidString).mov")
    }
}

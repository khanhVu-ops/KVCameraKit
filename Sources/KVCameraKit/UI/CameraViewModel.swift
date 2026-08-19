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

    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    init(
        handler: any CameraArtifactHandler,
        onDismiss: @escaping () -> Void,
        cameraService: (any CameraCapturing)? = nil
    ) {
        self.handler = handler
        self.onDismiss = onDismiss
        self.cameraService = cameraService ?? CameraService()
    }

    func send(_ action: Action) {
        switch action {
        case .onAppear:
            cameraService.onAvailabilityChange = { [weak self] isAvailable in
                Task { @MainActor in
                    self?.state.isSessionInterrupted = !isAvailable
                }
            }
            Task {
                let authorized = await cameraService.setupSession()
                state.authorization = authorized ? .authorized : .denied
                if authorized {
                    refreshZoomCapabilities()
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
            stopRecordingTimer()
            stopCountdown()
            cameraService.stopSession()

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
                stopRecordingTimer()
                stopCountdown()
                state.isRecording = false
                cameraService.stopSession()
            }

        case .setMode(let mode):
            guard !state.isRecording, mode != state.mode else { return }
            state.mode = mode
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
            state.isFocusLocked = false
            state.focusTapPoint = nil
            Task {
                await cameraService.switchCamera()
                // The front camera has a different set of lenses; re-reading is the only
                // way the pill stops advertising the back camera's.
                refreshZoomCapabilities()
                state.isSwitchingCamera = false
            }

        case .shutterTapped:
            handleShutterTap()

        case .captureFlightCompleted:
            state.captureStage = .idle

        case .installHardwareControls(let labels):
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

                // Fly now, seal after. `preview` is a ~1 MP frame from the same
                // capture, so the card is sharp without waiting for encryption.
                let flightImage = shot.preview ?? shot.data
                state.captureStage = .flying(CaptureFlight(id: UUID(), imageData: flightImage))

                let artifact = CaptureArtifact(
                    kind: .photo,
                    data: shot.data,
                    fileExtension: shot.fileExtension,
                    previewData: shot.preview
                )

                // Cheap half first, expensive half second. The display thumbnail is tens
                // of milliseconds and the encrypted write is hundreds, so asking in that
                // order means the image is already under the card by the time it lands
                // and the cross-fade has something to fade onto.
                if let thumbnail = await handler.displayThumbnail(for: [artifact]) {
                    state.latestCapturedThumbnailData = thumbnail
                }

                let receipt = try await handler.store([artifact])
                if let thumbnail = receipt.thumbnailData {
                    state.latestCapturedThumbnailData = thumbnail
                }
                state.isSealing = false
                CameraHaptic.success.play()
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

    private func startVideoRecording() {
        let tempURL = Self.temporaryRecordingURL()
        cameraService.startRecording(to: tempURL)
        state.isRecording = true
        state.recordingDurationSeconds = 0
        CameraHaptic.medium.play()

        recordingTask?.cancel()
        recordingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                state.recordingDurationSeconds += 1
            }
        }
    }

    private func stopVideoRecording() {
        stopRecordingTimer()
        state.isRecording = false
        CameraHaptic.medium.play()

        state.isSealing = true

        Task {
            do {
                guard let outputURL = try await cameraService.stopRecording() else {
                    state.isSealing = false
                    return
                }

                let artifact = try await VideoArtifactReader.consume(at: outputURL)
                if let poster = artifact.previewData {
                    state.latestCapturedThumbnailData = poster
                    state.captureStage = .flying(CaptureFlight(id: UUID(), imageData: poster))
                }

                let receipt = try await handler.store([artifact])
                if let thumbnail = receipt.thumbnailData {
                    state.latestCapturedThumbnailData = thumbnail
                }
                state.isSealing = false
                CameraHaptic.success.play()
            } catch {
                state.isSealing = false
                state.alert = CameraAlert(title: .cameraKit("Error"), message: .cameraKit("Video could not be saved"))
                CameraHaptic.error.play()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTask?.cancel()
        recordingTask = nil
    }

    private func refreshZoomCapabilities() {
        let range = cameraService.zoomRange()
        state.zoomLevels = cameraService.availableZoomLevels()
        state.zoomRange = range
        state.currentZoom = min(max(1.0, range.lowerBound), range.upperBound)
    }

    // MARK: - Helpers

    private static func temporaryRecordingURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("REC_\(UUID().uuidString).mov")
    }
}

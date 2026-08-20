import AVFoundation
import CoreGraphics
import Foundation

/// The `CameraCapturing` implementation, and the one owner of the session.
///
/// What is left here after the split is deliberately only three things: the
/// `AVCaptureSession`, the active device, and the queue everything is serialised on. Each
/// subsystem below owns its own AVFoundation objects and receives the device as an argument,
/// so there is exactly one place a device can change hands — `configureSession` and
/// `switchCamera` — instead of five objects holding a reference that goes stale on a swap.
///
/// It stayed a thousand lines for a while, and the cost was not length: photo settings,
/// zoom arithmetic, KVO lifetimes, an audio route and two delegate conformances all sat in
/// one `@unchecked Sendable` class, so every question about any of them started by working
/// out which queue the answer was on.
final class CameraService: NSObject, CameraCapturing, @unchecked Sendable {

    let session = AVCaptureSession()

    private var activeDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private(set) var currentPosition: CameraPosition = .back

    var flashMode: CameraFlashMode = .auto
    private(set) var isTorchOn: Bool = false

    var onAvailabilityChange: (@Sendable (Bool) -> Void)?
    var onHardwareControlChange: (@Sendable (CameraHardwareControlChange) -> Void)?

    /// Whether *we* started the session.
    ///
    /// Availability is only meaningful for a running session. Reporting it from
    /// `isRunning` alone painted "Camera is unavailable" over a session that had simply
    /// never been started — which is every simulator run, where `setupSession()` returns
    /// `true` without configuring anything.
    private var isSessionStarted = false

    private let sessionQueue = DispatchQueue(label: "com.iosvault.camera.sessionQueue")

    /// Chosen at construction, because it decides which outputs go on the session — see
    /// `CameraRecordingEngine.usesSampleBuffers`.
    private let recordingEngine: CameraRecordingEngine

    private let photo = PhotoCaptureCoordinator()
    /// Built in `init` rather than lazily, because it needs the session and the queue that
    /// serialises it. Constructing it attaches nothing — see `CameraFrameTap.addConsumer`.
    private var frameTap: FrameSource!
    private let movie = MovieRecordingCoordinator()
    private let audio = CameraAudioSession()
    /// Only built for the asset-writer engine. The movie-file engine gets its audio from the
    /// session input, exactly as before.
    private let audioTap = CameraAudioTap()
    private let assetWriter = AssetWriterRecorder()
    /// Held for the duration of a recording, so the frame tap keeps delivering.
    private var recordingSubscription: FrameSubscription?
    /// Whether the microphone output is really on the session. False on a simulator, where
    /// there is no session at all — and the writer needs to know before it creates a track it
    /// would never fill.
    private var isAudioTapAttached = false
    private var hardwareControls: CameraHardwareControls!
    private var rotation: CameraRotationController!
    private var observer: CameraSessionObserver!

    init(recordingEngine: CameraRecordingEngine = .movieFile) {
        self.recordingEngine = recordingEngine
        super.init()

        // Built here rather than at the property, because each needs a callback into
        // `self`. The alternative — every subsystem holding `weak var service` — is the
        // arrangement that makes a split like this worse than the single class it replaced.
        hardwareControls = CameraHardwareControls(
            onLensPicked: { [weak self] index, factor in
                guard let self = self, let device = self.activeDevice else { return }
                self.applyZoom(to: device, uiFactor: factor, animated: true)
                self.onHardwareControlChange?(.lensIndex(index))
            },
            onChange: { [weak self] change in
                self?.onHardwareControlChange?(change)
            }
        )

        // The simulator has no session at all, so a real `AVCaptureVideoDataOutput` could
        // never deliver a frame there — and every step that comes after this one needs
        // frames. Same trade as `SimulatedCapture`: a synthetic stream keeps the work
        // runnable, and says nothing about performance, which only a device can.
        #if targetEnvironment(simulator)
        frameTap = SimulatedFrameSource()
        #else
        frameTap = CameraFrameTap(session: session, sessionQueue: sessionQueue)
        #endif

        rotation = CameraRotationController(
            applyCaptureAngle: { [weak self] angle in
                self?.applyCaptureRotation(angle)
            }
        )

        observer = CameraSessionObserver(
            onInterrupted: { [weak self] in
                self?.reportAvailability(false)
            },
            onInterruptionEnded: { [weak self] in
                self?.restartIfStarted()
            },
            onRuntimeError: { [weak self] error in
                self?.handleRuntimeError(error)
            },
            onSubjectAreaChange: { [weak self] in
                self?.sessionQueue.async {
                    self?.activeDevice?.applyContinuousFocusAndExposure()
                }
            }
        )
        observer.observe(session)
    }

    // MARK: - Session lifecycle

    func setupSession() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        guard await CameraDeviceDiscovery.requestAuthorization() else { return false }

        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: self.startSessionLocked())
            }
        }

        if started {
            await rotation.refresh(for: activeDevice)
        }
        return started
        #endif
    }

    /// Session queue only.
    private func startSessionLocked() -> Bool {
        // Re-entering the screen, or coming back from the background, must not
        // rebuild a session that is already running.
        if session.isRunning {
            return !session.inputs.isEmpty
        }

        if !session.inputs.isEmpty {
            session.startRunning()
            isSessionStarted = session.isRunning
            return session.isRunning
        }

        return configureSessionLocked()
    }

    /// Session queue only. Builds the session from nothing.
    private func configureSessionLocked() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.photo) ? .photo : .high

        let device = CameraDeviceDiscovery.device(for: .back)
        activeDevice = device

        guard let device = device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }

        session.addInput(input)
        videoInput = input

        // No microphone here. It is attached when the user picks VIDEO — see
        // `setAudioEnabled`.

        if session.canAddOutput(photo.output) {
            session.addOutput(photo.output)
            photo.configureOutput()
        }

        // Deliberately one or the other, never both. `AVCaptureMovieFileOutput` and
        // `AVCaptureVideoDataOutput` coexisting on a session is a constraint that varies by
        // device and configuration, and the failure is silent: `canAddOutput` returns `false`
        // and the frame tap never attaches, so a Metal preview shows black and a scanner
        // never finds a page with nothing logged anywhere. Attaching only what the chosen
        // engine needs means that can never happen.
        if recordingEngine.usesSampleBuffers {
            if session.canAddOutput(audioTap.output) {
                session.addOutput(audioTap.output)
                isAudioTapAttached = true
            }
        } else if session.canAddOutput(movie.output) {
            session.addOutput(movie.output)
        }

        session.commitConfiguration()
        session.startRunning()
        isSessionStarted = session.isRunning

        // Explicitly sync hardware zoom factor to 1.0 (1x Wide)
        applyZoom(to: device, uiFactor: 1.0, animated: false)

        return session.isRunning
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.audio.detach(from: self.session)
            self.isSessionStarted = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() async {
        #if targetEnvironment(simulator)
        currentPosition = currentPosition.flipped
        #else
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.swapCameraLocked()
                continuation.resume()
            }
        }

        // The lens list belongs to the camera, so the coordinator is re-pointed after the
        // swap rather than assumed to still describe the back camera.
        await rotation.refresh(for: activeDevice)
        #endif
    }

    /// Session queue only.
    private func swapCameraLocked() {
        let newPosition = currentPosition.flipped
        guard let newDevice = CameraDeviceDiscovery.device(for: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

        session.beginConfiguration()
        if let currentInput = videoInput {
            session.removeInput(currentInput)
        }

        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            activeDevice = newDevice
            currentPosition = newPosition
        } else if let currentInput = videoInput {
            session.addInput(currentInput)
        }

        session.commitConfiguration()

        // Reset zoom to 1x on switch
        applyZoom(to: newDevice, uiFactor: 1.0, animated: false)
    }

    // MARK: - Audio

    func setAudioEnabled(_ enabled: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                if enabled {
                    self.audio.attach(to: self.session)
                } else {
                    self.audio.detach(from: self.session)
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Zoom

    func availableZoomLevels() -> [CGFloat] {
        #if targetEnvironment(simulator)
        return SimulatedCapture.zoomLevels
        #else
        guard let device = activeDevice else { return [] }
        return CameraZoomLadder.levels(for: device)
        #endif
    }

    func zoomRange() -> ClosedRange<CGFloat> {
        #if targetEnvironment(simulator)
        return SimulatedCapture.zoomRange
        #else
        guard let device = activeDevice else { return 1.0...1.0 }
        return CameraZoomLadder.range(for: device)
        #endif
    }

    func setZoom(factor: CGFloat, animated: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.applyZoom(to: device, uiFactor: factor, animated: animated)
        }
    }

    /// The one path that moves the lens, so the Camera Control HUD cannot be left behind by
    /// a pinch or a tap on the pill.
    private func applyZoom(to device: AVCaptureDevice, uiFactor: CGFloat, animated: Bool) {
        device.applyZoom(uiFactor: uiFactor, animated: animated)
        hardwareControls.syncSelectedLens(for: device)
    }

    // MARK: - Focus & exposure

    func focus(at pointOfInterest: CGPoint, locked: Bool) {
        sessionQueue.async { [weak self] in
            self?.activeDevice?.applyOneShotFocus(at: pointOfInterest, locked: locked)
        }
    }

    func resetFocusAndExposure() {
        sessionQueue.async { [weak self] in
            self?.activeDevice?.applyContinuousFocusAndExposure()
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            self?.activeDevice?.applyExposureBias(bias)
        }
    }

    func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.activeDevice?.applyTorch(on: on) == true {
                self.isTorchOn = on
            }
        }
    }

    // MARK: - Rotation

    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        rotation.attach(previewLayer: layer)
        rotation.refresh(for: activeDevice)
    }

    var isUsingFrontCamera: Bool { currentPosition == .front }

    var frames: any FrameSource { frameTap }

    private func applyCaptureRotation(_ angle: CGFloat) {
        latestCaptureAngle = angle
        // The tap reports this per frame. Same coordinator, same angle as the preview layer —
        // a frame pipeline that derived its own orientation would be a second source of truth
        // for which way is up, and the two would disagree in landscape.
        (frameTap as? CameraFrameTap)?.setRotationAngle(angle)

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            var outputs: [AVCaptureOutput] = [self.photo.output]
            if !self.recordingEngine.usesSampleBuffers {
                outputs.append(self.movie.output)
            }
            for output in outputs {
                guard let connection = output.connection(with: .video),
                      connection.isVideoRotationAngleSupported(angle) else { continue }
                connection.videoRotationAngle = angle
            }
        }
    }

    // MARK: - Camera Control

    func installHardwareControls(labels: CameraControlLabels) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self = self, let device = self.activeDevice else {
                    continuation.resume()
                    return
                }
                self.hardwareControls.install(
                    on: self.session,
                    device: device,
                    levels: self.availableZoomLevels(),
                    labels: labels,
                    queue: self.sessionQueue
                )
                continuation.resume()
            }
        }
    }

    // MARK: - Session availability

    private func restartIfStarted() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.isSessionStarted else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.reportAvailability(self.session.isRunning)
        }
    }

    /// A runtime error is not always fatal: `mediaServicesWereReset` is the common one
    /// and it is recoverable by starting the session again. Without this the viewfinder
    /// stayed black until the user left the screen and came back.
    private func handleRuntimeError(_ error: AVError?) {
        reportAvailability(false)
        guard error?.code == .mediaServicesWereReset else { return }
        restartIfStarted()
    }

    private func reportAvailability(_ isAvailable: Bool) {
        guard isSessionStarted else { return }
        onAvailabilityChange?(isAvailable)
    }

    // MARK: - Capture

    func capturePhoto() async throws -> CapturedPhoto? {
        #if targetEnvironment(simulator)
        return SimulatedCapture.photo()
        #else
        return try await photo.capture(flashMode: flashMode, on: sessionQueue)
        #endif
    }

    func startRecording(to outputURL: URL) {
        switch recordingEngine {
        case .movieFile:
            // Needs a real session, so a simulator can only no-op and hand back a stub on
            // stop — which is what it did before any of this.
            #if targetEnvironment(simulator)
            break
            #else
            movie.start(to: outputURL, on: sessionQueue)
            #endif

        case .assetWriter:
            // No `#if` here, deliberately. This path takes its video from `FrameSource`, and
            // that is simulated on a simulator — so unlike every previous recorder, this one
            // produces a real, playable file on a machine with no camera. Audio is the only
            // part that cannot be faked, and the writer is told so rather than left to create
            // a track nothing fills.
            // The rotation is baked in as a track transform rather than by rotating pixels:
            // one matrix in the container header instead of a full-frame copy 30 times a
            // second, and every player honours it.
            let transform = Self.transform(forCaptureAngle: latestCaptureAngle)
            assetWriter.start(
                to: outputURL,
                transform: transform,
                includesAudio: isAudioTapAttached
            )

            audioTap.setConsumer { [weak self] sampleBuffer in
                self?.assetWriter.appendAudio(sampleBuffer)
            }
            // Subscribing is also what attaches the video data output, so a recording holds
            // the frame stream open for exactly as long as it runs.
            recordingSubscription = frameTap.addConsumer { [weak self] frame in
                self?.assetWriter.appendVideo(frame)
            }
        }
    }

    func stopRecording() async throws -> URL? {
        switch recordingEngine {
        case .movieFile:
            #if targetEnvironment(simulator)
            return SimulatedCapture.video()
            #else
            return try await movie.stop(on: sessionQueue)
            #endif

        case .assetWriter:
            // Unsubscribed *before* finishing, so no sample can arrive after
            // `markAsFinished` — appending to a finished input is a hard failure that
            // invalidates the whole file.
            recordingSubscription?.cancel()
            recordingSubscription = nil
            audioTap.setConsumer(nil)
            return await assetWriter.stop()
        }
    }

    /// The most recent horizon-level capture angle, for the writer's track transform.
    private var latestCaptureAngle: CGFloat = 0

    /// A capture angle in degrees as a track transform.
    ///
    /// Static and pure because "the video is sideways" is the classic recorder bug and it
    /// should not need a device to catch.
    static func transform(forCaptureAngle angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: angle * .pi / 180)
    }
}

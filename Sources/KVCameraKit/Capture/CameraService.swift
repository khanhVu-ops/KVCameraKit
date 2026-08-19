import AVFoundation
import UIKit

/// AVFoundation camera controller managing photo capture, video recording, multi-lens switching, zoom, focus, and flash.
final class CameraService: NSObject, CameraCapturing, @unchecked Sendable {
    enum CameraPosition {
        case back
        case front
    }

    let session = AVCaptureSession()

    private var activeDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    /// Delegate callbacks arrive on a queue AVFoundation owns, while the continuations
    /// are installed from `sessionQueue`. Two queues touching the same slot is a data
    /// race with two visible outcomes: a continuation resumed twice (crash) or one
    /// dropped (a `Task` that never finishes). Every access goes through this lock, and
    /// the slot doubles as the one-capture-at-a-time guard.
    private let continuationLock = NSLock()
    private var photoContinuation: CheckedContinuation<CapturedPhoto?, Error>?
    private var videoContinuation: CheckedContinuation<URL?, Error>?

    private(set) var currentPosition: CameraPosition = .back
    var flashMode: CameraFlashMode = .auto
    var isTorchOn: Bool = false
    private(set) var isSimulator: Bool = false

    var onAvailabilityChange: (@Sendable (Bool) -> Void)?
    var onHardwareControlChange: (@Sendable (CameraHardwareControlChange) -> Void)?

    /// Whether *we* started the session.
    ///
    /// Availability is only meaningful for a running session. Reporting it from
    /// `isRunning` alone painted "Camera is unavailable" over a session that had simply
    /// never been started — which is every simulator run, where `setupSession()` returns
    /// `true` without configuring anything.
    private var isSessionStarted = false

    /// Owned by the view. Held weakly so the layer's own lifetime decides when it goes.
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []

    /// Kept so the HUD's highlighted lens can follow a pinch or a tap on the pill. Without
    /// it the button would keep saying `1×` after the screen had moved on.
    private var lensPicker: AVCaptureIndexPicker?
    private var lensLevels: [CGFloat] = []

    private let sessionQueue = DispatchQueue(label: "com.iosvault.camera.sessionQueue")

    override init() {
        super.init()
        #if targetEnvironment(simulator)
        isSimulator = true
        #endif
        addSessionObservers()
    }

    deinit {
        rotationObservations.forEach { $0.invalidate() }
        NotificationCenter.default.removeObserver(self)
    }

    func checkPermissions() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let videoAuth = AVCaptureDevice.authorizationStatus(for: .video)
        if videoAuth == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted
        }
        return videoAuth == .authorized
        #endif
    }

    func setupSession() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        guard await checkPermissions() else { return false }

        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                // Re-entering the screen, or coming back from the background, must not
                // rebuild a session that is already running.
                guard !self.session.isRunning else {
                    if self.session.inputs.isEmpty {
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(returning: true)
                    }
                    return
                }

                if !self.session.inputs.isEmpty {
                    self.session.startRunning()
                    self.isSessionStarted = self.session.isRunning
                    continuation.resume(returning: self.session.isRunning)
                    return
                }

                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.photo) {
                    self.session.sessionPreset = .photo
                } else {
                    self.session.sessionPreset = .high
                }

                // Configure Camera Input
                let device = self.getDevice(for: .back)
                self.activeDevice = device

                guard let device = device,
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    continuation.resume(returning: false)
                    return
                }

                self.session.addInput(input)
                self.videoInput = input

                // No microphone here. It is attached when the user picks VIDEO — see
                // `setAudioEnabled`.

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.configurePhotoOutput()
                }

                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }

                self.session.commitConfiguration()
                self.session.startRunning()
                self.isSessionStarted = self.session.isRunning

                // Explicitly sync hardware zoom factor to 1.0 (1x Wide)
                self.applyZoomToDevice(device, factor: 1.0, animated: false)

                continuation.resume(returning: self.session.isRunning)
            }
        }

        if started {
            await refreshRotationCoordinator()
        }
        return started
        #endif
    }

    /// Must run inside `beginConfiguration()`.
    ///
    /// `maxPhotoQualityPrioritization` is the ceiling, not the setting — the old code
    /// read it and assigned it back to itself, which did nothing. The per-shot value in
    /// `makePhotoSettings` stays `.balanced`, which is what Camera.app uses: `.quality`
    /// on every frame adds shutter latency the animation then has to hide.
    ///
    /// Zero-shutter-lag and responsive capture are the reason a modern iPhone returns a
    /// frame in tens of milliseconds instead of hundreds, and they are the cheapest
    /// possible win for how immediate the capture feels. They must be enabled in this
    /// order: zero shutter lag, then responsive capture, then fast prioritization.
    private func configurePhotoOutput() {
        photoOutput.maxPhotoQualityPrioritization = .quality

        if photoOutput.isZeroShutterLagSupported {
            photoOutput.isZeroShutterLagEnabled = true
        }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = true
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.detachAudioLocked()
            self.isSessionStarted = false
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func switchCamera() async {
        #if targetEnvironment(simulator)
        currentPosition = (currentPosition == .back) ? .front : .back
        #else
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                let newPosition: CameraPosition = (self.currentPosition == .back) ? .front : .back
                guard let newDevice = self.getDevice(for: newPosition),
                      let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                    continuation.resume()
                    return
                }

                self.session.beginConfiguration()
                if let currentInput = self.videoInput {
                    self.session.removeInput(currentInput)
                }

                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoInput = newInput
                    self.activeDevice = newDevice
                    self.currentPosition = newPosition
                } else if let currentInput = self.videoInput {
                    self.session.addInput(currentInput)
                }

                self.session.commitConfiguration()

                // Reset zoom to 1x on switch
                self.applyZoomToDevice(newDevice, factor: 1.0, animated: false)
                continuation.resume()
            }
        }

        // The lens list belongs to the camera, so it is re-read after the swap rather
        // than assumed to be the same one the back camera published.
        await refreshRotationCoordinator()
        #endif
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
                    self.attachAudioLocked()
                } else {
                    self.detachAudioLocked()
                }
                continuation.resume()
            }
        }
    }

    /// `sessionQueue` only.
    private func attachAudioLocked() {
        guard audioInput == nil else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try? audioSession.setActive(true)

        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: audioDevice) else { return }

        session.beginConfiguration()
        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
        session.commitConfiguration()
    }

    /// `sessionQueue` only.
    ///
    /// `.notifyOthersOnDeactivation` is what lets whatever the user was listening to
    /// resume. Leaving the session active held the audio route for as long as the app
    /// was open.
    private func detachAudioLocked() {
        if let audioInput = audioInput {
            session.beginConfiguration()
            session.removeInput(audioInput)
            session.commitConfiguration()
            self.audioInput = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Zoom

    func availableZoomLevels() -> [CGFloat] {
        #if targetEnvironment(simulator)
        // A stand-in, same as the simulated capture: without it the screen cannot be
        // inspected on a simulator at all. Fed through the real ladder so what shows up
        // here has the same shape it will have on an iPhone 16.
        return Self.zoomLevels(optical: [0.5, 1.0], maxFactor: 15.0)
        #else
        guard let device = activeDevice else { return [] }
        let base = baseZoomFactor(for: device)
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }

        let optical = device.constituentDevices.indices.compactMap { index -> CGFloat? in
            let deviceFactor: CGFloat
            if index == 0 {
                deviceFactor = device.minAvailableVideoZoomFactor
            } else if index - 1 < switchOvers.count {
                deviceFactor = switchOvers[index - 1]
            } else {
                return nil
            }
            return ((deviceFactor / base) * 10).rounded() / 10
        }

        return Self.zoomLevels(
            optical: optical.isEmpty ? [1.0] : optical,
            maxFactor: Self.maxUIZoomFactor(for: device, base: base)
        )
        #endif
    }

    /// The lens list, topped up with the steps a user expects to find.
    ///
    /// Optical constituents alone are not the whole answer. An iPhone 16 has exactly two
    /// lenses — ultra wide and wide — so listing only those gave `0,5 · 1×` and dropped
    /// the `2×` that Camera.app shows, because on a 48 MP sensor that step is a crop
    /// rather than a lens and no API reports it as one. The rungs below are added only
    /// when the hardware range actually reaches them, so nothing on the pill is a
    /// promise the device cannot keep.
    ///
    /// The candidates stop at 5: past that it is plain digital crop, and a chip that
    /// offers 10× is advertising a blurry photo. Together with the optical lenses this
    /// lands on `0,5 · 1 · 2 · 3 · 5` on both an iPhone 16 and a Pro, which is the point —
    /// the same list, arrived at from different hardware.
    ///
    /// Pure and static so the shape of the list is testable without a device.
    static func zoomLevels(
        optical: [CGFloat],
        maxFactor: CGFloat,
        candidates: [CGFloat] = [2.0, 3.0, 5.0],
        limit: Int = 5
    ) -> [CGFloat] {
        var levels = optical.filter { $0 <= maxFactor + 0.05 }.sorted()

        for candidate in candidates {
            guard levels.count < limit else { break }
            guard candidate <= maxFactor + 0.05 else { continue }
            // Within a fifth of an existing rung it is the same chip to the user.
            guard !levels.contains(where: { abs($0 - candidate) < 0.2 }) else { continue }
            levels.append(candidate)
            levels.sort()
        }

        return levels.count > 1 ? levels : []
    }

    func zoomRange() -> ClosedRange<CGFloat> {
        #if targetEnvironment(simulator)
        return 0.5...15.0
        #else
        guard let device = activeDevice else { return 1.0...1.0 }
        let base = baseZoomFactor(for: device)
        let lower = device.minAvailableVideoZoomFactor / base
        let upper = Self.maxUIZoomFactor(for: device, base: base)
        guard lower < upper else { return 1.0...1.0 }
        return lower...upper
        #endif
    }

    /// The ceiling, expressed as the user sees it.
    ///
    /// Clamping `maxAvailableVideoZoomFactor` at 15 and *then* dividing by the base was
    /// clamping in device space: on a phone whose wide lens sits at 2.0 that left a
    /// ceiling of 7,5× and quietly put `5×` near the top of the range. The limit belongs
    /// in the same units as the number on the chip.
    private static func maxUIZoomFactor(for device: AVCaptureDevice, base: CGFloat) -> CGFloat {
        guard base > 0 else { return 1.0 }
        return min(device.maxAvailableVideoZoomFactor / base, 15.0)
    }

    /// The device factor that the user calls "1x".
    ///
    /// The old code assumed `virtualDeviceSwitchOverVideoZoomFactors[0]`, which is only
    /// the wide lens on a device whose widest constituent is an ultra wide. On a
    /// wide + tele dual camera that first switch-over is the *telephoto* threshold, so
    /// "1x" was mapping onto the tele. Reading the wide lens out of
    /// `constituentDevices` is the version that holds for every layout.
    private func baseZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
              wideIndex > 0 else {
            return 1.0
        }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        guard wideIndex - 1 < switchOvers.count else { return 1.0 }
        return switchOvers[wideIndex - 1]
    }

    /// Sets zoom factor with smooth optical/digital transition animation.
    func setZoom(factor: CGFloat, animated: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.applyZoomToDevice(device, factor: factor, animated: animated)
        }
    }

    private func applyZoomToDevice(_ device: AVCaptureDevice, factor: CGFloat, animated: Bool) {
        configure(device) { device in
            let base = baseZoomFactor(for: device)
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = Self.maxUIZoomFactor(for: device, base: base) * base
            let target = factor * base
            let clamped = max(minZoom, min(target, maxZoom))

            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 18.0)
            } else {
                device.videoZoomFactor = clamped
            }
        }

        syncLensPicker(for: device)
    }

    /// Keeps the HUD's highlighted lens in step with whatever moved the zoom.
    private func syncLensPicker(for device: AVCaptureDevice) {
        guard let picker = lensPicker, let index = nearestLensIndex(for: device) else { return }
        guard picker.selectedIndex != index else { return }
        picker.selectedIndex = index
    }

    private func nearestLensIndex(for device: AVCaptureDevice) -> Int? {
        guard !lensLevels.isEmpty else { return nil }
        let base = baseZoomFactor(for: device)
        guard base > 0 else { return nil }
        let current = device.videoZoomFactor / base
        return lensLevels.indices.min(by: {
            abs(lensLevels[$0] - current) < abs(lensLevels[$1] - current)
        })
    }

    // MARK: - Focus & exposure

    func focus(at pointOfInterest: CGPoint, locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.configure(device) { device in
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = pointOfInterest
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = pointOfInterest
                    device.exposureMode = .autoExpose
                }
                // `.autoFocus` is one shot and then holds, so the lock is simply the
                // absence of anything that re-triggers it. Watching the subject area is
                // what hands control back for an ordinary tap — the version before this
                // never did, and one tap left focus locked for the rest of the session.
                device.isSubjectAreaChangeMonitoringEnabled = !locked
            }
        }
    }

    func resetFocusAndExposure() {
        sessionQueue.async { [weak self] in
            self?.applyContinuousFocus()
        }
    }

    @objc private func subjectAreaDidChange(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            self?.applyContinuousFocus()
        }
    }

    /// `sessionQueue` only.
    private func applyContinuousFocus() {
        guard let device = activeDevice else { return }
        configure(device) { device in
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = centre
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = centre
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(0)
            device.isSubjectAreaChangeMonitoringEnabled = false
        }
    }

    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self = self, let device = self.activeDevice else { return }
            self.configure(device) { device in
                let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
                device.setExposureTargetBias(clamped)
            }
        }
    }

    func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.activeDevice,
                  device.hasTorch,
                  device.isTorchAvailable else { return }
            self.configure(device) { device in
                device.torchMode = on ? .on : .off
                self.isTorchOn = on
            }
        }
    }

    /// One place that pairs `lockForConfiguration` with its unlock.
    ///
    /// Seven call sites each had their own `do { try lock } catch {}`, and each one was
    /// a chance to return early while still holding the lock.
    private func configure(_ device: AVCaptureDevice, _ body: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            body(device)
        } catch {}
    }

    // MARK: - Rotation

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        Task { await refreshRotationCoordinator() }
    }

    /// One coordinator drives both the viewfinder and what gets written to disk.
    ///
    /// Every connection used to be pinned to `.portrait`, so a landscape photo came out
    /// rotated. `RotationCoordinator` reports the angle that keeps the horizon level and
    /// publishes it through KVO, which is also how the preview follows the device
    /// without the app watching `UIDevice.orientation` itself.
    @MainActor
    private func refreshRotationCoordinator() async {
        rotationObservations.forEach { $0.invalidate() }
        rotationObservations = []

        guard let device = activeDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                self?.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                self?.applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
            }
        ]
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        Task { @MainActor [weak self] in
            guard let connection = self?.previewLayer?.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            for output in [self.photoOutput as AVCaptureOutput, self.movieOutput as AVCaptureOutput] {
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
                self?.applyHardwareControls(labels)
                continuation.resume()
            }
        }
    }

    /// `sessionQueue` only.
    ///
    /// Three of the four slots AVFoundation allows, chosen because they are the settings
    /// this screen actually has: zoom, exposure compensation and the self-timer. Each one
    /// reports back through `onHardwareControlChange` instead of writing to the device
    /// behind the ViewModel's back, so the pill, the reticle and the timer badge stay
    /// truthful while the button is being used.
    private func applyHardwareControls(_ labels: CameraControlLabels) {
        guard session.supportsControls, let device = activeDevice else { return }

        session.setControlsDelegate(self, queue: sessionQueue)
        session.beginConfiguration()
        for control in session.controls {
            session.removeControl(control)
        }

        // A picker over the lenses, not a continuous slider. The system's own Camera puts a
        // discrete `1× / 2×` list on this button, the on-screen pill is already that list,
        // and one control per value avoids a slider and a picker disagreeing about zoom.
        // Continuous zoom stays where it belongs: pinch, and dragging the pill.
        lensLevels = availableZoomLevels()
        lensPicker = nil
        if lensLevels.count > 1, labels.lensOptions.count == lensLevels.count {
            let picker = AVCaptureIndexPicker(
                labels.zoom,
                symbolName: "arrow.up.left.and.arrow.down.right",
                localizedIndexTitles: labels.lensOptions
            )
            picker.selectedIndex = nearestLensIndex(for: device) ?? 0
            picker.setActionQueue(sessionQueue) { [weak self] index in
                guard let self = self, self.lensLevels.indices.contains(index) else { return }
                self.applyZoomToDevice(device, factor: self.lensLevels[index], animated: true)
                self.onHardwareControlChange?(.lensIndex(index))
            }
            if session.canAddControl(picker) {
                session.addControl(picker)
                lensPicker = picker
            }
        }

        let minBias = device.minExposureTargetBias
        let maxBias = device.maxExposureTargetBias
        if minBias < maxBias {
            let exposure = AVCaptureSlider(labels.exposure, symbolName: "sun.max", in: minBias...maxBias)
            exposure.value = device.exposureTargetBias
            exposure.setActionQueue(sessionQueue) { [weak self] value in
                self?.onHardwareControlChange?(.exposureBias(value))
            }
            if session.canAddControl(exposure) {
                session.addControl(exposure)
            }
        }

        if !labels.timerOptions.isEmpty {
            let timer = AVCaptureIndexPicker(
                labels.timer,
                symbolName: "timer",
                localizedIndexTitles: labels.timerOptions
            )
            timer.setActionQueue(sessionQueue) { [weak self] index in
                self?.onHardwareControlChange?(.timerOptionIndex(index))
            }
            if session.canAddControl(timer) {
                session.addControl(timer)
            }
        }

        session.commitConfiguration()
    }

    // MARK: - Session availability

    private func addSessionObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(subjectAreaDidChange(_:)),
            name: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil
        )
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        reportAvailability(false)
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
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
    @objc private func sessionRuntimeError(_ notification: Notification) {
        reportAvailability(false)
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError,
              error.code == .mediaServicesWereReset else { return }

        sessionQueue.async { [weak self] in
            guard let self = self, self.isSessionStarted else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.reportAvailability(self.session.isRunning)
        }
    }

    private func reportAvailability(_ isAvailable: Bool) {
        guard isSessionStarted else { return }
        onAvailabilityChange?(isAvailable)
    }

    // MARK: - Capture

    func capturePhoto() async throws -> CapturedPhoto? {
        #if targetEnvironment(simulator)
        return generateSimulatedPhoto()
        #else
        // The continuation type is spelled out. Left to inference it resolves to
        // `CapturedPhoto` rather than `CapturedPhoto?`, because `return` may promote a
        // non-optional to the optional return type — and then `resume(returning: nil)`
        // no longer compiles. It only surfaces on a device build, since the simulator
        // takes the branch above.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedPhoto?, Error>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                // A second tap while the first frame is still in the pipeline is dropped
                // here rather than overwriting the pending continuation.
                guard self.installPhotoContinuation(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }

                self.photoOutput.capturePhoto(with: self.makePhotoSettings(), delegate: self)
            }
        }
        #endif
    }

    /// Extracted from the capture closure on purpose.
    ///
    /// Built inline, this ran to a dozen statements inside a `DispatchQueue.async`
    /// closure that also had to infer a continuation type, and the compiler reported the
    /// whole closure as "cannot convert value of type '_' to DispatchWorkItem" rather
    /// than naming the line at fault.
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }

        settings.photoQualityPrioritization = .balanced

        // The small representation that the flight animation flies. Asking for it costs
        // nothing extra — it is produced from the same frame — and it is the difference
        // between a sharp card and the 320 px vault thumbnail stretched across the screen.
        if let previewFormat = settings.availablePreviewPhotoPixelFormatTypes.first {
            var previewSettings: [String: Any] = [:]
            previewSettings[kCVPixelBufferPixelFormatTypeKey as String] = previewFormat
            previewSettings[kCVPixelBufferWidthKey as String] = 1280
            previewSettings[kCVPixelBufferHeightKey as String] = 1280
            settings.previewPhotoFormat = previewSettings
        }

        let supported = photoOutput.supportedFlashModes
        switch flashMode {
        case .auto where supported.contains(.auto): settings.flashMode = .auto
        case .on where supported.contains(.on):     settings.flashMode = .on
        default:
            if supported.contains(.off) {
                settings.flashMode = .off
            }
        }

        return settings
    }

    func startRecording(to outputURL: URL) {
        #if targetEnvironment(simulator)
        #else
        sessionQueue.async { [weak self] in
            guard let self = self, !self.movieOutput.isRecording else { return }
            try? FileManager.default.removeItem(at: outputURL)
            self.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        }
        #endif
    }

    func stopRecording() async throws -> URL? {
        #if targetEnvironment(simulator)
        return generateSimulatedVideo()
        #else
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            sessionQueue.async { [weak self] in
                guard let self = self, self.movieOutput.isRecording else {
                    continuation.resume(returning: nil)
                    return
                }
                guard self.installVideoContinuation(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.movieOutput.stopRecording()
            }
        }
        #endif
    }

    // MARK: - Continuation plumbing

    /// `true` when the slot was free and the continuation now owns the capture.
    private func installPhotoContinuation(_ continuation: CheckedContinuation<CapturedPhoto?, Error>) -> Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        guard photoContinuation == nil else { return false }
        photoContinuation = continuation
        return true
    }

    private func takePhotoContinuation() -> CheckedContinuation<CapturedPhoto?, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let pending = photoContinuation
        photoContinuation = nil
        return pending
    }

    private func installVideoContinuation(_ continuation: CheckedContinuation<URL?, Error>) -> Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        guard videoContinuation == nil else { return false }
        videoContinuation = continuation
        return true
    }

    private func takeVideoContinuation() -> CheckedContinuation<URL?, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let pending = videoContinuation
        videoContinuation = nil
        return pending
    }

    // MARK: - Helpers

    /// Preference order for the back camera: the widest *virtual* device wins, because
    /// only a virtual device exposes constituent lenses — and those are what the `0,5×`
    /// chip and every other optical rung are derived from.
    private static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera
    ]

    private func getDevice(for position: CameraPosition) -> AVCaptureDevice? {
        let pos: AVCaptureDevice.Position = (position == .back) ? .back : .front
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.preferredDeviceTypes,
            mediaType: .video,
            position: pos
        )

        // `discovery.devices.first` is not the first entry of `deviceTypes`: AVFoundation
        // makes no promise that the result is ordered by the types requested. On an
        // iPhone 16 it handed back the plain wide angle, which has no constituent
        // lenses — so `0,5×` vanished from the pill and the list fell back to digital
        // rungs. Walking the preference list explicitly is the only ordering there is.
        for type in Self.preferredDeviceTypes {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos)
    }

    /// Container sniffed from the bytes.
    ///
    /// Capturing HEVC yields an HEIC file. Trusting the codec request instead of the
    /// result is how a HEIC ended up on disk named `.jpg`.
    private static func fileExtension(for data: Data) -> String {
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
            return "jpg"
        }
        if data.count >= 12 {
            let boxType = data.subdata(in: data.startIndex.advanced(by: 4)..<data.startIndex.advanced(by: 8))
            if String(data: boxType, encoding: .ascii) == "ftyp" {
                return "heic"
            }
        }
        return "jpg"
    }

    /// Bakes the sensor orientation into pixels.
    ///
    /// `UIImage.jpegData` on an image whose orientation is not `.up` is not reliably
    /// upright, so the frame goes through a renderer once. It is a ~1 MP image on a
    /// background queue, which is cheaper than one frame of the flight animation.
    private static func uprightJPEG(from cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Data? {
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation(from: orientation))
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let baked = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return baked.jpegData(compressionQuality: 0.9)
    }

    private static func imageOrientation(from orientation: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch orientation {
        case .up:             return .up
        case .upMirrored:     return .upMirrored
        case .down:           return .down
        case .downMirrored:   return .downMirrored
        case .left:           return .left
        case .leftMirrored:   return .leftMirrored
        case .right:          return .right
        case .rightMirrored:  return .rightMirrored
        @unknown default:     return .up
        }
    }

    #if targetEnvironment(simulator)
    private func generateSimulatedPhoto() -> CapturedPhoto? {
        let size = CGSize(width: 1080, height: 1920)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        let colors = [
            UIColor.black.cgColor,
            UIColor.darkGray.cgColor
        ] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }

        let text = "iOS-Vault Encrypted Capture"
        let font = UIFont.systemFont(ofSize: 36, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textRect = CGRect(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        (text as NSString).draw(in: textRect, withAttributes: attrs)

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let data = image?.jpegData(compressionQuality: 0.85) else { return nil }
        return CapturedPhoto(data: data, preview: data, fileExtension: "jpg")
    }

    private func generateSimulatedVideo() -> URL? {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SIM_REC_\(UUID().uuidString).mov")
        let dummyData = Data("SIMULATED_ENCRYPTED_VIDEO_STREAM".utf8)
        try? dummyData.write(to: tempURL)
        return tempURL
    }
    #endif
}

extension CameraService: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        onHardwareControlChange?(.hudFullscreen(true))
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        onHardwareControlChange?(.hudFullscreen(false))
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        onHardwareControlChange?(.hudFullscreen(false))
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let continuation = takePhotoContinuation() else { return }

        if let error = error {
            continuation.resume(throwing: error)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(returning: nil)
            return
        }

        let orientationRaw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw ?? 1) ?? .up
        let preview = photo.previewCGImageRepresentation().flatMap {
            Self.uprightJPEG(from: $0, orientation: orientation)
        }

        continuation.resume(
            returning: CapturedPhoto(
                data: data,
                preview: preview,
                fileExtension: Self.fileExtension(for: data)
            )
        )
    }
}

extension CameraService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        guard let continuation = takeVideoContinuation() else { return }
        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: outputFileURL)
        }
    }
}

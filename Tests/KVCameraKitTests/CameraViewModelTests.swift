import XCTest
import AVFoundation
import UIKit
@testable import KVCameraKit

@MainActor
final class CameraViewModelTests: XCTestCase {

    func test_cameraViewModel_toggles() {
        let camera = StubCamera()
        let handler = StubHandler()
        let viewModel = makeViewModel(camera: camera, handler: handler)

        XCTAssertEqual(viewModel.state.mode, .photo)
        viewModel.send(.setMode(.video))
        XCTAssertEqual(viewModel.state.mode, .video)

        XCTAssertEqual(viewModel.state.flashMode, .auto)
        viewModel.send(.toggleFlash)
        XCTAssertEqual(viewModel.state.flashMode, .on)
        viewModel.send(.toggleFlash)
        XCTAssertEqual(viewModel.state.flashMode, .off)

        XCTAssertFalse(viewModel.state.isGridEnabled)
        viewModel.send(.toggleGrid)
        XCTAssertTrue(viewModel.state.isGridEnabled)

        XCTAssertEqual(viewModel.state.timerDelaySeconds, 0)
        viewModel.send(.toggleTimerMenu)
        XCTAssertTrue(viewModel.state.isTimerMenuOpen)
        viewModel.send(.setTimerDelay(5))
        // Choosing closes the menu in the same update; a local view flag written next to
        // the publish did not survive the re-render.
        XCTAssertFalse(viewModel.state.isTimerMenuOpen)
        XCTAssertEqual(viewModel.state.timerDelaySeconds, 5)
        viewModel.send(.setTimerDelay(10))
        XCTAssertEqual(viewModel.state.timerDelaySeconds, 10)
        // Anything not on the menu is ignored rather than accepted silently.
        viewModel.send(.setTimerDelay(7))
        XCTAssertEqual(viewModel.state.timerDelaySeconds, 10)
        viewModel.send(.setTimerDelay(0))
        XCTAssertEqual(viewModel.state.timerDelaySeconds, 0)

        viewModel.send(.dismiss)
        XCTAssertEqual(dismissCount, 1)
    }

    func test_cameraViewModel_zoom_and_exposure() {
        let camera = StubCamera()
        let handler = StubHandler()
        let viewModel = makeViewModel(camera: camera, handler: handler)

        XCTAssertEqual(viewModel.state.currentZoom, 1.0)
        viewModel.send(.setZoom(0.5, animated: true))
        XCTAssertEqual(viewModel.state.currentZoom, 0.5)

        viewModel.send(.setZoom(2.0, animated: true))
        XCTAssertEqual(viewModel.state.currentZoom, 2.0)

        viewModel.send(.setExposureBias(0.5))
        XCTAssertEqual(viewModel.state.exposureBias, 0.5)

        let testDevicePoint = CGPoint(x: 0.5, y: 0.5)
        let testViewPoint = CGPoint(x: 180, y: 320)
        viewModel.send(.focusAt(devicePoint: testDevicePoint, viewPoint: testViewPoint, locked: false))
        XCTAssertEqual(viewModel.state.focusTapPoint, testViewPoint)
    }

    func test_capturePhoto_handsOneArtifactToTheHost() async throws {
        let camera = StubCamera()
        let handler = StubHandler()
        let viewModel = makeViewModel(camera: camera, handler: handler)

        viewModel.send(.shutterTapped)
        try await waitUntil { handler.stored.count == 1 }

        // What the camera owes its host is exactly this: bytes, a container, and the facts
        // about them. Encryption, filenames and vault items are on the other side of the
        // boundary and are not this test's business any more.
        let batch = handler.stored[0]
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch[0].kind, .photo)
        XCTAssertFalse(batch[0].data.isEmpty)
        XCTAssertEqual(batch[0].fileExtension, "jpg")
        XCTAssertNotNil(batch[0].previewData)
    }

    // MARK: - Capture pipeline

    func test_authorization_startsChecking_andDeniesWhenSetupFails() async throws {
        let camera = StubCamera()
        camera.setupResult = false
        let viewModel = makeViewModel(camera: camera)

        // Not a `Bool`: before the answer arrives the screen must show neither the
        // viewfinder nor the "access required" prompt.
        XCTAssertEqual(viewModel.state.authorization, .checking)

        viewModel.send(.onAppear)
        try await waitUntil { viewModel.state.authorization != .checking }

        XCTAssertEqual(viewModel.state.authorization, .denied)
        XCTAssertFalse(viewModel.state.isAuthorized)
    }

    func test_capturePhoto_movesThroughStages_andFliesBeforeSealingFinishes() async throws {
        let camera = StubCamera()
        let handler = StubHandler()
        let viewModel = makeViewModel(camera: camera, handler: handler)

        viewModel.send(.shutterTapped)

        // The curtain is state, and it is down on the same turn as the tap.
        XCTAssertEqual(viewModel.state.captureStage, .exposing)
        XCTAssertTrue(viewModel.state.isSealing)

        try await waitUntil {
            if case .flying = viewModel.state.captureStage { return true }
            return false
        }

        guard case .flying(let flight) = viewModel.state.captureStage else {
            return XCTFail("expected a flight")
        }
        XCTAssertFalse(flight.imageData.isEmpty)

        // The animation owns its own teardown; nothing else may reset the stage.
        viewModel.send(.captureFlightCompleted)
        XCTAssertEqual(viewModel.state.captureStage, .idle)

        try await waitUntil { !viewModel.state.isSealing }
        XCTAssertEqual(handler.stored.count, 1)
        XCTAssertEqual(handler.stored[0].first?.kind, .photo)
        // The host reported a thumbnail and the corner button took it.
        XCTAssertEqual(viewModel.state.latestCapturedThumbnailData, StubHandler.storedThumbnail)
    }

    func test_capturePhoto_secondTapWhileBusyIsDropped() async throws {
        let camera = StubCamera()
        camera.captureDelayNanoseconds = 200_000_000
        let handler = StubHandler()
        let viewModel = makeViewModel(camera: camera, handler: handler)

        viewModel.send(.shutterTapped)
        viewModel.send(.shutterTapped)
        viewModel.send(.shutterTapped)

        try await waitUntil {
            if case .flying = viewModel.state.captureStage { return true }
            return false
        }
        try await waitUntil { !viewModel.state.isSealing }

        // Two taps used to overwrite the pending capture continuation, which either
        // crashed on a double resume or hung the dropped one forever.
        XCTAssertEqual(camera.captureCount, 1)
        XCTAssertEqual(handler.stored.count, 1)
    }

    func test_capturePhoto_failure_surfacesAnAlertInsteadOfSwallowingIt() async throws {
        let camera = StubCamera()
        camera.captureError = StubCameraError.failed
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.shutterTapped)
        try await waitUntil { viewModel.state.alert != nil }

        XCTAssertEqual(viewModel.state.captureStage, .idle)
        XCTAssertFalse(viewModel.state.isSealing)

        viewModel.send(.dismissAlert)
        XCTAssertNil(viewModel.state.alert)
    }

    func test_flashModeCyclesIntoTheService() {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.toggleFlash)
        XCTAssertEqual(camera.flashMode, .on)
        viewModel.send(.toggleFlash)
        XCTAssertEqual(camera.flashMode, .off)
        viewModel.send(.toggleFlash)
        XCTAssertEqual(camera.flashMode, .auto)
    }

    // MARK: - Hardware capabilities & lifecycle

    func test_zoomLevelsComeFromHardware_andZoomIsClampedToItsRange() async throws {
        let camera = StubCamera()
        camera.zoomLevels = [1.0, 2.0]
        camera.range = 1.0...4.0
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { !viewModel.state.zoomLevels.isEmpty }

        XCTAssertEqual(viewModel.state.zoomLevels, [1.0, 2.0])
        XCTAssertEqual(viewModel.state.zoomRange, 1.0...4.0)

        // A pinch past the hardware limit used to reach the device as 10.0, because the
        // view clamped with its own guess.
        viewModel.send(.setZoom(9.0, animated: false))
        XCTAssertEqual(viewModel.state.currentZoom, 4.0)
        XCTAssertEqual(camera.appliedZoom, 4.0)

        viewModel.send(.setZoom(0.1, animated: false))
        XCTAssertEqual(viewModel.state.currentZoom, 1.0)
    }

    func test_emptyLensListIsPassedThroughToState() async throws {
        let camera = StubCamera()
        camera.zoomLevels = []
        camera.range = 1.0...1.0
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { viewModel.state.authorization == .authorized }

        XCTAssertTrue(viewModel.state.zoomLevels.isEmpty)
    }

    func test_microphoneIsAttachedOnlyForVideo() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { viewModel.state.authorization == .authorized }

        // Photo mode must not hold the microphone: it puts the orange in-use indicator on
        // screen and stops whatever the user was listening to.
        XCTAssertFalse(camera.isAudioEnabled)

        viewModel.send(.setMode(.video))
        try await waitUntil { camera.isAudioEnabled }

        viewModel.send(.setMode(.photo))
        try await waitUntil { !camera.isAudioEnabled }
    }

    func test_sessionInterruptionIsSurfaced_andRecovers() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { viewModel.state.authorization == .authorized }
        XCTAssertFalse(viewModel.state.isSessionInterrupted)

        camera.simulateAvailability(false)
        try await waitUntil { viewModel.state.isSessionInterrupted }

        camera.simulateAvailability(true)
        try await waitUntil { !viewModel.state.isSessionInterrupted }
    }

    func test_backgroundingStopsTheSession_andForegroundingRestartsIt() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { viewModel.state.authorization == .authorized }

        // `onDisappear` never fires on backgrounding, so without this the session kept
        // the camera while the app was off screen.
        viewModel.send(.scenePhaseChanged(isActive: false))
        XCTAssertTrue(camera.didStopSession)

        viewModel.send(.scenePhaseChanged(isActive: true))
        try await waitUntil { viewModel.state.authorization == .authorized }
        XCTAssertFalse(viewModel.state.isSessionInterrupted)
    }

    func test_switchCameraReReadsTheLensList() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { !viewModel.state.zoomLevels.isEmpty }

        camera.zoomLevels = [1.0]
        camera.range = 1.0...1.0
        viewModel.send(.switchCamera)
        try await waitUntil { viewModel.state.zoomLevels == [1.0] }

        XCTAssertEqual(camera.switchCount, 1)
        XCTAssertEqual(viewModel.state.currentZoom, 1.0)
    }

    // MARK: - AE/AF lock

    func test_longPressLocksFocus_andBadgeClearsIt() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        // An ordinary tap keeps subject-area monitoring on, so the camera hands itself
        // back to continuous when the scene changes.
        viewModel.send(.focusAt(devicePoint: .zero, viewPoint: .zero, locked: false))
        XCTAssertEqual(camera.didLockFocus, false)
        XCTAssertFalse(viewModel.state.isFocusLocked)

        viewModel.send(.focusAt(devicePoint: .zero, viewPoint: .zero, locked: true))
        XCTAssertEqual(camera.didLockFocus, true)
        XCTAssertTrue(viewModel.state.isFocusLocked)

        viewModel.send(.setExposureBias(1.5))
        viewModel.send(.clearFocusLock)

        XCTAssertFalse(viewModel.state.isFocusLocked)
        XCTAssertEqual(viewModel.state.exposureBias, 0)
        XCTAssertNil(viewModel.state.focusTapPoint)
        XCTAssertTrue(camera.didResetFocus)
    }

    func test_switchingCameraClearsTheLock_andFlagsTheTransition() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.focusAt(devicePoint: .zero, viewPoint: .zero, locked: true))
        XCTAssertTrue(viewModel.state.isFocusLocked)

        viewModel.send(.switchCamera)
        // Held for the real reconfiguration, which is what the viewfinder blur covers.
        XCTAssertTrue(viewModel.state.isSwitchingCamera)
        XCTAssertFalse(viewModel.state.isFocusLocked)

        try await waitUntil { !viewModel.state.isSwitchingCamera }
        XCTAssertEqual(camera.switchCount, 1)
    }

    func test_switchCameraIgnoresASecondTapWhileSwapping() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.switchCamera)
        viewModel.send(.switchCamera)
        viewModel.send(.switchCamera)

        try await waitUntil { !viewModel.state.isSwitchingCamera }
        XCTAssertEqual(camera.switchCount, 1)
    }

    // MARK: - Camera Control

    func test_hardwareControlsDriveTheOnScreenState() async throws {
        let camera = StubCamera()
        camera.range = 0.5...8.0
        let viewModel = makeViewModel(camera: camera)

        viewModel.send(.onAppear)
        try await waitUntil { viewModel.state.zoomRange != nil }

        // Picking a lens on the button must move the pill too: a hardware zoom the
        // on-screen number disagrees with is worse than no hardware zoom.
        camera.simulateHardwareControl(.lensIndex(2))
        try await waitUntil { viewModel.state.currentZoom == 2.0 }

        // An index the picker could not have produced is ignored, not force-unwrapped.
        camera.simulateHardwareControl(.lensIndex(99))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.state.currentZoom, 2.0)

        camera.simulateHardwareControl(.timerOptionIndex(2))
        try await waitUntil { viewModel.state.timerDelaySeconds == 5 }

        // An index the picker could not have produced is ignored, not force-unwrapped.
        camera.simulateHardwareControl(.timerOptionIndex(99))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.state.timerDelaySeconds, 5)

        camera.simulateHardwareControl(.hudFullscreen(true))
        try await waitUntil { viewModel.state.isHardwareHUDVisible }
        camera.simulateHardwareControl(.hudFullscreen(false))
        try await waitUntil { !viewModel.state.isHardwareHUDVisible }
    }

    func test_hardwareControlLabelsArePassedToTheSession() async throws {
        let camera = StubCamera()
        let viewModel = makeViewModel(camera: camera)

        let labels = CameraControlLabels(
            zoom: "Zoom",
            lensOptions: CameraControlLabels.lensOptionTitles(
                for: [0.5, 1.0, 2.0],
                locale: Locale(identifier: "vi_VN")
            ),
            exposure: "Exposure",
            timer: "Timer",
            timerOptions: ["Off", "3s", "5s", "10s"]
        )
        viewModel.send(.installHardwareControls(labels))
        try await waitUntil { camera.installedLabels != nil }

        XCTAssertEqual(camera.installedLabels?.timerOptions.count, CameraState.timerDelayOptions.count)
        // Formatted for the chosen locale, not the device's: a comma where Vietnamese
        // wants one. This is why the titles are not built with `.formatted()`.
        XCTAssertEqual(camera.installedLabels?.lensOptions, ["0,5×", "1×", "2×"])
    }

    // MARK: - Helpers

    private var dismissCount = 0

    private func makeViewModel(
        camera: StubCamera,
        handler: StubHandler = StubHandler()
    ) -> CameraViewModel {
        CameraViewModel(
            handler: handler,
            onDismiss: { [weak self] in self?.dismissCount += 1 },
            cameraService: camera
        )
    }

    /// Polls instead of sleeping a fixed amount: the pipeline now spans a real actor hop
    /// plus an off-main encrypt, and a single `sleep` either flakes or wastes a second.
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}

private enum StubCameraError: Error {
    case failed
}

/// A host that stores nothing.
///
/// This is what the package boundary bought: the camera's tests no longer stand up a
/// vault — a directory manager, a crypto engine, a keychain, a metadata store and a real
/// PIN setup — to assert that tapping the shutter produces one photo.
private final class StubHandler: CameraArtifactHandler, @unchecked Sendable {
    static let displayThumbnail = Data("display".utf8)
    static let storedThumbnail = Data("stored".utf8)

    private(set) var stored: [[CaptureArtifact]] = []
    var latest: Data?

    func displayThumbnail(for artifacts: [CaptureArtifact]) async -> Data? {
        Self.displayThumbnail
    }

    func store(_ artifacts: [CaptureArtifact]) async throws -> CaptureReceipt {
        stored.append(artifacts)
        return CaptureReceipt(thumbnailData: Self.storedThumbnail)
    }

    func latestThumbnail() async -> Data? { latest }
}

/// A camera that needs no device.
///
/// This is what `CameraCapturing` exists for: the capture pipeline is a stage machine
/// with an off-main tail, and none of it was assertable while the ViewModel held the
/// concrete AVFoundation class.
private final class StubCamera: CameraCapturing, @unchecked Sendable {
    let session = AVCaptureSession()
    var flashMode: CameraFlashMode = .auto
    var isUsingFrontCamera = false
    var onAvailabilityChange: (@Sendable (Bool) -> Void)?
    var onHardwareControlChange: (@Sendable (CameraHardwareControlChange) -> Void)?

    var setupResult = true
    var captureError: Error?
    var captureDelayNanoseconds: UInt64 = 0
    var zoomLevels: [CGFloat] = [0.5, 1.0, 2.0]
    var range: ClosedRange<CGFloat> = 0.5...8.0
    private(set) var captureCount = 0
    private(set) var didStopSession = false
    private(set) var isAudioEnabled = false
    private(set) var switchCount = 0
    private(set) var appliedZoom: CGFloat?
    private(set) var didLockFocus: Bool?
    private(set) var didResetFocus = false
    private(set) var installedLabels: CameraControlLabels?

    /// Frames are not what this stub exists to exercise — the fan-out has its own tests —
    /// but the protocol requires one, and handing back a real source keeps `StubCamera`
    /// honest about the shape of the thing it stands in for.
    let frames: any FrameSource = StubFrameSource()

    func setupSession() async -> Bool { setupResult }
    func stopSession() { didStopSession = true }
    func switchCamera() async {
        switchCount += 1
        isUsingFrontCamera.toggle()
    }
    func setAudioEnabled(_ enabled: Bool) async { isAudioEnabled = enabled }
    func availableZoomLevels() -> [CGFloat] { zoomLevels }
    func zoomRange() -> ClosedRange<CGFloat> { range }
    func setZoom(factor: CGFloat, animated: Bool) { appliedZoom = factor }
    func focus(at pointOfInterest: CGPoint, locked: Bool) { didLockFocus = locked }
    func resetFocusAndExposure() { didResetFocus = true }
    func setExposureBias(_ bias: Float) {}
    func setTorch(on: Bool) {}
    func startRecording(to outputURL: URL) {}
    func stopRecording() async throws -> URL? { nil }
    @MainActor func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {}
    func installHardwareControls(labels: CameraControlLabels) async { installedLabels = labels }

    /// Drives the same callback AVFoundation's interruption notifications drive.
    func simulateAvailability(_ isAvailable: Bool) {
        onAvailabilityChange?(isAvailable)
    }

    /// Drives the same callback Camera Control drives on an iPhone 16 and later.
    func simulateHardwareControl(_ change: CameraHardwareControlChange) {
        onHardwareControlChange?(change)
    }

    func capturePhoto() async throws -> CapturedPhoto? {
        captureCount += 1
        if captureDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: captureDelayNanoseconds)
        }
        if let captureError = captureError {
            throw captureError
        }
        let data = Self.jpeg(side: 240)
        return CapturedPhoto(data: data, preview: Self.jpeg(side: 120), fileExtension: "jpg")
    }

    private static func jpeg(side: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}

/// A frame source that never produces a frame.
///
/// The camera screen does not read frames yet, so the correct stand-in here is one that stays
/// silent: a stub that invented a stream would make every ViewModel test pay for a timer.
private final class StubFrameSource: FrameSource, @unchecked Sendable {
    var statistics = FrameStatistics()

    func addConsumer(_ consumer: @escaping FrameConsumer) -> FrameSubscription {
        FrameSubscription {}
    }
}

import AVFoundation
import CoreGraphics
import Foundation

/// Flash behaviour, as the user cycles it in the top bar.
///
/// Top level rather than nested in `CameraService` so `CameraState` can hold it
/// without the state type naming the AVFoundation-facing class.
enum CameraFlashMode: Equatable, Sendable {
    case auto
    case on
    case off
}

/// One frame, as it comes back from the sensor.
///
/// `preview` is the small representation AVFoundation delivers alongside the full
/// frame. It exists so the capture animation can fly a **sharp** image the moment
/// the shutter closes: the 12 MP frame still has a few hundred milliseconds of
/// AES-GCM ahead of it, and the flight has to be over before that finishes.
///
/// `fileExtension` is sniffed from the bytes rather than assumed. Capturing HEVC
/// yields an HEIC container, and the old code wrote it to disk named `.jpg`.
struct CapturedPhoto: Sendable {
    let data: Data
    let preview: Data?
    let fileExtension: String
}

/// Something the user did with Camera Control — the capacitive button below the side
/// button on an iPhone 16 and later.
///
/// It is reported back rather than applied silently, because the on-screen pill has to
/// agree with the hardware: sliding the button to 2,4× and finding the pill still saying
/// `1×` is worse than not supporting the button at all.
enum CameraHardwareControlChange: Sendable {
    /// An index into the lens list, matching the on-screen pill.
    case lensIndex(Int)
    case exposureBias(Float)
    case timerOptionIndex(Int)
    /// The system HUD took over the screen. Apple's guidance is to get the app's own
    /// controls out of the way while it is up.
    case hudFullscreen(Bool)
}

/// Titles for the Camera Control HUD, already resolved to strings.
///
/// AVFoundation wants `String`, and the HUD is drawn by the system, so this cannot stay a
/// `LocalizedStringResource` for a view to resolve later. They come through
/// `LanguageStore.localized` — the app's existing bridge — and not `String(localized:)`,
/// which reads the *device* language and would disagree with the language chosen in the
/// app.
struct CameraControlLabels: Sendable {
    let zoom: String
    /// The lens factors as text — `0,5` · `1` · `2` · `3` · `5`. Built with an explicit
    /// locale rather than `.formatted()`, which reads the device locale and would print a
    /// point where the chosen language wants a comma.
    let lensOptions: [String]
    let exposure: String
    let timer: String
    let timerOptions: [String]

    /// Formats lens factors for the HUD.
    static func lensOptionTitles(for levels: [CGFloat], locale: Locale) -> [String] {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return levels.map { level in
            let number = formatter.string(from: NSNumber(value: Double(level))) ?? "\(level)"
            return number + "×"
        }
    }
}

/// What the camera screen needs from the hardware.
///
/// A protocol rather than the concrete `CameraService` for one reason: the
/// ViewModel owns a capture *pipeline* — a stage machine, off-main sealing,
/// an error surface — and none of that is assertable if the only implementation
/// needs a device. `CameraService` talks to AVFoundation; a test hands back
/// fixtures.
///
/// `session` is the one leak: an `AVCaptureVideoPreviewLayer` needs the session
/// object itself, and no value type stands in for a live viewfinder.
protocol CameraCapturing: AnyObject, Sendable {
    var session: AVCaptureSession { get }
    var flashMode: CameraFlashMode { get set }

    /// Fires with `false` when the session stops delivering frames — a phone call,
    /// another app taking the camera, Split View — and `true` when it resumes. Without
    /// it the viewfinder simply freezes black and nothing on screen says why.
    var onAvailabilityChange: (@Sendable (Bool) -> Void)? { get set }

    /// Camera Control events. Never fires on a device without the button.
    var onHardwareControlChange: (@Sendable (CameraHardwareControlChange) -> Void)? { get set }

    func setupSession() async -> Bool
    func stopSession()
    /// Awaitable because the lens list changes with the camera, and the screen has to
    /// re-read it once the swap has actually happened.
    func switchCamera() async

    /// Audio is attached only for video.
    ///
    /// Adding the microphone at setup put the orange in-use indicator on screen and
    /// switched the audio session to `.playAndRecord`, which stops whatever the user was
    /// listening to — both on a screen that may only ever take a photo.
    func setAudioEnabled(_ enabled: Bool) async

    /// The lenses this camera actually has, as the factors the user sees — 1.0 is the
    /// wide lens.
    ///
    /// Not a hard-coded `[0.5, 1, 2, 3]`. `videoZoomFactor` is relative to the *widest*
    /// constituent of a virtual device, so on a triple camera 1.0 is the ultra wide and
    /// the wide sits at a switch-over factor; the UI number and the device number are
    /// different, and the mapping differs per device. An iPhone SE has one lens and gets
    /// an empty list — offering `0,5` there meant a button that clamped back to 1x and
    /// lied about it.
    func availableZoomLevels() -> [CGFloat]
    /// The UI-factor range pinch may cover.
    func zoomRange() -> ClosedRange<CGFloat>

    func setZoom(factor: CGFloat, animated: Bool)

    /// One-shot focus and exposure at a point.
    ///
    /// `locked` is the whole difference between a tap and a long press, and it is the
    /// same distinction AVCam draws: with subject-area monitoring on, the camera hands
    /// itself back to continuous tracking when the scene changes; with it off, the
    /// one-shot result simply stays, which is what "AE/AF LOCK" means.
    func focus(at pointOfInterest: CGPoint, locked: Bool)
    /// Back to continuous focus and exposure at the centre.
    func resetFocusAndExposure()
    func setExposureBias(_ bias: Float)
    func setTorch(on: Bool)
    func capturePhoto() async throws -> CapturedPhoto?
    func startRecording(to outputURL: URL)
    func stopRecording() async throws -> URL?

    /// Handed the live preview layer so rotation can be driven from one
    /// `RotationCoordinator` instead of a hard-coded `.portrait` on every connection.
    ///
    /// `@MainActor` because the argument is a layer a `UIView` owns, and the only caller is
    /// `makeUIView`. Spelling it out is what lets the rotation controller be main-actor
    /// too — the alternative was hopping a `CALayer` across isolation domains, which Swift 6
    /// correctly refuses.
    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer)

    /// Publishes zoom, exposure and the self-timer to Camera Control. A no-op where the
    /// hardware has no such button.
    func installHardwareControls(labels: CameraControlLabels) async

    /// Frames off the sensor, for whoever needs pixels rather than a viewfinder.
    ///
    /// Alongside `session`, not instead of it: the preview layer keeps drawing exactly as
    /// before, and nothing reads this until a scanner, a Metal preview, a recorder or a
    /// filter does. Nothing is attached to the session until the first consumer subscribes.
    var frames: any FrameSource { get }
}

import AVFoundation
import CoreGraphics

/// Keeps the viewfinder and what gets written to disk both level.
///
/// One coordinator drives both. Every connection used to be pinned to `.portrait`, so a
/// landscape photo came out rotated. `RotationCoordinator` reports the angle that keeps the
/// horizon level and publishes it through KVO, which is also how the preview follows the
/// device without the app watching `UIDevice.orientation` itself.
///
/// A separate type because it owns KVO observations with a lifetime — the single most
/// common way this kind of code leaks is an observation that outlives the thing it points
/// at, and here `deinit` is one line next to the array it invalidates.
@MainActor
final class CameraRotationController {

    /// Owned by the view. Held weakly so the layer's own lifetime decides when it goes.
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []

    /// Where the capture angle goes. The outputs live on the session queue, so applying it
    /// is the service's business rather than this type reaching for them.
    private let applyCaptureAngle: @Sendable (CGFloat) -> Void

    /// `nonisolated` so the service can build it in its own synchronous `init`. Safe
    /// because this stores one `@Sendable` closure and leaves every main-actor property at
    /// its empty default — nothing observable exists yet to be touched off the main actor.
    nonisolated init(applyCaptureAngle: @escaping @Sendable (CGFloat) -> Void) {
        self.applyCaptureAngle = applyCaptureAngle
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
    }

    /// Re-points the coordinator at whichever camera is now active.
    ///
    /// Called after setup and after every switch: the coordinator is bound to one device,
    /// so a stale one reports the front camera's angles for the back camera.
    func refresh(for device: AVCaptureDevice?) {
        observations.forEach { $0.invalidate() }
        observations = []

        guard let device = device else {
            coordinator = nil
            return
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator

        observations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor [weak self] in
                    self?.applyPreviewAngle(angle)
                }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                self?.applyCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
            }
        ]
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

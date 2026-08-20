import AVFoundation
import Foundation

/// Everything about taking one still: the output, its settings, and the delegate callback
/// that turns a frame into `CapturedPhoto`.
///
/// Split out of `CameraService` because it is the only part that owns a delegate
/// conformance and a pending continuation, which is where the concurrency care has to
/// live. Nothing else in the camera needs to know that a capture is one round trip
/// through a queue AVFoundation owns.
final class PhotoCaptureCoordinator: NSObject, @unchecked Sendable {

    let output = AVCapturePhotoOutput()

    private let slot = ContinuationSlot<CapturedPhoto?>()

    /// Must run inside `beginConfiguration()`.
    ///
    /// `maxPhotoQualityPrioritization` is the ceiling, not the setting — the old code
    /// read it and assigned it back to itself, which did nothing. The per-shot value in
    /// `makeSettings` stays `.balanced`, which is what Camera.app uses: `.quality`
    /// on every frame adds shutter latency the animation then has to hide.
    ///
    /// And the ceiling is `.balanced` too, matching it. Raising the ceiling is not free: the
    /// output allocates for the level it is told it may be asked for, so a ceiling of
    /// `.quality` bought a deeper pipeline and a slower first capture in exchange for a
    /// quality level no shot here ever requests. It was set to `.quality` while fixing the
    /// no-op above, which is how a ceiling ends up disagreeing with every actual use of it.
    ///
    /// Zero-shutter-lag and responsive capture are the reason a modern iPhone returns a
    /// frame in tens of milliseconds instead of hundreds, and they are the cheapest
    /// possible win for how immediate the capture feels. They must be enabled in this
    /// order: zero shutter lag, then responsive capture, then fast prioritization.
    func configureOutput() {
        output.maxPhotoQualityPrioritization = .balanced

        if output.isZeroShutterLagSupported {
            output.isZeroShutterLagEnabled = true
        }
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = true
        }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = true
        }
    }

    /// Fires the shutter, or returns `nil` when a frame is already in the pipeline.
    ///
    /// `queue` is the session queue: the settings are read off the output, so building
    /// them anywhere else is a race with reconfiguration.
    func capture(flashMode: CameraFlashMode, on queue: DispatchQueue) async throws -> CapturedPhoto? {
        // The continuation type is spelled out. Left to inference it resolves to
        // `CapturedPhoto` rather than `CapturedPhoto?`, because `return` may promote a
        // non-optional to the optional return type — and then `resume(returning: nil)`
        // no longer compiles. It only surfaces on a device build, since the simulator
        // never reaches here.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedPhoto?, Error>) in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                // A second tap while the first frame is still in the pipeline is dropped
                // here rather than overwriting the pending continuation.
                guard self.slot.install(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }

                self.output.capturePhoto(with: self.makeSettings(flashMode: flashMode), delegate: self)
            }
        }
    }

    /// Extracted from the capture closure on purpose.
    ///
    /// Built inline, this ran to a dozen statements inside a `DispatchQueue.async`
    /// closure that also had to infer a continuation type, and the compiler reported the
    /// whole closure as "cannot convert value of type '_' to DispatchWorkItem" rather
    /// than naming the line at fault.
    private func makeSettings(flashMode: CameraFlashMode) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.hevc) {
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

        let supported = output.supportedFlashModes
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
}

extension PhotoCaptureCoordinator: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let continuation = slot.take() else { return }

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
            CapturedPhotoDecoder.uprightJPEG(from: $0, orientation: orientation)
        }

        continuation.resume(
            returning: CapturedPhoto(
                data: data,
                preview: preview,
                fileExtension: CapturedPhotoDecoder.fileExtension(for: data)
            )
        )
    }
}

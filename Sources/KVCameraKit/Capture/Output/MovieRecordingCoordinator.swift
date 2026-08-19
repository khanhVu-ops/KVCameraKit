import AVFoundation
import Foundation

/// Everything about recording one clip to a file.
///
/// The mirror of `PhotoCaptureCoordinator`: an output, a delegate conformance and one
/// pending continuation. `AVCaptureMovieFileOutput` is deliberately still the mechanism —
/// swapping it for `AVAssetWriter` is a later step, and this is the seam that makes it one
/// file rather than a rewrite of the service.
final class MovieRecordingCoordinator: NSObject, @unchecked Sendable {

    let output = AVCaptureMovieFileOutput()

    private let slot = ContinuationSlot<URL?>()

    var isRecording: Bool { output.isRecording }

    func start(to outputURL: URL, on queue: DispatchQueue) {
        queue.async { [weak self] in
            guard let self = self, !self.output.isRecording else { return }
            try? FileManager.default.removeItem(at: outputURL)
            self.output.startRecording(to: outputURL, recordingDelegate: self)
        }
    }

    /// The finished file, or `nil` when nothing was recording.
    func stop(on queue: DispatchQueue) async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            queue.async { [weak self] in
                guard let self = self, self.output.isRecording else {
                    continuation.resume(returning: nil)
                    return
                }
                guard self.slot.install(continuation) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.output.stopRecording()
            }
        }
    }
}

extension MovieRecordingCoordinator: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        guard let continuation = slot.take() else { return }
        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: outputFileURL)
        }
    }
}

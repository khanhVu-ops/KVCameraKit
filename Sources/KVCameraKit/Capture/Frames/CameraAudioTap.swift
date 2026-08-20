import AVFoundation
import Foundation

/// Microphone sample buffers, for whoever is writing a file.
///
/// `AVCaptureMovieFileOutput` never needed this: the audio input on the session went straight
/// into it. `AVAssetWriter` appends what it is given, so the samples have to be delivered —
/// which is the whole difference between AVFoundation recording for you and you recording.
///
/// Deliberately thinner than `CameraFrameTap`: one consumer, not a fan-out. Two things
/// reading the same audio stream would each have to decide what to do about the other's
/// timing, and nothing here needs that.
final class CameraAudioTap: NSObject, @unchecked Sendable {

    let output = AVCaptureAudioDataOutput()

    /// Its own serial queue, separate from the video one. Audio arrives in far smaller, far
    /// more frequent buffers, and putting it behind a queue that is also doing per-frame
    /// texture work is how the audio track ends up with gaps.
    private let audioQueue = DispatchQueue(label: "com.iosvault.camera.audioQueue")

    private let lock = NSLock()
    private var consumer: (@Sendable (CMSampleBuffer) -> Void)?

    override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: audioQueue)
    }

    /// The same "valid only inside the callback" contract as `CameraFrame`, for the same
    /// reason: these buffers come from a pool.
    func setConsumer(_ consumer: (@Sendable (CMSampleBuffer) -> Void)?) {
        lock.lock()
        self.consumer = consumer
        lock.unlock()
    }
}

extension CameraAudioTap: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let consumer = self.consumer
        lock.unlock()
        consumer?(sampleBuffer)
    }
}

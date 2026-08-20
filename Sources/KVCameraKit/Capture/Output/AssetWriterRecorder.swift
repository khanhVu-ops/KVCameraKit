import AVFoundation
import CoreMedia
import Foundation

/// Writes a video file by appending samples, instead of letting AVFoundation do it.
///
/// The point is what it makes possible rather than what it does better. With
/// `AVCaptureMovieFileOutput` the app never sees the bytes: it cannot record filtered frames,
/// and it cannot encrypt as it writes — it can only wait for a finished plaintext file and
/// re-read it. Appending samples ourselves is the precondition for both.
///
/// Every guard in here is against a specific way a real-time writer produces a file that is
/// empty, truncated or a second short, all of which look like success at the call site.
final class AssetWriterRecorder: @unchecked Sendable {

    /// One serial queue owns the writer.
    ///
    /// `AVAssetWriterInput.append` is not safe to call concurrently, and video and audio
    /// arrive on two different queues by design. Funnelling both through here is what makes
    /// "is the writer ready, has the session started" a question with one answer rather than
    /// a race between two callbacks.
    private let writerQueue = DispatchQueue(label: "com.iosvault.camera.assetWriterQueue")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    /// `startSession(atSourceTime:)` has been called.
    ///
    /// It cannot be called until the first sample arrives, because the source time has to be
    /// a real presentation timestamp: guess it and every sample is either rejected as being
    /// before the session start or lands after a gap the player shows as a frozen opening
    /// frame.
    private var hasStartedSession = false

    /// Audio that arrived before the first video frame is discarded.
    ///
    /// A microphone warms up faster than a camera, so the first buffers are reliably audio.
    /// Starting the session on them means the file opens with audio over no picture, and
    /// every player shows black for that gap.
    private var isRecording = false

    private(set) var outputURL: URL?

    // MARK: - Lifecycle

    /// Whether an audio track should be created at all.
    ///
    /// Not a preference — a fact about the session. An `AVAssetWriterInput` cannot be added
    /// after `startWriting`, so the audio input has to be created before any audio has
    /// arrived; and creating one that then receives nothing leaves a track with no samples,
    /// which is a file some players open and others refuse. A simulator has no microphone
    /// output on its session at all, so it says so and gets a video-only file that is
    /// genuinely playable.
    private var includesAudio = true

    /// Prepares the writer. The session itself starts on the first video sample.
    func start(to url: URL, transform: CGAffineTransform, includesAudio: Bool = true) {
        writerQueue.sync {
            try? FileManager.default.removeItem(at: url)

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            self.writer = writer
            self.outputURL = url
            self.transform = transform
            self.includesAudio = includesAudio
            self.hasStartedSession = false
            self.isRecording = true
        }
    }

    /// The rotation to bake into the track, from the same coordinator that drives the preview.
    ///
    /// A *transform* rather than rotated pixels: rotating every frame on the way in costs a
    /// full-frame copy 30 times a second to achieve what one matrix in the container header
    /// does for free. Players and editors honour it.
    private var transform: CGAffineTransform = .identity

    /// Finishes the file and returns it, or `nil` if nothing was ever written.
    ///
    /// The `nil` matters: a stop with no samples produces a valid `AVAssetWriter` that has
    /// written a file with no tracks, and handing that to the vault stores an unplayable
    /// artifact that looks exactly like a successful recording.
    func stop() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.isRecording = false

                guard let writer = self.writer, self.hasStartedSession else {
                    // Never started: tear down and say so rather than finishing an empty file.
                    self.reset()
                    continuation.resume(returning: nil)
                    return
                }

                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()

                writer.finishWriting {
                    let url = writer.status == .completed ? self.outputURL : nil
                    self.writerQueue.async {
                        self.reset()
                        continuation.resume(returning: url)
                    }
                }
            }
        }
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        hasStartedSession = false
        outputURL = nil
    }

    // MARK: - Sample intake

    /// Called on the frame queue.
    func appendVideo(_ frame: CameraFrame) {
        let sampleBuffer = frame.sampleBuffer
        writerQueue.async { [weak self] in
            self?.handleVideo(sampleBuffer)
        }
    }

    /// Called on the audio queue.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            self?.handleAudio(sampleBuffer)
        }
    }

    /// Writer queue only.
    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, let writer else { return }

        if videoInput == nil {
            // Built from the first buffer's own format, not from a guess. Hard-coding
            // dimensions means every device that does not match gets a stretched file, and
            // the session preset can change them at runtime.
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            videoInput = makeVideoInput(width: Int(dimensions.width), height: Int(dimensions.height))
            if let videoInput, writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
        }

        guard let videoInput else { return }

        if !hasStartedSession {
            guard writer.status == .unknown else { return }
            // Audio input is added *before* `startWriting`, because inputs cannot be added
            // afterwards — so it is created here even though the first audio sample may not
            // have arrived yet.
            if includesAudio, audioInput == nil {
                let input = makeAudioInput()
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasStartedSession = true
        }

        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    /// Writer queue only.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        // Before the first video frame there is no session, and appending would either fail
        // or open the file with audio over black.
        guard isRecording, hasStartedSession,
              let writer, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    // MARK: - Inputs

    private func makeVideoInput(width: Int, height: Int) -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // ~6 Mbps at 1080p: a visible step above what the default picks, and well
                // under what makes a vault entry inconveniently large.
                AVVideoAverageBitRateKey: Self.bitRate(width: width, height: height),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // Without this the writer assumes it can take its time, and a real-time source
        // overruns it — the symptom is a file that plays fast, having silently dropped
        // everything the writer was not ready for.
        input.expectsMediaDataInRealTime = true
        input.transform = transform
        return input
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 96_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Roughly 6 Mbps at 1080p, scaled by pixel count.
    ///
    /// Static and pure so the number is inspectable: a bitrate chosen per resolution is the
    /// difference between a 4K clip that is 40 MB and one that is 400 MB, and neither is
    /// obvious from looking at the recorder.
    static func bitRate(width: Int, height: Int) -> Int {
        let pixels = max(width * height, 1)
        let referencePixels = 1920 * 1080
        let referenceBitRate = 6_000_000.0
        let scaled = referenceBitRate * Double(pixels) / Double(referencePixels)
        // Floored so a tiny preview-sized capture still gets a usable rate, and capped so a
        // 4K source does not ask for something the encoder will refuse.
        return Int(min(max(scaled, 1_000_000), 40_000_000))
    }
}

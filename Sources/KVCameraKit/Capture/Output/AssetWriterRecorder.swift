import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// Writes a video by appending samples, instead of letting AVFoundation do it.
///
/// The point is what it makes possible rather than what it does better. With
/// `AVCaptureMovieFileOutput` the app never sees the bytes: it cannot record filtered frames,
/// and it cannot encrypt as it writes — it can only wait for a finished plaintext file and
/// re-read it. Appending samples ourselves is the precondition for both.
///
/// It writes to one of two destinations, and the second is the reason the first exists:
///
/// - `.file` — a `.mov`, finished on disk. AVFoundation rewrites the header at the end, which
///   is exactly why this cannot be streamed.
/// - `.stream` — a **fragmented MP4**, handed over segment by segment as the encoder produces
///   them. An initialization segment then self-contained media segments, so concatenating
///   what arrives *is* the file. Nothing is ever written to disk here, which for a host that
///   encrypts means no plaintext ever exists outside memory.
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

    /// Where the bytes go. Held rather than passed, because the answer is needed on the
    /// delegate callback as well as at stop.
    private enum Destination {
        case file(URL)
        /// Called in delivery order, on AVFoundation's queue. Must not block.
        case stream(@Sendable (Data) -> Void)
    }

    private var destination: Destination = .file(URL(fileURLWithPath: "/dev/null"))

    /// Retained because `AVAssetWriter.delegate` is weak, and a deallocated delegate is
    /// simply a recording that produces no segments — with nothing logged.
    private var segmentDelegate: SegmentDelegate?

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

    /// Prepares a writer that finishes a file. The session itself starts on the first video
    /// sample.
    func start(to url: URL, rotationDegrees: CGFloat, includesAudio: Bool = true) {
        writerQueue.sync {
            try? FileManager.default.removeItem(at: url)

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            self.begin(with: writer, destination: .file(url), rotationDegrees: rotationDegrees, includesAudio: includesAudio)
            self.outputURL = url
        }
    }

    /// Prepares a writer that emits fragmented-MP4 segments instead of a file.
    ///
    /// `onSegment` receives the initialization segment first and each media segment after it,
    /// in order. Concatenated, they are the recording.
    func startStreaming(
        rotationDegrees: CGFloat,
        includesAudio: Bool,
        onSegment: @escaping @Sendable (Data) -> Void
    ) {
        writerQueue.sync {
            let delegate = SegmentDelegate(onSegment: onSegment)

            let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
            // Segment output only happens with a profile that defines what a segment is.
            // `.mpeg4AppleHLS` is the one that permits audio and video in the same segment —
            // measured, because the CMAF profile's one-track-per-file rule would split a
            // recording in two and leave the sound to be re-muxed later.
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            // Two seconds. This is the unit of *everything* about streaming: how much is held
            // in memory at once, how much is lost if the app dies mid-recording, and how
            // often the encoder is forced to emit a keyframe. Shorter costs bitrate for
            // keyframes nobody asked for; longer holds more plaintext in memory for longer.
            writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
            writer.delegate = delegate

            self.segmentDelegate = delegate
            self.begin(with: writer, destination: .stream(onSegment), rotationDegrees: rotationDegrees, includesAudio: includesAudio)
            self.outputURL = nil
        }
    }

    /// Writer queue only. The half both destinations share.
    private func begin(
        with writer: AVAssetWriter,
        destination: Destination,
        rotationDegrees: CGFloat,
        includesAudio: Bool
    ) {
        self.writer = writer
        self.destination = destination
        self.rotationDegrees = rotationDegrees
        // y-down, because a video track's transform is in the image's own space.
        self.transform = CaptureRotation.trackTransform(degrees: rotationDegrees)
        self.includesAudio = includesAudio
        self.hasStartedSession = false
        self.isRecording = true
        self.videoInput = nil
        self.audioInput = nil
        self.firstVideoTime = nil
        self.lastVideoEndTime = nil
        self.videoDimensions = nil
        self.posterData = nil
    }

    /// The rotation to bake into the track, from the same coordinator that drives the preview.
    ///
    /// A *transform* rather than rotated pixels: rotating every frame on the way in costs a
    /// full-frame copy 30 times a second to achieve what one matrix in the container header
    /// does for free. Players and editors honour it.
    private var transform: CGAffineTransform = .identity
    /// The same rotation as a number, kept because the poster needs it in a coordinate space
    /// where the matrix above means the opposite thing — see `CaptureRotation`.
    private var rotationDegrees: CGFloat = 0

    /// Facts about the recording that only the recorder is in a position to know, gathered as
    /// the samples go past. Writer queue only.
    private var firstVideoTime: CMTime?
    private var lastVideoEndTime: CMTime?
    private var videoDimensions: CMVideoDimensions?
    private var posterData: Data?

    /// Finishes the recording, or returns `nil` if nothing was ever written.
    ///
    /// The `nil` matters: a stop with no samples produces a valid `AVAssetWriter` that has
    /// written a file with no tracks, and handing that to the vault stores an unplayable
    /// artifact that looks exactly like a successful recording.
    func stop() async -> RecordingOutput? {
        await withCheckedContinuation { (continuation: CheckedContinuation<RecordingOutput?, Never>) in
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
                    self.writerQueue.async {
                        let output = writer.status == .completed ? self.finishedOutput() : nil
                        self.reset()
                        continuation.resume(returning: output)
                    }
                }
            }
        }
    }

    /// Writer queue only.
    private func finishedOutput() -> RecordingOutput? {
        switch destination {
        case .file:
            guard let url = outputURL else { return nil }
            return .file(url)

        case .stream:
            return .stream(CaptureVideoSummary(
                fileExtension: "mp4",
                byteCount: segmentDelegate?.byteCount ?? 0,
                duration: recordedDuration(),
                pixelWidth: orientedDimensions()?.width,
                pixelHeight: orientedDimensions()?.height,
                posterData: posterData
            ))
        }
    }

    /// Measured from the samples' own timestamps rather than from a wall clock, which
    /// includes however long the writer was being set up.
    private func recordedDuration() -> TimeInterval? {
        guard let start = firstVideoTime, let end = lastVideoEndTime else { return nil }
        let seconds = (end - start).seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// The track is rotated by a transform, so its stored dimensions are pre-rotation: a
    /// portrait recording reports landscape until the transform is applied.
    private func orientedDimensions() -> (width: Int, height: Int)? {
        guard let dimensions = videoDimensions else { return nil }
        let oriented = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            .applying(transform)
        return (Int(abs(oriented.width.rounded())), Int(abs(oriented.height.rounded())))
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        segmentDelegate = nil
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
            videoDimensions = dimensions
            videoInput = makeVideoInput(width: Int(dimensions.width), height: Int(dimensions.height))
            if let videoInput, writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
        }

        guard let videoInput else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

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
            // Also before `startWriting`, and only meaningful when segmenting: the writer
            // stamps segment boundaries relative to this, and a value that disagrees with the
            // session start puts the first media segment before the file begins.
            if case .stream = destination {
                writer.initialSegmentStartTime = presentationTime
            }
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
            firstVideoTime = presentationTime

            // The poster comes from the first frame that actually made it into the file.
            // Rendered off writerQueue so JPEG encoding never delays the first video frame.
            let angle = rotationDegrees
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let poster = CapturePosterRenderer.jpeg(from: sampleBuffer, rotationAngle: angle)
                self?.writerQueue.async {
                    self?.posterData = poster
                }
            }
        }

        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)

        // Duration is the end of the last frame, not its start — otherwise every recording
        // is one frame short, which is invisible until someone compares it to the timer.
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
        lastVideoEndTime = sampleDuration.isValid && sampleDuration.isNumeric
            ? presentationTime + sampleDuration
            : presentationTime
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

    // MARK: - Segments

    /// Forwards each segment and counts the bytes.
    ///
    /// A separate object rather than a conformance on the recorder, for two reasons: the
    /// callback arrives on AVFoundation's own queue rather than the writer queue, so keeping
    /// it here keeps that boundary visible, and it saves making the recorder an `NSObject`
    /// only to satisfy a delegate protocol.
    private final class SegmentDelegate: NSObject, AVAssetWriterDelegate {
        private let onSegment: @Sendable (Data) -> Void
        private let lock = NSLock()
        /// `nonisolated(unsafe)` because `AVAssetWriterDelegate` is `Sendable`, so the
        /// compiler wants this immutable — and it cannot see that the lock below is what
        /// makes it safe. The alternative, an actor, cannot conform: the delegate callback is
        /// synchronous.
        nonisolated(unsafe) private var bytes = 0

        init(onSegment: @escaping @Sendable (Data) -> Void) {
            self.onSegment = onSegment
        }

        /// Read from the writer queue at stop, written on AVFoundation's queue — hence the
        /// lock rather than the queue this class does not own.
        var byteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }

        func assetWriter(
            _ writer: AVAssetWriter,
            didOutputSegmentData segmentData: Data,
            segmentType: AVAssetSegmentType,
            segmentReport: AVAssetSegmentReport?
        ) {
            lock.lock()
            bytes += segmentData.count
            lock.unlock()
            onSegment(segmentData)
        }
    }
}

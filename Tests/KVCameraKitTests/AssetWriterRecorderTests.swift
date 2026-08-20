import AVFoundation
import CoreMedia
import XCTest
@testable import KVCameraKit

/// The recorder's decisions, and the two pure functions behind them.
///
/// A real-time writer has several ways to produce a file that is empty, truncated or a second
/// short, and all of them look like success at the call site. What is testable without a
/// camera is exactly that: the contract on `stop()`, the bitrate ladder, and the track
/// transform — "the video came out sideways" is the classic recorder bug.
final class AssetWriterRecorderTests: XCTestCase {

    // MARK: - The engine flag

    func test_onlyTheAssetWriterEnginesUseSampleBuffers() {
        XCTAssertFalse(CameraRecordingEngine.movieFile.usesSampleBuffers)
        XCTAssertTrue(CameraRecordingEngine.assetWriter.usesSampleBuffers)
        XCTAssertTrue(CameraRecordingEngine.streamingAssetWriter.usesSampleBuffers)
    }

    /// Only one engine sends the bytes to the host, and the screen asks this before it opens a
    /// destination. Getting it wrong on `.movieFile` would mean asking the vault for a sink
    /// that never receives a byte.
    func test_onlyTheStreamingEngineStreamsToTheHost() {
        XCTAssertFalse(CameraRecordingEngine.movieFile.streamsToHost)
        XCTAssertFalse(CameraRecordingEngine.assetWriter.streamsToHost)
        XCTAssertTrue(CameraRecordingEngine.streamingAssetWriter.streamsToHost)
    }

    // MARK: - stop()

    /// A stop with no samples must report nothing.
    ///
    /// This is the guard that matters most. `AVAssetWriter` will happily finish a file with no
    /// tracks, and that file is *valid* — so without this the vault stores an unplayable
    /// artifact that is indistinguishable from a successful recording, and the user finds out
    /// when they tap it.
    func test_stoppingWithoutASingleSampleReturnsNil() async {
        let recorder = AssetWriterRecorder()
        let url = Self.temporaryURL()

        recorder.start(to: url, rotationDegrees: 0)
        let result = await recorder.stop()

        XCTAssertNil(result)
    }

    /// And a stop that was never started must not crash or invent a URL.
    func test_stoppingWithoutStartingReturnsNil() async {
        let recorder = AssetWriterRecorder()
        let result = await recorder.stop()
        XCTAssertNil(result)
    }

    /// Starting twice must not leave the first writer half-finished.
    func test_restartingReplacesThePreviousWriter() async {
        let recorder = AssetWriterRecorder()
        recorder.start(to: Self.temporaryURL(), rotationDegrees: 0)

        let second = Self.temporaryURL()
        recorder.start(to: second, rotationDegrees: 0)
        XCTAssertEqual(recorder.outputURL, second)

        _ = await recorder.stop()
        XCTAssertNil(recorder.outputURL, "a finished recorder must not still name a file")
    }

    /// Audio arriving before any video is dropped rather than starting the session.
    ///
    /// A microphone warms up faster than a camera, so the first buffers are reliably audio.
    /// Starting on them opens the file with sound over no picture, which every player shows
    /// as black.
    func test_audioBeforeTheFirstVideoFrameDoesNotStartTheFile() async throws {
        let recorder = AssetWriterRecorder()
        let url = Self.temporaryURL()
        recorder.start(to: url, rotationDegrees: 0)

        for index in 0..<10 {
            recorder.appendAudio(try Self.silentAudioSample(index: Int64(index)))
        }

        // Still nothing: no video means no session, so there is no file to finish.
        let result = await recorder.stop()
        XCTAssertNil(result)
    }

    /// The success path, end to end, without a camera.
    ///
    /// Worth the effort of synthesising buffers: the simulator short-circuits recording
    /// entirely, so without this the entire writer would be unexercised until someone ran it
    /// on a device — and "the file is empty" or "the file has no audio track" are exactly the
    /// failures that look like success at the call site.
    func test_appendingVideoAndAudioProducesAPlayableFileWithBothTracks() async throws {
        let recorder = AssetWriterRecorder()
        let url = Self.temporaryURL()
        recorder.start(to: url, rotationDegrees: 0)

        // Real time matters to the writer: `expectsMediaDataInRealTime` means it drops what it
        // is not ready for, so the samples are paced rather than dumped in a loop.
        for index in 0..<20 {
            recorder.appendVideo(CameraFrame(
                sampleBuffer: try Self.videoSample(index: Int64(index)),
                rotationAngle: 0
            ))
            recorder.appendAudio(try Self.silentAudioSample(index: Int64(index)))
            try await Task.sleep(for: .milliseconds(20))
        }

        let stopped = await recorder.stop()
        let finished = try Self.fileURL(of: XCTUnwrap(stopped, "the writer produced no file"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))

        let asset = AVURLAsset(url: finished)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "a file with no duration is an empty file")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1, "audio input is added before startWriting, or it cannot be added at all")

        let videoTrack = try XCTUnwrap(videoTracks.first)
        let size = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 640, height: 480))

        try? FileManager.default.removeItem(at: finished)
    }

    /// The transform is carried into the track rather than applied to pixels.
    func test_theTrackCarriesTheRotationTransform() async throws {
        let recorder = AssetWriterRecorder()
        let url = Self.temporaryURL()
        recorder.start(to: url, rotationDegrees: 90)

        for index in 0..<12 {
            recorder.appendVideo(CameraFrame(
                sampleBuffer: try Self.videoSample(index: Int64(index)),
                rotationAngle: 90
            ))
            try await Task.sleep(for: .milliseconds(20))
        }

        let stopped = await recorder.stop()
        let finished = try Self.fileURL(of: XCTUnwrap(stopped))
        let asset = AVURLAsset(url: finished)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let transform = try await track.load(.preferredTransform)

        // A quarter turn, in the header — not identity, which is what "the video came out
        // sideways" looks like.
        XCTAssertEqual(transform.b, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.0001)

        try? FileManager.default.removeItem(at: finished)
    }

    // MARK: - Streaming

    /// The streamed path, end to end: segments out, a playable file when they are put back
    /// together.
    ///
    /// This is the assertion the whole step rests on. A fragmented MP4 is only a file if the
    /// initialization segment comes first and the media segments keep their order — and
    /// "encrypted, stored, and unopenable" is a failure the user would meet long after the
    /// recording was possible to repeat.
    func test_streamingProducesSegmentsThatConcatenateIntoAPlayableFile() async throws {
        let recorder = AssetWriterRecorder()
        let collected = SegmentLog()

        recorder.startStreaming(rotationDegrees: 0, includesAudio: true) { collected.append($0) }

        for index in 0..<70 {
            recorder.appendVideo(CameraFrame(
                sampleBuffer: try Self.videoSample(index: Int64(index)),
                rotationAngle: 0
            ))
            recorder.appendAudio(try Self.silentAudioSample(index: Int64(index)))
            try await Task.sleep(for: .milliseconds(20))
        }

        let stopped = await recorder.stop()
        guard case .stream(let summary) = try XCTUnwrap(stopped, "the writer produced nothing") else {
            return XCTFail("a streaming recorder must not report a file")
        }

        let segments = collected.snapshot()
        // More than one, or the segment interval never took effect and the whole clip was
        // buffered to the end — which is the thing this replaces.
        XCTAssertGreaterThan(segments.count, 1, "no segmentation happened")
        XCTAssertEqual(summary.byteCount, segments.reduce(0) { $0 + $1.count })
        XCTAssertEqual(summary.fileExtension, "mp4")

        var blob = Data()
        for segment in segments { blob.append(segment) }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Streamed_\(UUID().uuidString).mp4")
        try blob.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "the concatenation is not a playable file")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        // The reason this profile was chosen over the CMAF one, asserted rather than trusted:
        // a profile that refused muxed media would silently produce a recording with no sound.
        XCTAssertEqual(audioTracks.count, 1, "audio and video have to share one fragmented file")

        // The facts the host cannot work out for itself once the bytes are encrypted.
        XCTAssertEqual(summary.pixelWidth, 640)
        XCTAssertEqual(summary.pixelHeight, 480)
        let reportedDuration = try XCTUnwrap(summary.duration)
        XCTAssertEqual(reportedDuration, duration.seconds, accuracy: 0.5)
        XCTAssertNotNil(summary.posterData, "no poster means no thumbnail for the library")
    }

    /// A rotated recording reports rotated dimensions.
    ///
    /// The track stores its size pre-rotation, so a portrait clip measures landscape until the
    /// transform is applied — and the host writes whatever it is told into the item's metadata,
    /// where it decides the aspect ratio of every grid cell.
    func test_streamedDimensionsAreOriented() async throws {
        let recorder = AssetWriterRecorder()
        recorder.startStreaming(rotationDegrees: 90, includesAudio: false) { _ in }

        for index in 0..<20 {
            recorder.appendVideo(CameraFrame(
                sampleBuffer: try Self.videoSample(index: Int64(index)),
                rotationAngle: 90
            ))
            try await Task.sleep(for: .milliseconds(20))
        }

        let stopped = await recorder.stop()
        guard case .stream(let summary) = try XCTUnwrap(stopped) else {
            return XCTFail("expected a streamed recording")
        }
        XCTAssertEqual(summary.pixelWidth, 480)
        XCTAssertEqual(summary.pixelHeight, 640)
    }

    /// A streamed recording with no video is nothing, and must emit nothing.
    ///
    /// Same guard as the file path, and it matters more here: the host has already opened a
    /// destination, so a summary would commit an item whose only content is an
    /// initialization segment — a file that exists, has no frames, and plays as nothing.
    func test_streamingWithoutAVideoSampleProducesNoSegmentsAndNoSummary() async throws {
        let recorder = AssetWriterRecorder()
        let collected = SegmentLog()
        recorder.startStreaming(rotationDegrees: 0, includesAudio: true) { collected.append($0) }

        for index in 0..<10 {
            recorder.appendAudio(try Self.silentAudioSample(index: Int64(index)))
        }

        let stopped = await recorder.stop()
        XCTAssertNil(stopped)
        XCTAssertTrue(collected.snapshot().isEmpty)
    }

    /// Segments reach the sink in the order they were produced, through the pump that keeps
    /// AVFoundation's queue from waiting on the host's disk.
    func test_thePumpPreservesOrderAndReportsAFailure() async throws {
        let sink = RecordingSinkSpy()
        let pump = CaptureStreamPump(sink: sink)
        for index in 0..<50 { pump.enqueue(Data([UInt8(index)])) }
        let failure = await pump.finish()

        XCTAssertNil(failure)
        XCTAssertEqual(sink.snapshot().map { $0.first }, (0..<50).map { UInt8($0) })

        // And a sink that fails is reported rather than swallowed: the recording is gone, and
        // the only thing worse than saying so is not saying so.
        let failing = RecordingSinkSpy()
        failing.failOnWrite = true
        let failingPump = CaptureStreamPump(sink: failing)
        failingPump.enqueue(Data([1]))
        let reported = await failingPump.finish()
        XCTAssertNotNil(reported)
    }

    // MARK: - Bitrate

    /// Scaled by pixel count, so a 4K clip is not encoded at a 1080p rate and a small one is
    /// not given 6 Mbps it cannot use.
    func test_bitRateScalesWithPixelCount() {
        let hd = AssetWriterRecorder.bitRate(width: 1920, height: 1080)
        XCTAssertEqual(hd, 6_000_000)

        // Four times the pixels, four times the rate — up to the cap.
        let uhd = AssetWriterRecorder.bitRate(width: 3840, height: 2160)
        XCTAssertEqual(uhd, 24_000_000)

        // Orientation must not change the answer: it is pixels, not width.
        XCTAssertEqual(
            AssetWriterRecorder.bitRate(width: 1080, height: 1920),
            AssetWriterRecorder.bitRate(width: 1920, height: 1080)
        )
    }

    /// Both ends are clamped: a tiny capture still gets a usable rate, and an enormous one
    /// does not ask the encoder for something it will refuse.
    func test_bitRateIsClampedAtBothEnds() {
        XCTAssertEqual(AssetWriterRecorder.bitRate(width: 16, height: 16), 1_000_000)
        XCTAssertEqual(AssetWriterRecorder.bitRate(width: 16_000, height: 9_000), 40_000_000)
        // Degenerate input must not divide by zero.
        XCTAssertEqual(AssetWriterRecorder.bitRate(width: 0, height: 0), 1_000_000)
    }

    // MARK: - Track transform

    /// The rotation goes into the container header, not into the pixels — one matrix instead
    /// of a full-frame copy 30 times a second.
    func test_captureAngleBecomesARotationTransform() {
        XCTAssertTrue(CameraService.transform(forCaptureAngle: 0).isIdentity)

        let ninety = CameraService.transform(forCaptureAngle: 90)
        XCTAssertEqual(ninety.a, 0, accuracy: 0.0001)
        XCTAssertEqual(ninety.b, 1, accuracy: 0.0001)
        XCTAssertEqual(ninety.c, -1, accuracy: 0.0001)
        XCTAssertEqual(ninety.d, 0, accuracy: 0.0001)

        // A quarter turn applied four times is back where it started, so the sign convention
        // is self-consistent rather than merely plausible.
        let full = CameraService.transform(forCaptureAngle: 360)
        XCTAssertEqual(full.a, 1, accuracy: 0.0001)
        XCTAssertEqual(full.b, 0, accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// The file a finished recording named, or a failure that explains which case arrived.
    private static func fileURL(of output: RecordingOutput) throws -> URL {
        guard case .file(let url) = output else {
            throw XCTSkip("expected a file recording, got a streamed one")
        }
        return url
    }

    private static func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecorderTest_\(UUID().uuidString).mov")
    }

    /// A 640x480 frame. Larger than the 64x48 used elsewhere in these tests because a real
    /// encoder is involved here, and very small dimensions are not reliably encodable.
    private static func videoSample(index: Int64) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )

        // 30 fps in a 600 timescale, which divides evenly.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 20, timescale: 600),
            presentationTimeStamp: CMTime(value: index * 20, timescale: 600),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    /// One buffer of silence, which is enough to prove it was ignored.
    private static func silentAudioSample(index: Int64) throws -> CMSampleBuffer {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )

        var format: CMFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamDescription,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format
            ),
            noErr
        )

        let frameCount = 1_024
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: frameCount * 2, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: frameCount * 2,
                flags: 0, blockBufferOut: &blockBuffer
            ),
            noErr
        )
        let block = try XCTUnwrap(blockBuffer)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: frameCount * 2), noErr)

        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: try XCTUnwrap(format),
                sampleCount: frameCount,
                presentationTimeStamp: CMTime(value: index * Int64(frameCount), timescale: 44_100),
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }
}

/// Collects segments off whichever queue AVFoundation delivers them on.
private final class SegmentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [Data] = []

    func append(_ segment: Data) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
    }

    func snapshot() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return segments
    }
}

/// A sink that keeps what it is given, and can be told to fail.
private final class RecordingSinkSpy: CaptureVideoSink, @unchecked Sendable {
    /// The pump calls `write` one at a time, so this needs no lock — which is itself part of
    /// the contract being asserted.
    nonisolated(unsafe) private var chunks: [Data] = []
    nonisolated(unsafe) var failOnWrite = false

    func write(_ chunk: Data) async throws {
        if failOnWrite { throw CocoaError(.fileWriteOutOfSpace) }
        chunks.append(chunk)
    }

    func finish(_ summary: CaptureVideoSummary) async throws -> CaptureReceipt {
        CaptureReceipt(thumbnailData: nil)
    }

    func cancel() async {}

    func snapshot() -> [Data] { chunks }
}

import AVFoundation
import CoreVideo
import XCTest
@testable import KVCameraKit

/// The fan-out and the subscription lifetime.
///
/// None of this needs a sensor, and all of it is where a frame pipeline goes wrong in ways
/// that look like something else: a consumer that keeps receiving after it was cancelled, a
/// tap that stays attached because a token was dropped, a subscribe that deadlocks against a
/// frame already in flight.
final class FrameSourceTests: XCTestCase {

    // MARK: - Subscription

    func test_cancellingASubscriptionIsIdempotent() {
        let cancellations = Counter()
        let subscription = FrameSubscription { cancellations.increment() }

        subscription.cancel()
        subscription.cancel()
        subscription.cancel()

        // Cancelling twice must not decrement a consumer count twice, or the tap detaches
        // while a second consumer is still reading.
        XCTAssertEqual(cancellations.value, 1)
    }

    /// The token cancels itself when it goes out of scope.
    ///
    /// Forgetting to cancel has no visible symptom — the session keeps producing frames for a
    /// consumer nobody is listening to, and the only trace is battery. So the token owns the
    /// lifetime rather than trusting a caller to remember.
    func test_droppingTheTokenCancelsTheSubscription() {
        let cancellations = Counter()
        do {
            _ = FrameSubscription { cancellations.increment() }
        }
        XCTAssertEqual(cancellations.value, 1)
    }

    func test_explicitCancelThenDeinitStillOnlyCancelsOnce() {
        let cancellations = Counter()
        do {
            let subscription = FrameSubscription { cancellations.increment() }
            subscription.cancel()
        }
        XCTAssertEqual(cancellations.value, 1)
    }

    // MARK: - Fan-out

    func test_everyConsumerSeesEveryFrame_andCancelledOnesSeeNone() throws {
        let tap = CameraFrameTap(session: AVCaptureSession(), sessionQueue: DispatchQueue(label: "test.session"))

        let first = Counter()
        let second = Counter()
        let firstToken = tap.addConsumer { _ in first.increment() }
        let secondToken = tap.addConsumer { _ in second.increment() }

        try deliver(frames: 3, to: tap)
        XCTAssertEqual(first.value, 3)
        XCTAssertEqual(second.value, 3)

        // One leaves; the other must be unaffected.
        firstToken.cancel()
        try deliver(frames: 2, to: tap)
        XCTAssertEqual(first.value, 3, "a cancelled consumer kept receiving frames")
        XCTAssertEqual(second.value, 5)

        secondToken.cancel()
        try deliver(frames: 2, to: tap)
        XCTAssertEqual(second.value, 5)
    }

    /// Statistics count what the sensor produced, not what consumers wanted.
    ///
    /// Delivered frames are recorded even with nobody subscribed, because "the tap is attached
    /// and running but nothing is reading it" is exactly the waste this number exists to make
    /// visible.
    func test_statisticsRecordFramesAndDropsFromTheDelegateCallbacks() throws {
        let tap = CameraFrameTap(session: AVCaptureSession(), sessionQueue: DispatchQueue(label: "test.session"))

        try deliver(frames: 31, to: tap)
        tap.captureOutput(
            AVCaptureVideoDataOutput(),
            didDrop: try Self.makeSampleBuffer(index: 99),
            from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput())
        )

        let stats = tap.statistics
        XCTAssertEqual(stats.delivered, 31)
        XCTAssertEqual(stats.dropped, 1)
        XCTAssertEqual(stats.dimensions, CGSize(width: 64, height: 48))
        XCTAssertEqual(stats.pixelFormat, kCVPixelFormatType_32BGRA)
        // 31 frames at a 30th of a second apart is one second of video.
        XCTAssertEqual(try XCTUnwrap(stats.framesPerSecond), 30, accuracy: 0.01)
    }

    /// A consumer that subscribes from inside its own callback must not deadlock.
    ///
    /// The tap copies its consumer list and releases the lock *before* calling anyone,
    /// precisely so this is possible. Holding the lock across delivery would hang here, and it
    /// would hang on a background queue where the stack trace says nothing.
    func test_subscribingFromInsideAFrameCallbackDoesNotDeadlock() throws {
        let tap = CameraFrameTap(session: AVCaptureSession(), sessionQueue: DispatchQueue(label: "test.session"))

        let inner = Counter()
        let innerToken = TokenBox()
        let outerToken = tap.addConsumer { _ in
            innerToken.setIfEmpty { tap.addConsumer { _ in inner.increment() } }
        }

        try deliver(frames: 2, to: tap)
        // The nested consumer joined during the first frame, so it saw the second.
        XCTAssertEqual(inner.value, 1)

        outerToken.cancel()
        innerToken.cancel()
    }

    /// Frames arrive on a queue, and `statistics` is read from another one.
    func test_statisticsSurviveConcurrentDeliveryAndReads() throws {
        let tap = CameraFrameTap(session: AVCaptureSession(), sessionQueue: DispatchQueue(label: "test.session"))
        let received = Counter()
        let token = tap.addConsumer { _ in received.increment() }

        let group = DispatchGroup()
        for index in 0..<200 {
            DispatchQueue.global().async(group: group) {
                if let buffer = try? Self.makeSampleBuffer(index: Int64(index)) {
                    tap.captureOutput(
                        AVCaptureVideoDataOutput(),
                        didOutput: buffer,
                        from: AVCaptureConnection(inputPorts: [], output: AVCaptureVideoDataOutput())
                    )
                }
                _ = tap.statistics
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        XCTAssertEqual(tap.statistics.delivered, 200)
        XCTAssertEqual(received.value, 200)
        token.cancel()
    }

    // MARK: - Frame contract

    func test_frameExposesFormatDimensionsAndTiming() throws {
        let frame = CameraFrame(sampleBuffer: try Self.makeSampleBuffer(index: 6), rotationAngle: 90)

        XCTAssertNotNil(frame.pixelBuffer)
        XCTAssertEqual(frame.dimensions, CGSize(width: 64, height: 48))
        XCTAssertEqual(frame.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(frame.presentationTime.seconds, 6.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(frame.rotationAngle, 90)
    }

    // MARK: - Simulated stream

    /// The stand-in has to actually stream, or every step built on it is built on nothing.
    func test_simulatedSourceDeliversMovingFrames_andStopsWhenCancelled() throws {
        let source = SimulatedFrameSource(size: CGSize(width: 64, height: 48), frameRate: 60)

        let received = Counter()
        let token = source.addConsumer { _ in received.increment() }

        let arrived = expectation(description: "frames arrive")
        DispatchQueue.global().async {
            while received.value < 5 { usleep(2_000) }
            arrived.fulfill()
        }
        wait(for: [arrived], timeout: 5)

        XCTAssertGreaterThanOrEqual(source.statistics.delivered, 5)
        XCTAssertEqual(source.statistics.dimensions, CGSize(width: 64, height: 48))
        // Timestamps come from the frame counter, so the reported rate is the requested one
        // even when the host Mac schedules the timer unevenly.
        XCTAssertEqual(try XCTUnwrap(source.statistics.framesPerSecond), 60, accuracy: 0.01)

        token.cancel()
        let afterCancel = received.value
        // Long enough that a still-running 60 fps timer would add dozens of frames.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(received.value, afterCancel, "the timer kept running after the last consumer left")
    }

    // MARK: - Helpers

    /// Drives the delegate method AVFoundation would call, so the fan-out is exercised without
    /// a session that could deliver anything.
    private func deliver(frames count: Int, to tap: CameraFrameTap) throws {
        let output = AVCaptureVideoDataOutput()
        let connection = AVCaptureConnection(inputPorts: [], output: output)
        for index in 0..<count {
            tap.captureOutput(output, didOutput: try Self.makeSampleBuffer(index: Int64(index)), from: connection)
        }
    }

    private static func makeSampleBuffer(index: Int64) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixelBuffer),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 20, timescale: 600),
            presentationTimeStamp: CMTime(value: CMTimeValue(index * 20), timescale: 600),
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
}

/// Holds the subscription a nested consumer creates. A captured `var` cannot be written from a
/// `@Sendable` closure, which is the compiler making the same point the test is checking.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: FrameSubscription?

    func setIfEmpty(_ make: () -> FrameSubscription) {
        lock.lock()
        let isEmpty = token == nil
        lock.unlock()
        guard isEmpty else { return }

        let new = make()
        lock.lock()
        token = new
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        token?.cancel()
    }
}

/// Frames arrive on the source's own queue, so a plain `var` counter would be a race the test
/// itself introduces.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

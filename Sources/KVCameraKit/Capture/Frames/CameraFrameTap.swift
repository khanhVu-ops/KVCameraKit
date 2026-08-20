import AVFoundation
import CoreGraphics
import Foundation

/// `AVCaptureVideoDataOutput`, fanned out to any number of consumers.
///
/// Deliberately parallel to `AVCaptureVideoPreviewLayer` rather than a replacement for it.
/// The preview layer is the viewfinder that currently works, and replacing it in the same
/// change as introducing a frame pipeline would mean debugging two new things at once with no
/// reference left on screen: a dropped frame, a wrong orientation, a colour shift and a black
/// screen all look the same when the only known-good path is the one you just deleted.
///
/// So this attaches, delivers, and counts. Nothing user-visible changes, and a later step can
/// switch the preview over behind a flag knowing what the frames cost.
final class CameraFrameTap: NSObject, FrameSource, @unchecked Sendable {

    private let output = AVCaptureVideoDataOutput()

    /// Its own queue, and specifically **not** the session queue. Frame delivery is
    /// continuous, so handing it the queue that also serialises `beginConfiguration`, zoom and
    /// capture would put a 30 Hz workload in front of every tap on the shutter.
    ///
    /// Serial, because `AVCaptureVideoDataOutputSampleBufferDelegate` requires it: a
    /// concurrent queue delivers frames out of order, which for anything that cares about
    /// timing is worse than dropping them.
    private let frameQueue = DispatchQueue(label: "com.iosvault.camera.frameQueue")

    private let lock = NSLock()
    private var consumers: [UUID: FrameConsumer] = [:]
    private var accumulator = FrameStatisticsAccumulator()
    private var isAttached = false

    /// The session and the queue that owns its configuration, supplied by `CameraService`.
    /// Held rather than passed per call so `addConsumer` can attach without every caller
    /// needing to know how the session is serialised.
    private weak var session: AVCaptureSession?
    private let sessionQueue: DispatchQueue

    /// The horizon-level angle, kept in step with the preview by whoever owns the rotation
    /// coordinator. Read per frame so a rotation mid-stream is reflected without the consumer
    /// having to ask.
    private var rotationAngle: CGFloat?

    init(session: AVCaptureSession, sessionQueue: DispatchQueue) {
        self.session = session
        self.sessionQueue = sessionQueue
        super.init()

        // Late frames are discarded rather than queued, which is the only defensible choice
        // for a tap running beside a live viewfinder: back-pressure from a slow consumer would
        // otherwise reach the session itself. A dropped frame is counted and visible in
        // `statistics`; a stalled session is not.
        output.alwaysDiscardsLateVideoFrames = true

        // No `videoSettings`: the native format is taken as-is. Requesting BGRA here would be
        // a per-frame conversion bought before knowing whether anything needs it — see
        // `CameraFrame.pixelFormat`.
        output.setSampleBufferDelegate(self, queue: frameQueue)
    }

    var statistics: FrameStatistics {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.statistics
    }

    /// The angle to report with each frame. Called by the rotation controller.
    func setRotationAngle(_ angle: CGFloat?) {
        lock.lock()
        rotationAngle = angle
        lock.unlock()
    }

    // MARK: - Consumers

    func addConsumer(_ consumer: @escaping FrameConsumer) -> FrameSubscription {
        let id = UUID()

        lock.lock()
        consumers[id] = consumer
        let isFirst = consumers.count == 1
        lock.unlock()

        if isFirst {
            attach()
        }

        return FrameSubscription { [weak self] in
            self?.removeConsumer(id)
        }
    }

    private func removeConsumer(_ id: UUID) {
        lock.lock()
        consumers.removeValue(forKey: id)
        let isEmpty = consumers.isEmpty
        lock.unlock()

        if isEmpty {
            detach()
        }
    }

    // MARK: - Attach / detach

    private func attach() {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.session else { return }

            self.lock.lock()
            let alreadyAttached = self.isAttached
            self.lock.unlock()
            guard !alreadyAttached else { return }

            // Adding an output is a session reconfiguration, and this one can change what the
            // photo path is able to do — on some devices a video data output lowers the
            // maximum photo dimensions or disables zero-shutter-lag. That is precisely what
            // running it in parallel is meant to surface, while the old preview is still on
            // screen to compare against.
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            guard session.canAddOutput(self.output) else { return }
            session.addOutput(self.output)

            self.lock.lock()
            self.isAttached = true
            self.lock.unlock()
        }
    }

    private func detach() {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.session else { return }

            self.lock.lock()
            let wasAttached = self.isAttached
            // Checked again on the session queue: a consumer can arrive between the decision
            // to detach and this block running, and tearing the output down under it would
            // leave a subscriber that never receives a frame.
            let hasConsumers = !self.consumers.isEmpty
            self.lock.unlock()

            guard wasAttached, !hasConsumers else { return }

            session.beginConfiguration()
            session.removeOutput(self.output)
            session.commitConfiguration()

            self.lock.lock()
            self.isAttached = false
            self.lock.unlock()
        }
    }
}

extension CameraFrameTap: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        let recipients = Array(consumers.values)
        let angle = rotationAngle
        lock.unlock()

        let frame = CameraFrame(sampleBuffer: sampleBuffer, rotationAngle: angle)

        lock.lock()
        accumulator.record(
            presentationSeconds: frame.presentationTime.seconds,
            pixelFormat: frame.pixelFormat,
            dimensions: frame.dimensions
        )
        lock.unlock()

        // The lock is released before the consumers run. Holding it across a consumer would
        // mean a slow one blocks `statistics` and every subscribe — and a consumer that
        // subscribed from inside its own callback would deadlock.
        for consumer in recipients {
            consumer(frame)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        accumulator.recordDrop()
        lock.unlock()
    }
}

import Foundation

/// A live stream of camera frames, separate from the viewfinder.
///
/// The camera has never seen a pixel: `AVCaptureVideoPreviewLayer` renders the session
/// straight into a `CALayer`, and stills arrive through a photo delegate. Every remaining
/// step on the roadmap needs frames — a scanner needs them for Vision, a Metal preview needs
/// them to draw, `AVAssetWriter` needs them to write, live filters need them to filter — so
/// this is the one dependency they share, added once.
///
/// A protocol for the usual reason in this package: the only real implementation needs a
/// device, and "does the fan-out drop a consumer, does the tap detach when the last one
/// leaves" are questions worth answering in milliseconds.
protocol FrameSource: AnyObject, Sendable {

    /// Starts delivering frames to `consumer` and returns the token that stops it.
    ///
    /// Attaching is lazy: the output goes onto the session with the first consumer and comes
    /// off after the last one. A screen that only ever takes a photo pays nothing — which
    /// matters, because an `AVCaptureVideoDataOutput` is not free even when nobody reads it.
    func addConsumer(_ consumer: @escaping FrameConsumer) -> FrameSubscription

    /// What has been delivered so far. See `FrameStatistics` for why this exists.
    var statistics: FrameStatistics { get }
}

/// Cancels one consumer's subscription.
///
/// Cancelled on `deinit` as well as by hand, because the failure mode of forgetting is
/// invisible: an orphaned consumer keeps the tap attached, so the session keeps paying for
/// frames nobody reads, and there is nothing on screen to suggest it.
final class FrameSubscription: @unchecked Sendable {

    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    deinit {
        cancel()
    }

    /// Idempotent: the token is cancelled once, whether by hand, by `deinit`, or both.
    func cancel() {
        lock.lock()
        let cancellation = onCancel
        onCancel = nil
        lock.unlock()
        cancellation?()
    }
}

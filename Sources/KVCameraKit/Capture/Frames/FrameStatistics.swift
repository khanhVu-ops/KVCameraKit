import CoreGraphics
import CoreVideo
import Foundation

/// What the frame tap actually delivered.
///
/// The point of running a frame source next to the working viewfinder is to be able to
/// answer "at what cost" before anything depends on it. Numbers, not impressions: a preview
/// that feels fine at 22 fps looks identical to one at 30 until you measure, and a tap that
/// silently drops a third of its frames is the kind of thing a scanner or a recorder
/// inherits as a bug two steps later.
struct FrameStatistics: Equatable, Sendable {
    var delivered: Int = 0
    /// Frames AVFoundation threw away because the consumer was too slow. With
    /// `alwaysDiscardsLateVideoFrames` on, this is the honest cost signal.
    var dropped: Int = 0
    /// From the buffers' own presentation timestamps, not a wall clock — the sensor's clock
    /// is the only one that says anything about the sensor.
    var framesPerSecond: Double?
    var pixelFormat: OSType?
    var dimensions: CGSize?

    /// The share of frames that never reached a consumer.
    var dropRate: Double? {
        let total = delivered + dropped
        guard total > 0 else { return nil }
        return Double(dropped) / Double(total)
    }

    /// `nil` until there is a second frame to measure an interval against.
    var isMeasured: Bool { framesPerSecond != nil }
}

/// Accumulates `FrameStatistics` from timestamps.
///
/// A separate value type with no AVFoundation in it, so the arithmetic — a rolling window, a
/// rate from timestamps, the drop share — is testable without a camera. The alternative was
/// counters inside the delegate, where verifying "does 30 fps report 30" needs a device
/// pointed at something.
struct FrameStatisticsAccumulator {

    /// Frames kept for the rate estimate. Thirty is about a second of video: long enough that
    /// one late frame does not swing the number, short enough that the reading still
    /// describes now rather than the average since launch.
    static let windowSize = 30

    private var delivered = 0
    private var dropped = 0
    private var pixelFormat: OSType?
    private var dimensions: CGSize?
    /// Presentation times in seconds, oldest first.
    private var window: [Double] = []

    mutating func record(presentationSeconds: Double, pixelFormat: OSType?, dimensions: CGSize?) {
        delivered += 1
        self.pixelFormat = pixelFormat
        self.dimensions = dimensions

        // A non-finite timestamp means the buffer had an invalid `CMTime`. Counted as
        // delivered — it was — but kept out of the window, because one NaN would poison
        // every rate after it.
        guard presentationSeconds.isFinite else { return }

        window.append(presentationSeconds)
        if window.count > Self.windowSize {
            window.removeFirst(window.count - Self.windowSize)
        }
    }

    mutating func recordDrop() {
        dropped += 1
    }

    var statistics: FrameStatistics {
        FrameStatistics(
            delivered: delivered,
            dropped: dropped,
            framesPerSecond: Self.rate(over: window),
            pixelFormat: pixelFormat,
            dimensions: dimensions
        )
    }

    /// Intervals, not frames, over elapsed time: `n` timestamps bound `n - 1` intervals, and
    /// dividing by `n` instead is the off-by-one that makes 30 fps read as 29.
    static func rate(over window: [Double]) -> Double? {
        guard window.count >= 2 else { return nil }
        let elapsed = window[window.count - 1] - window[0]
        guard elapsed > 0 else { return nil }
        return Double(window.count - 1) / elapsed
    }
}

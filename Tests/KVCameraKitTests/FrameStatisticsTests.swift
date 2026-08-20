import CoreGraphics
import CoreVideo
import XCTest
@testable import KVCameraKit

/// The arithmetic behind "at what cost", without a camera.
///
/// This is the whole reason `FrameStatisticsAccumulator` is a value type with no AVFoundation
/// in it. Asking "does a 30 fps stream report 30" of a delegate means a device pointed at
/// something; asking it of timestamps is five assertions.
final class FrameStatisticsTests: XCTestCase {

    func test_rateNeedsTwoTimestampsToMeanAnything() {
        XCTAssertNil(FrameStatisticsAccumulator.rate(over: []))
        XCTAssertNil(FrameStatisticsAccumulator.rate(over: [1.0]))
        // Every frame at the same instant is not an infinite frame rate, it is no measurement.
        XCTAssertNil(FrameStatisticsAccumulator.rate(over: [2.0, 2.0, 2.0]))
    }

    /// Intervals, not frames, over elapsed time.
    ///
    /// The off-by-one here is the interesting part: 31 timestamps a 30th of a second apart
    /// span exactly one second and bound 30 intervals. Dividing the *count* by the elapsed
    /// time instead reports 31 — plausible enough on a screen to never be questioned.
    func test_rateCountsIntervalsRatherThanFrames() throws {
        let timestamps = (0...30).map { Double($0) / 30.0 }
        let rate = try XCTUnwrap(FrameStatisticsAccumulator.rate(over: timestamps))
        XCTAssertEqual(rate, 30, accuracy: 0.0001)

        // Two frames a 60th apart is 60 fps, from the smallest possible sample.
        let pair = try XCTUnwrap(FrameStatisticsAccumulator.rate(over: [0, 1.0 / 60.0]))
        XCTAssertEqual(pair, 60, accuracy: 0.0001)
    }

    func test_accumulatorReportsFormatDimensionsAndRate() throws {
        var accumulator = FrameStatisticsAccumulator()
        let size = CGSize(width: 1920, height: 1080)

        for index in 0...30 {
            accumulator.record(
                presentationSeconds: Double(index) / 30.0,
                pixelFormat: kCVPixelFormatType_32BGRA,
                dimensions: size
            )
        }

        let stats = accumulator.statistics
        XCTAssertEqual(stats.delivered, 31)
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertEqual(stats.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(stats.dimensions, size)
        XCTAssertEqual(try XCTUnwrap(stats.framesPerSecond), 30, accuracy: 0.0001)
        XCTAssertEqual(stats.dropRate, 0)
        XCTAssertTrue(stats.isMeasured)
    }

    /// The rate has to describe now, not the average since launch.
    ///
    /// A stream that ran at 30 fps for a minute and then collapsed to 10 must read as 10 — an
    /// unbounded window would still be reporting 29 and nobody would look further.
    func test_windowDropsOldFramesSoTheRateDescribesTheRecentPast() throws {
        var accumulator = FrameStatisticsAccumulator()

        var time = 0.0
        for _ in 0..<200 {
            accumulator.record(presentationSeconds: time, pixelFormat: nil, dimensions: nil)
            time += 1.0 / 30.0
        }
        XCTAssertEqual(try XCTUnwrap(accumulator.statistics.framesPerSecond), 30, accuracy: 0.01)

        // Now it stalls to 10 fps for long enough to fill the window.
        for _ in 0..<FrameStatisticsAccumulator.windowSize {
            accumulator.record(presentationSeconds: time, pixelFormat: nil, dimensions: nil)
            time += 1.0 / 10.0
        }
        XCTAssertEqual(try XCTUnwrap(accumulator.statistics.framesPerSecond), 10, accuracy: 0.01)
        // Every frame is still counted, even the ones that have left the window.
        XCTAssertEqual(accumulator.statistics.delivered, 200 + FrameStatisticsAccumulator.windowSize)
    }

    /// An invalid `CMTime` yields a non-finite `seconds`, and one of those in the window would
    /// poison every rate computed after it.
    func test_nonFiniteTimestampIsCountedButNotMeasured() {
        var accumulator = FrameStatisticsAccumulator()

        accumulator.record(presentationSeconds: .nan, pixelFormat: nil, dimensions: nil)
        accumulator.record(presentationSeconds: .infinity, pixelFormat: nil, dimensions: nil)
        XCTAssertEqual(accumulator.statistics.delivered, 2)
        XCTAssertNil(accumulator.statistics.framesPerSecond)

        accumulator.record(presentationSeconds: 0, pixelFormat: nil, dimensions: nil)
        accumulator.record(presentationSeconds: 0.5, pixelFormat: nil, dimensions: nil)
        XCTAssertEqual(accumulator.statistics.framesPerSecond, 2)
    }

    func test_dropRateIsTheShareOfFramesThatNeverArrived() throws {
        var accumulator = FrameStatisticsAccumulator()
        XCTAssertNil(accumulator.statistics.dropRate, "no frames at all is not a 0% drop rate")

        for index in 0..<3 {
            accumulator.record(presentationSeconds: Double(index), pixelFormat: nil, dimensions: nil)
        }
        accumulator.recordDrop()

        XCTAssertEqual(accumulator.statistics.delivered, 3)
        XCTAssertEqual(accumulator.statistics.dropped, 1)
        XCTAssertEqual(try XCTUnwrap(accumulator.statistics.dropRate), 0.25)
    }
}

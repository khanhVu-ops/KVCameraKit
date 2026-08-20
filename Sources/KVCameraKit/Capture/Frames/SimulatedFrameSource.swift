#if targetEnvironment(simulator)
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// A synthetic frame stream, for a machine with no camera.
///
/// The same reasoning as `SimulatedCapture`, applied to the part that matters more. A
/// simulator has no session at all — `setupSession()` returns `true` without configuring
/// anything — so a real `AVCaptureVideoDataOutput` can never deliver a frame there. Without a
/// stand-in, *every* remaining step on the roadmap becomes device-only work: a scanner cannot
/// be pointed at anything, a Metal preview has nothing to draw, a filter has nothing to
/// filter, and a recorder has nothing to write. That is a long time to develop blind.
///
/// So it produces a moving pattern at a fixed rate, through the same `FrameSource` port. It
/// proves nothing about performance — the point of measuring on a device is that only a device
/// can answer that — but it makes everything downstream of frames runnable and previewable
/// today.
final class SimulatedFrameSource: FrameSource, @unchecked Sendable {

    private let size: CGSize
    private let frameRate: Int
    private let queue = DispatchQueue(label: "com.iosvault.camera.simulatedFrameQueue")

    private let lock = NSLock()
    private var consumers: [UUID: FrameConsumer] = [:]
    private var accumulator = FrameStatisticsAccumulator()
    private var timer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0

    private var formatDescription: CMFormatDescription?

    init(size: CGSize = CGSize(width: 1080, height: 1920), frameRate: Int = 30) {
        self.size = size
        self.frameRate = frameRate
    }

    var statistics: FrameStatistics {
        lock.lock()
        defer { lock.unlock() }
        return accumulator.statistics
    }

    func addConsumer(_ consumer: @escaping FrameConsumer) -> FrameSubscription {
        let id = UUID()

        lock.lock()
        consumers[id] = consumer
        let isFirst = consumers.count == 1
        lock.unlock()

        if isFirst { start() }

        return FrameSubscription { [weak self] in
            self?.removeConsumer(id)
        }
    }

    private func removeConsumer(_ id: UUID) {
        lock.lock()
        consumers.removeValue(forKey: id)
        let isEmpty = consumers.isEmpty
        lock.unlock()

        if isEmpty { stop() }
    }

    private func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        lock.unlock()

        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(1000.0 / Double(frameRate))))
        timer.setEventHandler { [weak self] in
            self?.emit()
        }
        timer.resume()
    }

    private func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    /// Timestamps come from a frame counter rather than a wall clock, so the reported rate is
    /// the rate that was asked for even when the timer fires unevenly under a debugger. A
    /// simulated stream that reported jitter would only teach a lesson about the host Mac.
    private func emit() {
        lock.lock()
        let recipients = Array(consumers.values)
        let index = frameIndex
        frameIndex += 1
        lock.unlock()

        guard !recipients.isEmpty,
              let pixelBuffer = makePixelBuffer(phase: Double(index) / Double(frameRate)),
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer, index: index) else { return }

        let frame = CameraFrame(sampleBuffer: sampleBuffer, rotationAngle: 0)

        lock.lock()
        accumulator.record(
            presentationSeconds: frame.presentationTime.seconds,
            pixelFormat: frame.pixelFormat,
            dimensions: frame.dimensions
        )
        lock.unlock()

        for consumer in recipients {
            consumer(frame)
        }
    }

    /// A gradient with a bar that sweeps across it, because a static image cannot tell a
    /// stopped stream from a running one.
    private func makePixelBuffer(phase: Double) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        context.setFillColor(UIColor.darkGray.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let barHeight = size.height / 8
        let travel = size.height + barHeight
        let y = (phase * travel).truncatingRemainder(dividingBy: travel) - barHeight
        context.setFillColor(UIColor.systemIndigo.cgColor)
        context.fill(CGRect(x: 0, y: y, width: size.width, height: barHeight))

        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, index: Int64) -> CMSampleBuffer? {
        if formatDescription == nil {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            formatDescription = description
        }
        guard let formatDescription = formatDescription else { return nil }

        // A 600 timescale is what AVFoundation uses for video: it divides evenly by 24, 25 and
        // 30, so none of the common frame rates lands on a repeating fraction.
        let timescale: CMTimeScale = 600
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(timescale / CMTimeScale(frameRate)), timescale: timescale),
            presentationTimeStamp: CMTime(
                value: CMTimeValue(index * Int64(timescale / CMTimeScale(frameRate))),
                timescale: timescale
            ),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
#endif

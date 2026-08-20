import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Rewrites a frame's pixels before the recorder appends it.
///
/// This exists because of what the first censor implementation did not do. It censored the
/// viewfinder — with a SwiftUI overlay that did not touch the camera's pixels at all — and it
/// censored a captured still. A recording it left completely alone: `grep censor` over
/// `AssetWriterRecorder` found nothing. So with the feature switched on, a video came out of the
/// vault with every face in it perfectly legible, and the only thing that had ever suggested
/// otherwise was an overlay drawn on top of the preview while it recorded.
///
/// That is the worst shape a privacy bug can take. Nothing failed, nothing was logged, and the
/// screen actively said the opposite of the truth for the whole duration of the recording.
///
/// Two properties of the implementation are load-bearing:
///
/// **A frame with no faces is returned untouched.** Not re-rendered, not re-encoded — the same
/// `CMSampleBuffer` object. Censoring is mostly idle: a subject enters, is covered, leaves. Paying
/// a full-frame Core Image render on frames with nothing to hide would be paying it nearly always.
///
/// **The buffer is a copy, into a pool.** The source belongs to AVFoundation's finite pool and
/// rendering into it in place would hand a mutated buffer to whatever else is reading the same
/// frame — the viewfinder, on the same stream. Which would look like the censor working
/// perfectly, right up until the two disagreed about timing.
final class CensorVideoStage: @unchecked Sendable {

    /// Unmanaged, matching `ToneRenderer` and the shader: the effect operates on the same
    /// gamma-encoded values the preview does. Colour-managing here would make every recorded
    /// frame differ from the viewfinder it was composed in.
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    /// Set once, before the recording starts.
    var mode: CameraCensorMode = .off
    /// Read per frame — the geometry is produced on the detector's queue and this is called on
    /// the writer's, so the newest value is the only correct one to use.
    var regions: (@Sendable () -> [CensorRegion])?

    /// Writer queue only, all three. The recorder calls `process` from one serial queue, which
    /// is what makes a pool with no lock around it correct.
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0
    private var poolDimensions = CGSize.zero
    private var outputFormat: CMFormatDescription?

    /// The frame to append, censored — or the frame that came in, when there is nothing to do.
    ///
    /// Never `nil` for a failure: a stage that cannot render returns the original rather than
    /// dropping the frame. A dropped frame is a recording that plays fast, and a censor that
    /// silently drops frames when it fails is worse than one that visibly does nothing.
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard mode.isEnabled,
              let faces = regions?(), !faces.isEmpty,
              let source = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return sampleBuffer }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = renderableFormat(CVPixelBufferGetPixelFormatType(source))

        guard let pool = pool(for: format, width: width, height: height) else { return sampleBuffer }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return sampleBuffer }

        let image = CIImage(cvPixelBuffer: source)
        let censored = CensorRenderer.render(image: image, mode: mode, regions: faces)
        context.render(
            censored,
            to: destination,
            bounds: image.extent,
            // `nil`, to match the unmanaged working space above. Passing a colour space here
            // converts, which is the change that makes a recording not match its preview.
            colorSpace: nil
        )

        guard let description = formatDescription(for: destination) else { return sampleBuffer }

        // Timing comes off the original, unchanged. Deriving it instead — from a frame counter,
        // or from a clock read here — is how a recording ends up a frame short or a few
        // milliseconds out of sync with its audio.
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else {
            return sampleBuffer
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: destination,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &output
        ) == noErr, let output else { return sampleBuffer }

        return output
    }

    /// Releases the pool. Called at stop so a finished recording does not hold a few 4K buffers
    /// for the rest of the session.
    func reset() {
        pool = nil
        poolFormat = 0
        poolDimensions = .zero
        outputFormat = nil
    }

    // MARK: - Pool

    /// A format `CIContext.render(_:to:bounds:colorSpace:)` accepts.
    ///
    /// The sensor's own bi-planar YCbCr is kept where possible, because it is what the HEVC
    /// encoder wants and converting to BGRA and back is two conversions bought to change
    /// nothing. Anything unrecognised becomes BGRA, which every path accepts — the writer will
    /// convert it on the way into the encoder.
    private func renderableFormat(_ format: OSType) -> OSType {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_32BGRA:
            return format
        default:
            return kCVPixelFormatType_32BGRA
        }
    }

    private func pool(for format: OSType, width: Int, height: Int) -> CVPixelBufferPool? {
        let dimensions = CGSize(width: width, height: height)
        if let pool, poolFormat == format, poolDimensions == dimensions {
            return pool
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // Without this the buffers are not IOSurface-backed, which turns the render and the
            // encode into CPU copies.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        // A handful, not one: the encoder holds a frame while the next is being rendered, and a
        // pool of one stalls the writer queue waiting for its own output to be released.
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4
        ]

        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess else { return nil }

        pool = created
        poolFormat = format
        poolDimensions = dimensions
        // The description describes the pool's buffers, so it is stale the moment the pool is.
        outputFormat = nil
        return created
    }

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        if let outputFormat { return outputFormat }
        var created: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &created
        ) == noErr else { return nil }
        outputFormat = created
        return created
    }
}

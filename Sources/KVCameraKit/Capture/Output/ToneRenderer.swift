import CoreImage
import CoreMedia
import Foundation
import simd

/// The two pieces of the still path that are not the look itself: the matrix hand-off to Core
/// Image, and the base frame the filter strip builds its chips from.
///
/// The look used to live here too, behind an argument for why it had to be one matrix rather than
/// a stack of `CIColorControls`/`CITemperatureAndTint`/`CIExposureAdjust` filters that would
/// drift from the shader one adjustment at a time. That argument was right and it grew: tone is
/// now one stage of five, so the whole recipe lives in `CameraLookRenderer` beside the censor and
/// the film texture, in the shader's order. What is left here is `parameters(for:)` — the one
/// place a `simd_float4x4` becomes `CIColorMatrix` arguments — and the frame grab, which is about
/// `FrameSource` rather than about colour.
///
enum ToneRenderer {

    /// The longest edge of a filter-strip thumbnail, in pixels.
    ///
    /// Small on purpose. This is a chip about 62 pt wide behind a corner radius; the frame it
    /// comes from is 1440x1080, and every filter on the strip renders from it. Downscaling
    /// once, before the looks are applied, is the difference between a few cheap renders and a
    /// few full-frame ones.
    ///
    /// Raised from 160, and not to be sharper: at 160 the base is 120 px tall, and grain sized
    /// at `CameraFilmSimulation.grainCellsAcrossHeight` does not have a whole pixel per cell to
    /// live in, so a film preset's most recognisable property aliased into mush on the one
    /// control whose job is to preview it. 384 gives every cell a pixel and change, and the chip
    /// is displayed at about 190 px, so the slight downsample is honest rather than invented.
    static let thumbnailMaxDimension: CGFloat = 384

    /// Built once. A `CIContext` carries compiled kernels and a command queue, and stills
    /// arrive one shutter press at a time — rebuilding it per photo was measurable.
    ///
    /// `nonisolated(unsafe)` because `CIContext` is documented as safe to use from multiple
    /// threads, which is the whole reason one shared instance is correct here.
    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    // MARK: - Filter strip thumbnails

    /// One downscaled still from the live stream, to build the strip's chips from.
    ///
    /// Waits for a single frame and unsubscribes. The downscale happens **inside** the frame
    /// callback, deliberately: a delivered buffer is only valid there, and holding one to work
    /// on later is what empties AVFoundation's pool and stops delivery with nothing logged.
    ///
    /// `nil` when no frame arrived — a session that has not started, or a simulator with the
    /// system preview engine — and the strip draws its chips from a colour ramp instead of
    /// pretending it has a picture.
    static func thumbnailBase(from frames: any FrameSource, timeout: Duration = .seconds(1)) async -> CGImage? {
        let box = FirstImage()
        let subscription = frames.addConsumer { frame in
            guard !box.isFilled else { return }
            guard let image = downscale(frame, to: thumbnailMaxDimension) else { return }
            box.fill(image)
        }
        defer { subscription.cancel() }

        // Polled rather than bridged out of the callback with a continuation. The wait is a
        // frame or two, and this keeps "resumed exactly once" a property of one lock instead
        // of careful reasoning about which of a timeout and a 30 Hz callback got there first —
        // a continuation resumed twice is a crash, and dropped is a strip that never appears.
        //
        // The sleep is **not** `try?`, and that is the whole of a bug worth more than the line
        // it took. `Task.sleep` throws immediately once the task is cancelled, so swallowing
        // that error turned this into a spin loop running flat out for the rest of the timeout —
        // on `.userInitiated`, at exactly the moment the task gets cancelled, which is when the
        // shelf is dismissed. Tapping from the filter strip to the censor picker therefore
        // dropped a second of CPU on the floor while the GPU was being handed a new look, and
        // the symptom was a viewfinder that froze and a control that appeared not to work.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let image = box.image { return image }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return box.image
            }
        }
        return box.image
    }

    /// The first frame to arrive, and only the first.
    private final class FirstImage: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGImage?

        var image: CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var isFilled: Bool { image != nil }

        func fill(_ image: CGImage) {
            lock.lock()
            if stored == nil { stored = image }
            lock.unlock()
        }
    }

    /// A frame, downscaled to thumbnail size and oriented upright. Frame-callback only.
    private static func downscale(_ frame: CameraFrame, to maxDimension: CGFloat) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else { return nil }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(extent.width, extent.height))
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let rotationAngle = frame.rotationAngle ?? 90
        image = image.transformed(by: CaptureRotation.imageTransform(degrees: rotationAngle))
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )

        return context.createCGImage(image, from: image.extent)
    }

    /// `CIColorMatrix` takes one vector per output channel plus a bias, which is exactly a 4×4
    /// affine transform read out by rows.
    ///
    /// The alpha coefficient of each colour vector is zero and the bias carries the matrix's
    /// fourth column instead. Leaving the bias in the vectors would multiply it by the pixel's
    /// alpha — invisible on an opaque camera frame, and wrong the first time anything with
    /// transparency goes through here.
    static func parameters(for matrix: simd_float4x4) -> [String: Any] {
        func row(_ index: Int) -> CIVector {
            CIVector(
                x: CGFloat(matrix[0][index]),
                y: CGFloat(matrix[1][index]),
                z: CGFloat(matrix[2][index]),
                w: 0
            )
        }
        return [
            "inputRVector": row(0),
            "inputGVector": row(1),
            "inputBVector": row(2),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(
                x: CGFloat(matrix[3][0]),
                y: CGFloat(matrix[3][1]),
                z: CGFloat(matrix[3][2]),
                w: 0
            )
        ]
    }
}

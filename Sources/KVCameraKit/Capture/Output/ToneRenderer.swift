import CoreImage
import CoreMedia
import Foundation
import simd

/// Applies a look to an image, using the same matrix the viewfinder drew with.
///
/// Two callers, one context, one decision about colour management: the captured still, and the
/// thumbnails on the filter strip. Those thumbnails have to match the look the viewfinder is
/// showing — a strip whose chips disagree with the live preview is worse than no chips — so
/// they come through here rather than through a second Core Image path of their own.
///
/// The interesting part is not the filter, it is the two ways this could have been written and
/// only one of them stays honest. Written as a stack of Core Image filters — `CIColorControls`
/// for saturation and contrast, `CITemperatureAndTint` for warmth, `CIExposureAdjust` for
/// exposure — it would look right today and drift from the shader the first time either side
/// is touched, and the symptom is a photo that does not match the viewfinder it was composed
/// in. So the look is *one matrix*, built in `CameraTone`, and this hands that matrix to
/// `CIColorMatrix` unchanged.
///
/// Two details make the parity real rather than nominal:
///
/// **No colour management.** The context works with `workingColorSpace: NSNull()`, so the
/// matrix multiplies the same gamma-encoded values the shader multiplies. Core Image's default
/// is to convert to linear light first, which is more defensible photographically and would
/// silently make every photo differ from its preview.
///
/// **JPEG out, whatever came in.** Filtering is a re-encode, and a filtered HEIC would need
/// the container rewritten; the extension is reported back so nothing writes a JPEG to disk
/// named `.heic` — the mirror of a bug this camera already had in the other direction.
enum ToneRenderer {

    /// The longest edge of a filter-strip thumbnail, in pixels.
    ///
    /// Small on purpose. This is a chip about 56 pt wide behind a corner radius; the frame it
    /// comes from is 1920x1080, and every filter on the strip renders from it. Downscaling
    /// once, before the looks are applied, is the difference between five cheap renders and
    /// five full-frame ones.
    static let thumbnailMaxDimension: CGFloat = 160

    /// Built once. A `CIContext` carries compiled kernels and a command queue, and stills
    /// arrive one shutter press at a time — rebuilding it per photo was measurable.
    ///
    /// `nonisolated(unsafe)` because `CIContext` is documented as safe to use from multiple
    /// threads, which is the whole reason one shared instance is correct here.
    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    /// The filtered image, or `nil` if the bytes could not be read.
    ///
    /// Returns `nil` rather than the original on failure, deliberately: silently storing an
    /// *unfiltered* photo when the user picked a look is the same class of lie as a preview
    /// that disagrees with the file, and the caller can decide what to do about it.
    static func apply(_ tone: CameraTone, to data: Data, quality: CGFloat = 0.9) -> (data: Data, fileExtension: String)? {
        guard !tone.isNeutral else { return (data, CapturedPhotoDecoder.fileExtension(for: data)) }
        guard let source = CIImage(data: data) else { return nil }

        let matrix = tone.colorMatrix
        let filtered = source.applyingFilter("CIColorMatrix", parameters: Self.parameters(for: matrix))

        // The extent, not the whole plane: a filter output is conceptually infinite, and
        // encoding without saying where to stop produces nothing.
        guard let encoded = context.jpegRepresentation(
            of: filtered.cropped(to: source.extent),
            colorSpace: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { return nil }

        return (encoded, "jpg")
    }

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
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let image = box.image { return image }
            try? await Task.sleep(for: .milliseconds(16))
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

    /// Each look applied to the same base image.
    ///
    /// One render per tone, off the main actor, once when the strip opens — not per frame. A
    /// live-updating thumbnail per filter is what Instagram trained everyone to expect and it
    /// costs a scaled render per filter per frame to decorate a strip that is open for two
    /// seconds, while the viewfinder behind it is already showing the selected look at full
    /// size.
    static func thumbnails(base: CGImage, tones: [CameraTone]) -> [CGImage] {
        let source = CIImage(cgImage: base)
        return tones.map { tone in
            guard !tone.isNeutral else { return base }
            let filtered = source.applyingFilter("CIColorMatrix", parameters: parameters(for: tone.colorMatrix))
            return context.createCGImage(filtered, from: source.extent) ?? base
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

import CoreImage
import CoreMedia
import Foundation

/// A poster frame from a sample buffer, for a recording whose file nobody can read.
///
/// It exists because streaming took away the old source of one. With a file on disk,
/// `AVAssetImageGenerator` produces a poster by decoding the first frame back out of it —
/// but a streamed recording is encrypted by the time it lands, so there is nothing to
/// decode. Taking it on the way *in* costs one JPEG encode at the start of a recording and
/// needs no decode at all.
enum CapturePosterRenderer {

    /// A JPEG of the frame, oriented by the recording's track transform and no larger than
    /// `maxDimension`.
    ///
    /// The transform matters: the recording carries its rotation in the container header, so
    /// a poster taken from raw pixels is sideways exactly where the video is not — and a
    /// library of portrait clips with landscape thumbnails is the sort of wrong that looks
    /// like a layout bug.
    static func jpeg(
        from sampleBuffer: CMSampleBuffer,
        transform: CGAffineTransform,
        maxDimension: CGFloat = 640
    ) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)

        // Scaled before rotating, so the encode works on ~0,3 MP rather than the full frame.
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(source.width, source.height))
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        image = image.transformed(by: transform)
        // A rotation puts the extent's origin negative, and an image whose origin is not at
        // zero encodes as a blank of the same size.
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )

        // Built per call rather than held: this runs once at the start of a recording, and a
        // cached `CIContext` would keep a Metal command queue alive for the lifetime of the
        // camera in exchange for saving a few milliseconds once.
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [
                CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String
                ): 0.85
            ]
        )
    }
}

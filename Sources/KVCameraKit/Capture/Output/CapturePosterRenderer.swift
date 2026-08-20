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

    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    /// A JPEG of the frame, oriented by the recording's track transform and no larger than
    /// `maxDimension`.
    ///
    /// The rotation matters: the recording carries its own in the container header, so a
    /// poster taken from raw pixels is sideways exactly where the video is not — and a library
    /// of portrait clips with landscape thumbnails is the sort of wrong that looks like a
    /// layout bug.
    ///
    /// It takes the **angle**, not the track transform, and that is the fix for a bug this
    /// shipped with: Core Image's y runs up while the track transform's runs down, so handing
    /// this the recorder's matrix turned the poster the opposite way and every video thumbnail
    /// faced 180° away from its own video. `CaptureRotation` is where the two conventions
    /// live now.
    static func jpeg(
        from sampleBuffer: CMSampleBuffer,
        rotationAngle: CGFloat,
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

        image = image.transformed(by: CaptureRotation.imageTransform(degrees: rotationAngle))
        // A rotation puts the extent's origin negative, and an image whose origin is not at
        // zero encodes as a blank of the same size.
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.origin.x, y: -image.extent.origin.y)
        )

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

import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// Turns a captured still plus a quad into a flat page.
///
/// Two steps, and both matter to whether the result reads as a scan or as a photo of a
/// desk: the perspective correction squares up a page shot from an angle, and a
/// conservative tone pass lifts the paper towards white without crushing what is printed
/// on it.
enum DocumentPageRenderer {

    /// One context, reused. `CIContext` allocates a Metal command queue and caches
    /// intermediates; building one per scan throws all of that away and shows up as a
    /// visible pause on the shutter.
    ///
    /// `nonisolated(unsafe)` rather than an actor: `CIContext` is documented as thread-safe,
    /// and wrapping it in an isolation domain would add a hop to a call that already runs
    /// off the main actor.
    private nonisolated(unsafe) static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Loads the captured bytes with their EXIF orientation already applied.
    ///
    /// `CIImage(data:)` on its own ignores the orientation tag, so a page shot in landscape
    /// comes through sideways — and then Vision looks for a document in a rotated image and
    /// the quad it returns describes a rotation nobody asked for. Applying it at load is
    /// what makes every coordinate downstream mean one thing.
    static func orientedImage(from data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    /// Flattens `quad` out of `image`.
    ///
    /// The quad is normalised, so it is scaled against the image's own extent here — never
    /// by the caller, which is how a crop ends up a few percent off.
    static func correctingPerspective(of image: CIImage, to quad: DocumentQuad) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let corners = quad.inImageSpace(of: CGSize(width: extent.width, height: extent.height))

        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgPoint: corners.topLeft), forKey: "inputTopLeft")
        filter?.setValue(CIVector(cgPoint: corners.topRight), forKey: "inputTopRight")
        filter?.setValue(CIVector(cgPoint: corners.bottomLeft), forKey: "inputBottomLeft")
        filter?.setValue(CIVector(cgPoint: corners.bottomRight), forKey: "inputBottomRight")
        return filter?.outputImage
    }

    /// A conservative tone pass.
    ///
    /// Deliberately mild. The temptation with a scanner is to threshold hard towards
    /// black-and-white, which looks superb on a clean printed page under even light and
    /// destroys a receipt, a handwritten note in pencil, or anything photographed in warm
    /// indoor light — and destroys it irreversibly, because the vault keeps what it was
    /// handed. A small contrast lift plus slight desaturation reads as "scanned" while
    /// leaving every pixel recoverable.
    static func enhanced(_ image: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(1.12, forKey: kCIInputContrastKey)
        filter?.setValue(0.03, forKey: kCIInputBrightnessKey)
        filter?.setValue(0.85, forKey: kCIInputSaturationKey)
        return filter?.outputImage ?? image
    }

    /// The whole pass: bytes in, flat page out.
    ///
    /// Returns `nil` rather than falling back to the uncorrected frame. A scanner that
    /// silently hands back a skewed photo of a desk when detection fails teaches the user
    /// that the mode is unreliable without ever saying what went wrong; the caller surfaces
    /// it instead.
    static func render(
        data: Data,
        quad: DocumentQuad,
        enhance: Bool = true,
        compressionQuality: CGFloat = 0.9
    ) -> Data? {
        guard let image = orientedImage(from: data),
              let corrected = correctingPerspective(of: image, to: quad) else { return nil }

        let finished = enhance ? enhanced(corrected) : corrected
        return jpeg(from: finished, compressionQuality: compressionQuality)
    }

    /// Detect and render in one pass, decoding the captured bytes exactly once.
    ///
    /// Detection runs here rather than reusing the quad from the live overlay, and that is a
    /// correctness point rather than an accuracy one: the preview stream and the photo output
    /// can differ in aspect ratio and field of view, so a normalised quad from one does not
    /// describe the same region of the other. The result would look almost right — a scan
    /// cropped a few percent off, every single time.
    static func scan(data: Data, detector: DocumentDetector, enhance: Bool = true) -> Data? {
        guard let image = orientedImage(from: data),
              let quad = detector.detect(in: image),
              let corrected = correctingPerspective(of: image, to: quad) else { return nil }
        return jpeg(from: enhance ? enhanced(corrected) : corrected)
    }

    /// Renders through a `CGImage` rather than `context.jpegRepresentation` because the
    /// latter needs a colour space argument and silently produces nothing for some
    /// filter-chain outputs; going via `CGImage` is the path that behaves the same for
    /// every chain in this file.
    static func jpeg(from image: CIImage, compressionQuality: CGFloat = 0.9) -> Data? {
        guard image.extent.width >= 1, image.extent.height >= 1,
              let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: compressionQuality)
    }
}

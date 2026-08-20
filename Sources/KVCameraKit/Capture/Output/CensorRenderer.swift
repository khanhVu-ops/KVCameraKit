import CoreImage
import CoreMedia
import Foundation
import ImageIO
import Vision

/// The censor, in Core Image, for the two destinations the shader cannot reach: a captured
/// still and a recorded video.
///
/// The viewfinder is a fragment shader (`CameraPreview.metal`) and this is Core Image, which is
/// two implementations of one effect — the arrangement `ToneRenderer` documents at length as
/// the thing to avoid. It is accepted here for the same reason it was there: the geometry, which
/// is the part with the bugs in it, lives in exactly one place (`CensorGeometry`), and what is
/// duplicated is only *how the pixels are averaged*. The numbers that decide where a censor goes
/// have one definition; the numbers that decide what it looks like are asserted to agree by
/// `CameraCensorTests`.
///
/// Every filter runs on a **crop**, and that is not an optimisation detail. The first
/// implementation pixellated and then Gaussian-blurred the entire frame in order to show the
/// result through a rectangular mask — at 4K, twice per frame, to censor something that occupies
/// two percent of the picture.
enum CensorRenderer {

    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    // The four numbers below are duplicated in `CameraPreview.metal`, by necessity — a shader
    // cannot read Swift. They are `internal` rather than `private` so `CameraLookParityTests` can
    // read them back and assert the shader still agrees: the censor's shape drifting between the
    // viewfinder and the file is invisible in a diff and does not fail a build.

    /// Cells across the face, matching `kMosaicCells` in the shader.
    static let mosaicCells: CGFloat = 9
    /// Blur radius as a fraction of the face's semi-axis. Proportional to the face, so the
    /// same look holds at every distance — the shader's tap grid is in the same units for the
    /// same reason.
    static let blurFraction: CGFloat = 0.35
    /// The bar, in the ellipse's own frame, matching `kBarHalfExtent`/`kBarCenterY`. The sign
    /// of the centre is flipped because Core Image's y runs up.
    static let barHalfExtent = CGSize(width: 1.02, height: 0.275)
    static let barCenterY: CGFloat = 0.175
    /// Where the feather starts, matching the shader's `smoothstep(0.86, 1.0, …)`.
    static let featherStart: CGFloat = 0.86

    // MARK: - Rendering

    /// The image with every region censored, in the image's own pixel space.
    ///
    /// `regions` are in normalized sensor-buffer coordinates — see `CensorRegion`. That is the
    /// space `image` is in for all three callers: a video frame is the raw buffer, and a still
    /// is the raw buffer plus an EXIF tag that `CIImage(data:)` deliberately does not apply.
    ///
    /// Both halves, for the video path, which has no grading stage to sit between them.
    static func render(
        image: CIImage,
        mode: CameraCensorMode,
        regions: [CensorRegion]
    ) -> CIImage {
        renderBar(image: renderDestructive(image: image, mode: mode, regions: regions), mode: mode, regions: regions)
    }

    /// Mosaic and blur — the stages that consume the picture's own pixels.
    ///
    /// Split from the bar so a caller with a grading stage can put each on the correct side of
    /// it. These two go **before** tone and the LUT: they are spatial averages, so they have to
    /// read ungraded pixels, and running them first means the censored patch is graded along
    /// with everything around it instead of sitting in the picture as an un-toned rectangle.
    ///
    /// The shader does exactly this, in `applyCensor`. The two used to disagree — the shader
    /// censored before grading and the still path after — and each carried a comment claiming it
    /// matched the other.
    static func renderDestructive(
        image: CIImage,
        mode: CameraCensorMode,
        regions: [CensorRegion]
    ) -> CIImage {
        guard mode == .mosaic || mode == .blur else { return image }
        return reduce(image: image, mode: mode, regions: regions)
    }

    /// The bar — an opaque object placed **on top of** the finished picture.
    ///
    /// After grading, so it is black. Before, a strong preset tinted it: Film Noir produced a
    /// dark grey bar in the viewfinder and a black one in the file, from the same censor mode.
    static func renderBar(
        image: CIImage,
        mode: CameraCensorMode,
        regions: [CensorRegion]
    ) -> CIImage {
        guard mode == .censorBar else { return image }
        return reduce(image: image, mode: mode, regions: regions)
    }

    private static func reduce(
        image: CIImage,
        mode: CameraCensorMode,
        regions: [CensorRegion]
    ) -> CIImage {
        guard !regions.isEmpty else { return image }

        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else { return image }

        var output = image
        for region in regions {
            output = censored(output, region: region, mode: mode, extent: extent)
        }
        return output
    }

    /// The union of the destructive regions, as a white-on-black mask.
    ///
    /// Beauty multiplies its skin mask by the inverse of this. Smoothing or sharpening inside a
    /// censored patch would be sampling detail back into the one region whose entire purpose is
    /// not to have any — the shader avoids it by reading the censor's own coverage value, and
    /// this is the same guard for the Core Image path.
    ///
    /// `nil` when there is nothing to mask, so the caller can skip a composite rather than
    /// blend against a black rectangle.
    static func destructiveCoverageMask(
        mode: CameraCensorMode,
        regions: [CensorRegion],
        extent: CGRect
    ) -> CIImage? {
        guard mode == .mosaic || mode == .blur, !regions.isEmpty else { return nil }
        guard extent.width > 1, extent.height > 1, !extent.isInfinite else { return nil }

        var mask: CIImage?
        for region in regions {
            let ellipse = CensorGeometry.coreImageEllipse(region, in: extent.size)
            let radius = ellipse.radius
            guard radius.width > 1, radius.height > 1 else { continue }
            let placement = CGAffineTransform(rotationAngle: ellipse.roll)
                .concatenating(CGAffineTransform(
                    translationX: ellipse.center.x + extent.minX,
                    y: ellipse.center.y + extent.minY
                ))
            let next = featheredMask(placement: placement, radius: radius)
            // Lighten rather than add: two overlapping faces must not produce a mask brighter
            // than white, which would push the inverse below zero.
            mask = mask.map {
                next.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: $0])
            } ?? next
        }

        return mask?
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .cropped(to: extent)
    }

    private static func censored(
        _ image: CIImage,
        region: CensorRegion,
        mode: CameraCensorMode,
        extent: CGRect
    ) -> CIImage {
        let ellipse = CensorGeometry.coreImageEllipse(region, in: extent.size)
        let center = CGPoint(x: ellipse.center.x + extent.minX, y: ellipse.center.y + extent.minY)
        let radius = ellipse.radius
        guard radius.width > 1, radius.height > 1 else { return image }

        // Rigid: the ellipse's semi-axes are already in pixels, so only the turn and the
        // position are left to apply.
        let placement = CGAffineTransform(rotationAngle: ellipse.roll)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))

        if mode == .censorBar {
            let bar = CGRect(
                x: -barHalfExtent.width * radius.width,
                y: (barCenterY - barHalfExtent.height) * radius.height,
                width: barHalfExtent.width * 2 * radius.width,
                height: barHalfExtent.height * 2 * radius.height
            )
            return CIImage(color: .black)
                .cropped(to: bar)
                .transformed(by: placement)
                .composited(over: image)
                .cropped(to: extent)
        }

        let bounds = CensorGeometry
            .bounds(center: center, radius: radius, roll: ellipse.roll)
            .intersection(extent)
        guard !bounds.isNull, bounds.width > 1, bounds.height > 1 else { return image }

        let effect: CIImage
        switch mode {
        case .mosaic:
            // Anchored on the face and sized from it. Both halves matter: the first
            // implementation anchored the grid at the *image* centre, so the blocks slid
            // across a moving face instead of travelling with it, and derived the cell size
            // from the frame, so a distant face became two blocks and a close one stayed
            // readable.
            let cell = max(2, radius.width * 2 / mosaicCells)
            // Softened *before* the cells are cut, and this is not cosmetic. `CIPixellate`
            // point-samples: each cell takes the colour of one pixel at its centre rather than
            // the mean of the cell. On anything with fine detail that aliases — a striped
            // shirt comes out as stripes of blocks — and for a censor it is worse than ugly,
            // because a point sample carries through more of the original than an average
            // does. A blur of roughly a third of a cell makes the sampled pixel stand for its
            // neighbourhood, which is what a mosaic is supposed to be.
            //
            // The shader does the same thing by averaging a grid inside each cell; it cannot
            // pre-blur, having no second pass to do it in.
            effect = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: cell / 3])
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: cell,
                    kCIInputCenterKey: CIVector(x: center.x, y: center.y)
                ])
                .cropped(to: bounds)

        case .blur:
            // `clampedToExtent` first, or the blur samples nothing beyond the edge and every
            // face near a border gets a dark halo. Core Image is lazy and driven by the region
            // of interest, so cropping the *result* is what keeps this to the face's area
            // rather than the frame's.
            effect = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: max(2, radius.width * blurFraction)
                ])
                .cropped(to: bounds)

        case .off, .censorBar:
            return image
        }

        return effect
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: featheredMask(placement: placement, radius: radius)
            ])
            .cropped(to: extent)
    }

    /// A soft-edged ellipse, as a mask.
    ///
    /// A transformed radial gradient rather than a drawn shape, because that gives the feather
    /// for free and in the right shape. The first implementation composited hard white
    /// rectangles into a black image, which produces a visibly aliased box edge around every
    /// face — and the usual fix for that, blurring the mask, is another full-frame filter.
    private static func featheredMask(placement: CGAffineTransform, radius: CGSize) -> CIImage {
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": featherStart,
            "inputRadius1": 1.0,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ])?.outputImage ?? CIImage(color: .white)

        // Scale turns the unit circle into the ellipse; the placement then rotates and moves
        // it. Composed in that order, so the scale happens in the ellipse's own frame.
        return gradient.transformed(
            by: CGAffineTransform(scaleX: radius.width, y: radius.height).concatenating(placement)
        )
    }

    // MARK: - Detection

    /// The faces in a decoded still, as regions in the decoded image's own space.
    ///
    /// The orientation is the whole content of this function. `CIImage(data:)` documents that it
    /// leaves the orientation metadata *unapplied*, so the decoded pixels are the sensor's —
    /// landscape, whichever way the phone was held. Handing those to Vision as `.up`, which the
    /// first implementation did, asks a face detector to find faces lying on their side: it
    /// mostly returns nothing, and what it does return is placed in a space nobody is drawing in.
    static func regions(in image: CIImage) -> [CensorRegion] {
        let orientation = decodedOrientation(of: image)
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3

        let handler = VNImageRequestHandler(ciImage: image, orientation: orientation, options: [:])
        try? handler.perform([request])

        let sensorSize = image.extent.size
        let degrees = CensorGeometry.rotationDegrees(for: orientation)

        return (request.results ?? []).enumerated().map { index, observation in
            CensorGeometry.region(
                visionBox: observation.boundingBox,
                visionRoll: CGFloat(truncating: observation.roll ?? 0),
                id: index,
                sensorSize: sensorSize,
                rotationDegrees: degrees
            )
        }
    }

    /// The orientation tag the decode left in place.
    private static func decodedOrientation(of image: CIImage) -> CGImagePropertyOrientation {
        let raw = image.properties[kCGImagePropertyOrientation as String] as? UInt32
        return raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
    }

    // MARK: - Stills

    /// Applies the censor to captured photo bytes.
    ///
    /// Decode and encode are deliberately untouched from what `ToneRenderer` does: `CIImage(data:)`
    /// keeps the orientation tag, `jpegRepresentation` writes the image's properties back, and the
    /// still therefore comes out the same way up as it went in. Only *where the censor lands*
    /// changed.
    static func apply(
        _ mode: CameraCensorMode,
        to data: Data,
        quality: CGFloat = 0.9
    ) -> (data: Data, fileExtension: String)? {
        guard mode.isEnabled else {
            return (data, CapturedPhotoDecoder.fileExtension(for: data))
        }
        guard let source = CIImage(data: data) else { return nil }

        // A still with no face in it is returned untouched rather than re-encoded. Re-encoding
        // costs a generation of JPEG quality to achieve nothing, and it would turn an HEIC into
        // a JPEG for no reason.
        let faces = regions(in: source)
        guard !faces.isEmpty else {
            return (data, CapturedPhotoDecoder.fileExtension(for: data))
        }

        let censored = render(image: source, mode: mode, regions: faces)

        guard let encoded = context.jpegRepresentation(
            of: censored.cropped(to: source.extent),
            colorSpace: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [
                CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String
                ): quality
            ]
        ) else { return nil }

        return (encoded, "jpg")
    }
}

import CoreImage
import Foundation

/// GPU-backed Core Image counterparts of the live Metal face warps.
///
/// Every built-in distortion is bounded to a face-sized radius. Core Image evaluates lazily,
/// so the still and recording paths do not allocate or shade a second full-resolution image
/// for each detected face. The preview performs the same family of inverse warps directly in
/// `CameraPreview.metal` and never leaves its existing look pass.
enum FaceEffectRenderer {

    static func render(
        image: CIImage,
        effect: CameraFaceEffect,
        regions: [CensorRegion]
    ) -> CIImage {
        guard effect.isEnabled, !regions.isEmpty else { return image }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, !extent.isInfinite else { return image }

        var output = image
        for region in regions {
            let ellipse = CensorGeometry.coreImageEllipse(region, in: extent.size)
            let center = CGPoint(
                x: ellipse.center.x + extent.minX,
                y: ellipse.center.y + extent.minY
            )
            guard ellipse.radius.width > 2, ellipse.radius.height > 2 else { continue }

            let input = output
            let crop = renderBounds(
                center: center,
                radius: ellipse.radius,
                roll: ellipse.roll,
                extent: extent
            )
            guard crop.width > 1, crop.height > 1 else { continue }

            var warped = output
            switch effect {
            case .off:
                break

            case .bigEyes:
                // Landmark detection would add a second, materially slower Vision request.
                // Stable eye anchors inferred from the already padded/rolled face ellipse give
                // the familiar effect while reusing the privacy detector's one observation.
                let eyeRadius = max(4, min(ellipse.radius.width, ellipse.radius.height) * 0.34)
                warped = bump(
                    warped,
                    center: point(x: -0.32, y: 0.18, ellipse: ellipse, center: center),
                    radius: eyeRadius,
                    scale: 0.52
                )
                warped = bump(
                    warped,
                    center: point(x: 0.32, y: 0.18, ellipse: ellipse, center: center),
                    radius: eyeRadius,
                    scale: 0.52
                )

            case .slimFace:
                warped = warped.applyingFilter("CIPinchDistortion", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: center),
                    kCIInputRadiusKey: max(ellipse.radius.width, ellipse.radius.height),
                    kCIInputScaleKey: 0.32
                ])

            case .funhouse:
                warped = bump(
                    warped,
                    center: center,
                    radius: max(ellipse.radius.width, ellipse.radius.height),
                    scale: 0.48
                )
            }

            // Some Core Image distortion filters advertise the input's infinite region of
            // interest even though their visible radius is finite. An explicit soft ellipse
            // is the contract: a face effect must never pull pixels from a frame corner.
            if effect.isEnabled {
                let patch = warped.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: input,
                    kCIInputMaskImageKey: faceMask(
                        center: center,
                        radius: ellipse.radius,
                        roll: ellipse.roll
                    )
                ])
                // Bounding the patch is the recording-path performance contract. Without it,
                // Core Image asks every distortion node to shade the complete 4K frame even
                // though the visible result occupies only a face. The compositor now requests
                // pixels solely inside this rolled ellipse's axis-aligned bounds.
                output = patch.cropped(to: crop).composited(over: input).cropped(to: extent)
            }
        }
        return output.cropped(to: extent)
    }

    private static func bump(
        _ image: CIImage,
        center: CGPoint,
        radius: CGFloat,
        scale: CGFloat
    ) -> CIImage {
        image.applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: center),
            kCIInputRadiusKey: radius,
            kCIInputScaleKey: scale
        ])
    }

    private static func faceMask(center: CGPoint, radius: CGSize, roll: CGFloat) -> CIImage {
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": 0.82,
            "inputRadius1": 1.0,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear
        ])?.outputImage ?? CIImage(color: .clear)
        let placement = CGAffineTransform(scaleX: radius.width, y: radius.height)
            .concatenating(CGAffineTransform(rotationAngle: roll))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return gradient.transformed(by: placement)
    }

    /// Axis-aligned bounds of a rolled ellipse, with enough guard space for the distortion's
    /// edge samples. Keeping this finite lets Core Image propagate a small region of interest
    /// through the graph instead of evaluating the whole camera buffer for every face.
    private static func renderBounds(
        center: CGPoint,
        radius: CGSize,
        roll: CGFloat,
        extent: CGRect
    ) -> CGRect {
        let cosine = abs(cos(roll))
        let sine = abs(sin(roll))
        let guardScale: CGFloat = 1.08
        let halfWidth = (radius.width * cosine + radius.height * sine) * guardScale
        let halfHeight = (radius.width * sine + radius.height * cosine) * guardScale
        return CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2
        ).intersection(extent)
    }

    /// A point in the rolled face's local frame, converted to Core Image pixels.
    private static func point(
        x: CGFloat,
        y: CGFloat,
        ellipse: (center: CGPoint, radius: CGSize, roll: CGFloat),
        center: CGPoint
    ) -> CGPoint {
        let localX = x * ellipse.radius.width
        let localY = y * ellipse.radius.height
        let cosine = cos(ellipse.roll)
        let sine = sin(ellipse.roll)
        return CGPoint(
            x: center.x + localX * cosine - localY * sine,
            y: center.y + localX * sine + localY * cosine
        )
    }
}

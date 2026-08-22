import CoreGraphics
import Foundation
import ImageIO

/// The arithmetic between Vision's coordinate space and `CensorRegion`'s, and nothing else.
///
/// Static and pure, for the same reason `CameraPreviewRenderer.transform` is: every one of
/// these conversions has a plausible-looking wrong version, and "the censor is 90° out" is not
/// something a unit test should need a camera — or a face — to catch. Each function here is
/// asserted against a hand-computed value in `CameraCensorTests`.
enum CensorGeometry {

    // MARK: - Padding

    /// How much wider than Vision's box the ellipse is.
    ///
    /// `VNFaceObservation.boundingBox` is tight: it runs roughly from the eyebrows to just
    /// below the chin and stops at the cheeks. It contains no hair, no ears and no jawline, so
    /// a censor drawn on it exactly leaves the top of the head and both ears uncovered — which
    /// is most of what makes someone recognisable at a glance.
    ///
    /// The vertical figure is larger than the horizontal one and the centre moves *up*,
    /// because the missing region is not symmetric: there is a whole skull above the eyebrows
    /// and only a chin below them.
    static let widthScale: CGFloat = 1.52
    static let heightScale: CGFloat = 1.78
    /// Upward shift of the centre, as a fraction of Vision's box height. Up is **minus** here.
    static let upwardBias: CGFloat = 0.14

    // MARK: - Vision's orientation

    /// The orientation to hand `VNImageRequestHandler` so that faces arrive upright.
    ///
    /// This is the fix for the single worst bug in the first censor implementation, which
    /// passed `.up` unconditionally. A sensor buffer is landscape whatever way the phone is
    /// held, so in portrait every face in it is lying on its side — and a face detector given
    /// a sideways face does not politely return a sideways box, it mostly returns nothing, and
    /// returns something wrong when it does.
    ///
    /// `CGImagePropertyOrientation` describes the turn needed **to display** the buffer, which
    /// is exactly the clockwise angle AVFoundation reports. `.right` is EXIF 6, "rotate 90°
    /// clockwise to display" — the portrait rear camera.
    static func visionOrientation(rotationDegrees: CGFloat) -> CGImagePropertyOrientation {
        switch quarterTurns(rotationDegrees) {
        case 1:  return .right
        case 2:  return .down
        case 3:  return .left
        default: return .up
        }
    }

    /// The clockwise turn an orientation tag prescribes — the inverse of `visionOrientation`.
    ///
    /// Needed by the still path, where the rotation is not reported by AVFoundation but written
    /// into the file as EXIF and left there by `CIImage(data:)`.
    ///
    /// The four mirrored tags are folded onto their unmirrored rotations. AVFoundation does not
    /// write them — a front-camera still is stored unmirrored with a plain 1/3/6/8 — so this is
    /// the branch that never runs on a capture from this app, and treating it as exact would be
    /// claiming a correctness nothing here has ever exercised.
    static func rotationDegrees(for orientation: CGImagePropertyOrientation) -> CGFloat {
        switch orientation {
        case .up, .upMirrored:          return 0
        case .right, .rightMirrored:    return 90
        case .down, .downMirrored:      return 180
        case .left, .leftMirrored:      return 270
        @unknown default:               return 0
        }
    }

    // MARK: - Vision → CensorRegion

    /// One face, converted the whole way: Vision's normalized box in the **upright** image
    /// with y **up**, to a padded ellipse in the **sensor buffer** with y **down**.
    ///
    /// Both halves are here rather than exposed separately because the intermediate value —
    /// a region in upright space — is not a thing any consumer wants, and leaving it callable
    /// invites somebody to consume it.
    static func region(
        visionBox: CGRect,
        visionRoll: CGFloat,
        id: Int,
        sensorSize: CGSize,
        rotationDegrees: CGFloat
    ) -> CensorRegion {
        let upright = uprightRegion(
            visionBox: visionBox,
            visionRoll: visionRoll,
            id: id,
            uprightSize: uprightSize(sensorSize: sensorSize, rotationDegrees: rotationDegrees)
        )
        return sensorRegion(
            fromUpright: upright,
            rotationDegrees: rotationDegrees,
            sensorSize: sensorSize
        )
    }

    /// The padded ellipse, still in the upright image's space.
    static func uprightRegion(
        visionBox box: CGRect,
        visionRoll: CGFloat,
        id: Int,
        uprightSize: CGSize
    ) -> CensorRegion {
        // Vision's origin is bottom-left and y runs up; ours is top-left and y runs down. The
        // flip is on the centre only — a height is a height in either convention.
        let centerX = box.midX
        let centerY = 1 - box.midY

        let paddedWidth = box.width * widthScale
        let paddedHeight = box.height * heightScale

        // Up is minus. Shifting *down* here is the version of this line that covers the neck
        // and leaves the hair, and it looks almost right in a preview of a bald subject.
        let biasedY = centerY - box.height * upwardBias

        // Both semi-axes are divided by the **width**, per `CensorRegion.radius`: the vertical
        // fraction is a fraction of the height, so it is rescaled into width units by the
        // aspect ratio rather than used as-is.
        let aspect = uprightSize.width > 0 ? uprightSize.height / uprightSize.width : 1

        return CensorRegion(
            id: id,
            center: CGPoint(x: centerX, y: biasedY),
            radius: CGSize(
                width: paddedWidth / 2,
                height: paddedHeight * aspect / 2
            ),
            // Vision's roll is in its own y-up space, so the same physical tilt is the
            // opposite sign here — the `CaptureRotation` lesson, applied to an angle that
            // arrives from Vision instead of from AVFoundation.
            roll: -visionRoll
        )
    }

    /// Undoes the rotation that made the buffer upright, putting the region back into the
    /// space the pixels actually live in.
    ///
    /// Every consumer works in sensor space — the Metal viewfinder samples the raw texture, the
    /// recorder appends raw samples with rotation carried as a track transform, and a captured
    /// still is raw sensor pixels with an EXIF tag. So this is where the turn is paid for, once.
    static func sensorRegion(
        fromUpright upright: CensorRegion,
        rotationDegrees: CGFloat,
        sensorSize: CGSize
    ) -> CensorRegion {
        let turns = quarterTurns(rotationDegrees)
        let u = upright.center.x
        let v = upright.center.y

        // The forward turn (sensor → upright) is clockwise in this y-down space, which for a
        // quarter turn sends the buffer's top-left corner to the upright image's top-*right*.
        // These are its inverse.
        let center: CGPoint
        switch turns {
        case 1:  center = CGPoint(x: v, y: 1 - u)
        case 2:  center = CGPoint(x: 1 - u, y: 1 - v)
        case 3:  center = CGPoint(x: 1 - v, y: u)
        default: center = CGPoint(x: u, y: v)
        }

        // A rotation is rigid in *pixels*, so the semi-axes only swap. They still have to be
        // renormalized, because both are expressed as a fraction of the width and a quarter
        // turn is precisely the case where the width changes.
        let radius: CGSize
        if turns == 1 || turns == 3 {
            let uprightWidth = sensorSize.height
            let scale = sensorSize.width > 0 ? uprightWidth / sensorSize.width : 1
            radius = CGSize(
                width: upright.radius.height * scale,
                height: upright.radius.width * scale
            )
        } else {
            radius = upright.radius
        }

        return CensorRegion(
            id: upright.id,
            center: center,
            radius: radius,
            roll: upright.roll - CGFloat(turns) * .pi / 2
        )
    }

    /// The upright image's pixel dimensions — the buffer's, with the axes swapped on a
    /// quarter turn.
    static func uprightSize(sensorSize: CGSize, rotationDegrees: CGFloat) -> CGSize {
        let turns = quarterTurns(rotationDegrees)
        return turns == 1 || turns == 3
            ? CGSize(width: sensorSize.height, height: sensorSize.width)
            : sensorSize
    }

    // MARK: - CensorRegion → pixels

    /// The region as a Core Image ellipse: pixel units, origin bottom-left, y **up**.
    ///
    /// Named after the space rather than after the caller, following `CaptureRotation`. Core
    /// Image is the one consumer whose y runs the other way, and a function called
    /// `pixelEllipse` would be used by the Metal path too, where it is 180° wrong.
    static func coreImageEllipse(
        _ region: CensorRegion,
        in pixelSize: CGSize
    ) -> (center: CGPoint, radius: CGSize, roll: CGFloat) {
        (
            center: CGPoint(
                x: region.center.x * pixelSize.width,
                y: (1 - region.center.y) * pixelSize.height
            ),
            radius: CGSize(
                width: region.radius.width * pixelSize.width,
                height: region.radius.height * pixelSize.width
            ),
            // y flips, so the turn does too.
            roll: -region.roll
        )
    }

    /// The axis-aligned bounds of the rotated ellipse, in the same space as the ellipse.
    ///
    /// This is what makes the renderers cheap: a censor is a few percent of the frame, so every
    /// filter runs on this crop instead of on the whole image. The first implementation
    /// pixellated and blurred entire 4K frames to show two faces.
    static func bounds(
        center: CGPoint,
        radius: CGSize,
        roll: CGFloat,
        inflatedBy inflation: CGFloat = 1
    ) -> CGRect {
        let cosine = cos(roll)
        let sine = sin(roll)
        // The extent of a rotated ellipse, exactly: the support function of the ellipse along
        // each axis. Using `max(rx, ry)` instead is the version that clips a tilted face.
        let halfWidth = ((radius.width * cosine) * (radius.width * cosine)
            + (radius.height * sine) * (radius.height * sine)).squareRoot()
        let halfHeight = ((radius.width * sine) * (radius.width * sine)
            + (radius.height * cosine) * (radius.height * cosine)).squareRoot()
        return CGRect(
            x: center.x - halfWidth * inflation,
            y: center.y - halfHeight * inflation,
            width: halfWidth * 2 * inflation,
            height: halfHeight * 2 * inflation
        )
    }

    // MARK: - Helpers

    /// The rotation as a whole number of quarter turns, 0…3.
    ///
    /// AVFoundation only ever reports 0, 90, 180 or 270 here — `videoRotationAngle` refuses
    /// anything else — but rounding rather than trusting that keeps a stray 89.9 from
    /// selecting the wrong branch of four.
    static func quarterTurns(_ degrees: CGFloat) -> Int {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return Int((normalized / 90).rounded()) % 4
    }
}

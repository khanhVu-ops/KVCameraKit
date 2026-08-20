import CoreGraphics
import UIKit

/// One rotation, two coordinate spaces — and the trap that has now produced three bugs.
///
/// AVFoundation reports rotation as a single number of degrees, and that number is expressed
/// in the *image's* coordinate space, where y runs **down**. Half the things that consume it
/// live in that space and half do not:
///
/// | Consumer | y | Wants |
/// |---|---|---|
/// | `AVAssetWriterInput.transform` (video track) | down | `trackTransform` |
/// | `AVCaptureConnection.videoRotationAngle` | down | the angle unchanged |
/// | Core Image (`CIImage.transformed`) | **up** | `imageTransform` |
/// | Metal clip space | **up** | `clipSpaceRadians` |
///
/// Using the wrong one is never subtly wrong — it is exactly 180° wrong, which fills the
/// frame correctly and looks like a rotation that was applied, because it was. Both of those
/// shipped: an upside-down Metal viewfinder, and a video thumbnail facing the opposite way
/// from the video it belongs to.
///
/// So the two live here, named after the space they belong to rather than after the caller
/// that happened to need them first.
enum CaptureRotation {

    /// For a video track's `preferredTransform`, or anything else in the image's y-down space.
    ///
    /// The angle goes in unchanged: this *is* AVFoundation's convention. A quarter turn here
    /// is `[0, 1, -1, 0]`, which is what a portrait recording carries in its header.
    static func trackTransform(degrees: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }

    /// For Core Image, whose origin is bottom-left and whose y runs up.
    ///
    /// Negated, and that is the whole content of this type: the same physical turn, described
    /// in a space whose y points the other way, is the opposite sign.
    static func imageTransform(degrees: CGFloat) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: -degrees * .pi / 180)
    }

    /// For Metal clip space, which also has y up.
    static func clipSpaceRadians(degrees: CGFloat) -> Float {
        Float(-degrees * .pi / 180)
    }

    /// The angle that makes a camera buffer upright *in the interface the user is holding*.
    ///
    /// Not the same question as "which way is gravity", and that difference is a bug this
    /// screen had: the Metal preview was fed `videoRotationAngleForHorizonLevelCapture`, which
    /// is the angle that keeps a **captured file** level with the horizon and therefore tracks
    /// the device as it turns. Applied to a preview whose own view has *already* been rotated
    /// by UIKit, it turns the picture a second time — so rotating the phone spun the image
    /// inside the frame, which is not what the system camera does.
    ///
    /// The sensor is bolted to the phone, so the compensation a preview needs depends only on
    /// where the interface is now:
    ///
    /// ```text
    /// compensation = 90° − (how far the interface has turned from portrait)
    /// ```
    ///
    /// Portrait is the anchor at 90°, which is the case a device confirmed: with the turn
    /// going the right way, a portrait preview is upright.
    static func previewAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        // How far UIKit has already turned the interface, clockwise from portrait. Note
        // `landscapeLeft` holds the home button on the *right* — `UIInterfaceOrientation` is
        // the mirror of `UIDeviceOrientation` here, and mixing the two swaps both landscapes.
        let interfaceTurn: CGFloat
        switch orientation {
        case .portrait:             interfaceTurn = 0
        case .landscapeRight:       interfaceTurn = 90
        case .portraitUpsideDown:   interfaceTurn = 180
        case .landscapeLeft:        interfaceTurn = 270
        case .unknown:              interfaceTurn = 0
        @unknown default:           interfaceTurn = 0
        }
        return (90 - interfaceTurn + 360).truncatingRemainder(dividingBy: 360)
    }
}

import CoreGraphics
import Foundation

/// Where a censor effect goes, in **one** coordinate space, defined once.
///
/// The space is the whole point of this type existing, so it is stated before anything else:
///
/// > Normalized against the **sensor buffer as it is delivered**, origin **top-left**, y runs
/// > **down**. Not the upright image, not the screen, not Vision's space.
///
/// Every consumer wants exactly that space and no other. The Metal viewfinder's `texCoord` *is*
/// this space. `AssetWriterRecorder` appends unrotated sensor pixels and bakes rotation as a
/// track transform, so it is this space. A captured still is sensor pixels plus an EXIF tag, so
/// it is this space too. The only producer that disagrees is Vision, which reports normalized
/// boxes in the *upright* image with y **up** — so the conversion happens once, at the
/// detector, in `CensorGeometry`, and nothing downstream converts anything.
///
/// That asymmetry is deliberate and it is the lesson from `CaptureRotation`: the same rotation
/// described in two y-conventions is not subtly different, it is exactly 180° wrong, and 180°
/// wrong fills the frame correctly and looks like a rotation that was applied. Three bugs in
/// this package came from that. So there is one conversion site rather than one per consumer.
///
/// ### Why an ellipse and not a rect
///
/// A face is an oval, and an axis-aligned rectangle around a tilted head either misses the
/// chin or covers a quarter of the shoulder. An ellipse with a roll costs the same to test per
/// pixel (one dot product) and gives a soft edge for free — `smoothstep` on the ellipse
/// distance, instead of blurring a mask image to hide an aliased rectangle.
public struct CensorRegion: Equatable, Sendable {

    /// Stable across frames for as long as the tracker keeps seeing the same face. Not an
    /// array index: Vision reorders its observations between frames, and an index-keyed region
    /// makes two faces swap identities — which, once smoothing is involved, animates one
    /// censor blob across the frame through everything in between.
    public var id: Int

    /// Normalized sensor-buffer coordinates, origin top-left, y down.
    public var center: CGPoint

    /// Semi-axes of the ellipse, **both normalized against the buffer's width**.
    ///
    /// Both against width, deliberately. Camera pixels are square, so normalizing each axis
    /// against its own dimension would make a circle in pixels into an ellipse in this space,
    /// and `roll` would then no longer be a rigid rotation — a tilted face would come out
    /// sheared. One divisor keeps the space isotropic and keeps the rotation honest.
    public var radius: CGSize

    /// Radians, **clockwise**, in this type's y-down space.
    ///
    /// Clockwise-positive is what a positive `CGAffineTransform(rotationAngle:)` does in a
    /// y-down space, which is the convention `CaptureRotation.trackTransform` already
    /// establishes for this package. Vision reports roll in a y-up space, so the detector
    /// negates it.
    public var roll: CGFloat

    public init(id: Int, center: CGPoint, radius: CGSize, roll: CGFloat) {
        self.id = id
        self.center = center
        self.radius = radius
        self.roll = roll
    }
}

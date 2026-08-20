import CoreGraphics
import Foundation

/// Texture layered over a film LUT.
///
/// Colour lives in the LUT. Grain and light leaks are spatial effects, so keeping them here
/// prevents a preset from pretending a colour cube can encode position-dependent texture.
///
/// The two constants below are the reason this type has more in it than two floats. Both the
/// fragment shader and the Core Image path have to place these effects, and they were placing
/// them differently — the same preset produced one grain in the viewfinder and a seven-times
/// coarser one on the filter-strip chip beside it, and put the light leak on two different
/// edges of the frame. Numbers that both sides must agree on live here, once, and
/// `CameraFilmParityTests` asserts they do.
public struct CameraFilmSimulation: Equatable, Sendable {
    public let grain: Float
    public let lightLeak: Float

    public static let none = CameraFilmSimulation()

    public init(grain: Float = 0, lightLeak: Float = 0) {
        self.grain = min(max(grain, 0), 1)
        self.lightLeak = min(max(lightLeak, 0), 1)
    }

    public var isEnabled: Bool { grain > 0.001 || lightLeak > 0.001 }

    // MARK: - Parity constants

    /// Grain cells across the **height of the upright image**.
    ///
    /// A count per image, not a size in pixels, and that is what makes one preset look like one
    /// film stock in the viewfinder, on a chip and in the saved file. Grain used to be hashed
    /// per *source* pixel in the shader and per *thumbnail* pixel in Core Image: at 1080 lines
    /// the viewfinder's grain was finer than the upscale to the screen could carry and vanished,
    /// while a 160 px chip showed grain seven times coarser than the photo would have. Same
    /// number, same preset, two unrelated textures.
    ///
    /// Duplicated as `kGrainCellsAcrossHeight` in `CameraPreview.metal`, which is the one place
    /// a constant is allowed to appear twice here — a shader cannot read this.
    public static let grainCellsAcrossHeight: CGFloat = 320

    /// Grain amplitude at `grain == 1`, as a fraction of full range. Matches the shader.
    static let grainAmplitude: CGFloat = 0.095

    /// The light leak's centre, in the **upright** image's normalised space with y running down.
    ///
    /// Outside the frame on purpose: a leak is light entering at the edge of the gate, so its
    /// bright core sits just off the picture and only the falloff is visible. Fixed rather than
    /// animated — an earlier version drifted the vertical position with the frame's timestamp,
    /// which made the leak swim around the viewfinder and guaranteed no still could ever match
    /// what the user had framed.
    static let lightLeakCenter = CGPoint(x: 1.03, y: 0.22)
    /// Inner and outer radius of the leak, in units of the image **width**.
    static let lightLeakInnerRadius: CGFloat = 0.05
    static let lightLeakOuterRadius: CGFloat = 0.72
    /// Leak alpha at `lightLeak == 1`, and its colour. Screen-blended in both paths.
    static let lightLeakAlpha: CGFloat = 0.50
    static let lightLeakColor = (red: CGFloat(1.0), green: CGFloat(0.42), blue: CGFloat(0.12))

    /// The size of one grain cell in pixels, for an image of this height.
    ///
    /// Fractional on purpose: rounding to whole pixels would make grain change scale in jumps as
    /// the render size changes, so a chip and a still would land on different cell sizes.
    ///
    /// Square cells, which is why the Core Image path needs no rotation for grain — a square is
    /// the same square whichever way the buffer is lying.
    static func grainCellSize(uprightHeight: CGFloat) -> CGFloat {
        max(uprightHeight / grainCellsAcrossHeight, 1)
    }

    /// The leak's centre in normalised **sensor-buffer** coordinates, origin top-left, y down.
    ///
    /// `lightLeakCenter` is stated in the *upright* image, because that is the frame a person
    /// sees and the frame a preset is designed against. Core Image renders a still in sensor
    /// space — a landscape buffer plus an EXIF tag, however the phone was held — so the centre
    /// has to be turned to match, and only the centre: the gradient is radially symmetric, so
    /// nothing else about it cares which way up the buffer is.
    ///
    /// The forward turn here is the same one `CensorGeometry.sensorRegion` applies, and for the
    /// same reason. Two turns that must agree, both derived from `quarterTurns`.
    static func lightLeakCenterInSensorSpace(rotationDegrees: CGFloat) -> CGPoint {
        sensorPoint(upright: lightLeakCenter, rotationDegrees: rotationDegrees)
    }

    /// A point in the upright image, in the buffer's own normalised space.
    ///
    /// Separate from the leak so `CameraLookParityTests` can assert it is the exact inverse of
    /// `CameraPreviewRenderer.uprightRotation`. Those two turns describe the same relationship —
    /// buffer to picture — from opposite ends, and nothing else would catch them disagreeing: the
    /// symptom is film texture and face geometry using different ideas of "up", and only one of
    /// them is visible enough to notice.
    static func sensorPoint(upright: CGPoint, rotationDegrees: CGFloat) -> CGPoint {
        let u = upright.x
        let v = upright.y
        switch CensorGeometry.quarterTurns(rotationDegrees) {
        case 1:  return CGPoint(x: v, y: 1 - u)
        case 2:  return CGPoint(x: 1 - u, y: 1 - v)
        case 3:  return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }
}

import CoreGraphics
import Foundation

/// Texture layered over a film LUT.
///
/// Colour lives in the LUT. Grain and light leaks are spatial effects, so keeping them here
/// prevents a preset from pretending a colour cube can encode position-dependent texture.
///
/// The constants and shared emulsion tile below are why this type has more in it than two floats. Both the
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
    /// Duplicated with the other scalar response constants in `CameraPreview.metal`, because a
    /// shader cannot read Swift values. Parity tests pin every duplicate; the texture itself is
    /// not duplicated and is uploaded directly from `grainTileBytes`.
    public static let grainCellsAcrossHeight: CGFloat = 220

    /// Grain amplitude at `grain == 1`, as a fraction of full range. Matches the shader.
    static let grainAmplitude: CGFloat = 0.075

    /// The deterministic dye-cloud field sampled by every renderer.
    ///
    /// Core Image used to invent its texture with `CIRandomGenerator`, while Metal evaluated a
    /// different sine hash. Even equal frequency and strength cannot make two unrelated random
    /// fields look alike. This tile is the single source now: Core Image repeats it directly and
    /// the live renderer uploads these same bytes as an `r8Unorm` texture.
    static let grainTileCells: Int = 128
    static let grainTexelsPerCell: Int = 4
    static let grainTileDimension: Int = grainTileCells * grainTexelsPerCell
    static let grainTileBytes: [UInt8] = makeGrainTile()

    /// Midtone density response shared with the shader.
    static let grainShadowStart: CGFloat = 0.03
    static let grainShadowFull: CGFloat = 0.22
    static let grainHighlightStart: CGFloat = 0.65
    static let grainHighlightEnd: CGFloat = 0.90

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

    /// A stable offset into the shared tile. A still and its shelf chip use the same seed; live
    /// video changes seed in quantised steps so the emulsion re-rolls instead of sliding.
    static func grainTileOffset(seed: Float) -> CGPoint {
        CGPoint(
            x: CGFloat(fraction(seed * 0.754_877_7)) * CGFloat(grainTileDimension),
            y: CGFloat(fraction(seed * 0.569_840_3)) * CGFloat(grainTileDimension)
        )
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

    // MARK: - Shared emulsion tile

    /// Two periodic value-noise octaves approximate overlapping dye clouds. Periodicity is not
    /// optional: both GPU samplers repeat this texture, and a non-periodic edge becomes a faint
    /// grid over flat skies. Sampling the same baked bytes also removes floating-point `sin`
    /// differences between Core Image and Metal devices.
    private static func makeGrainTile() -> [UInt8] {
        let dimension = grainTileDimension
        let texelsPerCell = Float(grainTexelsPerCell)
        var bytes = [UInt8](repeating: 0, count: dimension * dimension)

        for y in 0..<dimension {
            for x in 0..<dimension {
                let point = SIMD2<Float>(Float(x) / texelsPerCell, Float(y) / texelsPerCell)
                let broad = periodicValueNoise(point, period: grainTileCells)
                let fine = periodicValueNoise(
                    point * 2 + SIMD2<Float>(13.7, 31.9),
                    period: grainTileCells * 2
                )
                let value = min(max(broad * 0.68 + fine * 0.32, 0), 1)
                bytes[y * dimension + x] = UInt8((value * 255).rounded())
            }
        }
        return bytes
    }

    private static func periodicValueNoise(_ point: SIMD2<Float>, period: Int) -> Float {
        let ix = Int(floor(point.x))
        let iy = Int(floor(point.y))
        let fraction = SIMD2<Float>(point.x - floor(point.x), point.y - floor(point.y))
        let smooth = fraction * fraction * (SIMD2<Float>(repeating: 3) - 2 * fraction)

        let a = periodicHash(x: ix, y: iy, period: period)
        let b = periodicHash(x: ix + 1, y: iy, period: period)
        let c = periodicHash(x: ix, y: iy + 1, period: period)
        let d = periodicHash(x: ix + 1, y: iy + 1, period: period)
        return mix(mix(a, b, smooth.x), mix(c, d, smooth.x), smooth.y)
    }

    private static func periodicHash(x: Int, y: Int, period: Int) -> Float {
        let wrappedX = positiveModulo(x, period)
        let wrappedY = positiveModulo(y, period)
        var value = UInt32(truncatingIfNeeded: wrappedX &* 0x1f123bb5)
        value ^= UInt32(truncatingIfNeeded: wrappedY &* 0x5f356495)
        value ^= value >> 16
        value &*= 0x7feb352d
        value ^= value >> 15
        value &*= 0x846ca68b
        value ^= value >> 16
        return Float(value & 0x00ff_ffff) / Float(0x0100_0000)
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private static func fraction(_ value: Float) -> Float {
        value - floor(value)
    }
}

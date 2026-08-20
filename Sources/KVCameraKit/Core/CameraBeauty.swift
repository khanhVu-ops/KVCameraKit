import Foundation
import simd

/// Skin-aware retouching that composes with every camera look.
///
/// Kept separate from `CameraFilter` so beauty composes with every style, LUT and film
/// preset instead of becoming a second set of nearly identical presets. Every adjustment is
/// normalized to `0...1`, so the host can persist this value without knowing how either
/// renderer implements it.
public struct CameraBeauty: Equatable, Sendable {

    public var smoothing: Float
    public var brightness: Float
    public var rosy: Float
    public var definition: Float

    public static let off = CameraBeauty()

    /// Backwards-compatible name for the original one-slider beauty control.
    public var intensity: Float {
        get { smoothing }
        set { smoothing = Self.clamp(newValue) }
    }

    public init(
        smoothing: Float = 0,
        brightness: Float = 0,
        rosy: Float = 0,
        definition: Float = 0
    ) {
        self.smoothing = Self.clamp(smoothing)
        self.brightness = Self.clamp(brightness)
        self.rosy = Self.clamp(rosy)
        self.definition = Self.clamp(definition)
    }

    public init(intensity: Float) {
        self.init(smoothing: intensity)
    }

    public var isEnabled: Bool {
        smoothing > 0.001 || brightness > 0.001 || rosy > 0.001 || definition > 0.001
    }

    /// A YCbCr skin-chrominance gate shared by the preview and still mask generator.
    ///
    /// The edges are deliberately soft. A binary skin mask produces a visible border where
    /// smoothing stops, especially across cheeks and foreheads under mixed light.
    static func skinWeight(_ rgb: SIMD3<Float>) -> Float {
        let colour = simd_clamp(rgb, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        let luma = simd_dot(colour, SIMD3<Float>(0.299, 0.587, 0.114))
        let cb = -0.168736 * colour.x - 0.331264 * colour.y + 0.5 * colour.z + 0.5
        let cr = 0.5 * colour.x - 0.418688 * colour.y - 0.081312 * colour.z + 0.5

        let chroma = smoothBand(cb, lower: 0.25, upper: 0.43, feather: 0.055)
            * smoothBand(cr, lower: 0.48, upper: 0.72, feather: 0.06)
        let luminance = smoothBand(luma, lower: 0.08, upper: 0.98, feather: 0.08)
        let channelOrder = smoothstep(0, 0.08, colour.x - colour.z)

        return min(max(chroma * luminance * channelOrder, 0), 1)
    }

    private static func smoothBand(_ value: Float, lower: Float, upper: Float, feather: Float) -> Float {
        smoothstep(lower - feather, lower + feather, value)
            * (1 - smoothstep(upper - feather, upper + feather, value))
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

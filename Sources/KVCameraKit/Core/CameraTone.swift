import Foundation
import simd

/// A colour adjustment, as four numbers.
///
/// The whole point of these four and not others: **every one of them is affine in RGB**, so
/// the entire stage collapses to a single 4×4 matrix. That is not a micro-optimisation, it is
/// what makes the viewfinder and the photo agree. A filtered preview that produces an
/// unfiltered — or differently filtered — photo is the worst outcome available here, and the
/// usual way it happens is two implementations of "the same" look: a fragment shader for the
/// preview and a stack of Core Image filters for the still, drifting apart one adjustment at a
/// time. One matrix, computed here, is handed to both.
///
/// The order they compose in is the conventional one and it is not interchangeable: exposure
/// before white balance before saturation before contrast. Saturating first and then lifting
/// exposure is a different picture.
public struct CameraTone: Equatable, Sendable {

    /// Stops. `0` is neutral; `+1` is twice the light.
    public var exposure: Float
    /// `1` is neutral. Scales around mid grey, so it darkens shadows as it brightens highlights.
    public var contrast: Float
    /// `1` is neutral, `0` is greyscale, `2` is twice as colourful.
    public var saturation: Float
    /// `-1` (coldest) to `1` (warmest). Gains red against blue.
    public var warmth: Float

    public static let neutral = CameraTone(exposure: 0, contrast: 1, saturation: 1, warmth: 0)

    public init(exposure: Float = 0, contrast: Float = 1, saturation: Float = 1, warmth: Float = 0) {
        // Clamped at construction rather than at use. A saturation of 40 is not a look, it is
        // a bug somewhere upstream, and the place to stop it is before it reaches a shader
        // where it becomes three fully-clipped channels.
        self.exposure = min(max(exposure, -3), 3)
        self.contrast = min(max(contrast, 0), 3)
        self.saturation = min(max(saturation, 0), 3)
        self.warmth = min(max(warmth, -1), 1)
    }

    public var isNeutral: Bool { self == .neutral }

    /// BT.709 luma weights — the same ones the YCbCr conversion uses, because a saturation
    /// that desaturates around a different grey than the decode assumed shifts every skin tone.
    static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// How far warmth pushes red against blue at full deflection.
    ///
    /// A quarter, chosen so `±1` is a decisive shift and not a novelty filter: full warmth is
    /// a golden-hour cast, not a fire alarm.
    static let warmthGain: Float = 0.25

    /// The whole adjustment, as one matrix: `output = matrix * float4(rgb, 1)`.
    ///
    /// The fourth column carries the bias — contrast is the only stage that needs one — so a
    /// single multiply covers all four adjustments, and there is exactly one place where their
    /// order is decided.
    var colorMatrix: simd_float4x4 {
        // 1 — exposure: a straight gain, in stops so the control is perceptually even.
        let gain = pow(2, exposure)
        let exposureMatrix = Self.diagonal(SIMD3<Float>(repeating: gain))

        // 2 — white balance: red up, blue down. Green is left alone, which is what keeps a
        // warmth slider from turning into a tint slider.
        let warmthMatrix = Self.diagonal(SIMD3<Float>(
            1 + warmth * Self.warmthGain,
            1,
            1 - warmth * Self.warmthGain
        ))

        // 3 — saturation: interpolate each channel towards the luma of the whole pixel, which
        // is a mix and therefore linear, and therefore expressible here rather than in code
        // the still path would have to duplicate.
        let weights = Self.lumaWeights
        let inverse = 1 - saturation
        var saturationMatrix = matrix_identity_float4x4
        for channel in 0..<3 {
            for source in 0..<3 {
                let mix = inverse * weights[source]
                saturationMatrix[source][channel] = channel == source ? saturation + mix : mix
            }
        }

        // 4 — contrast: scale around mid grey. The only stage with an offset.
        var contrastMatrix = Self.diagonal(SIMD3<Float>(repeating: contrast))
        let lift = 0.5 * (1 - contrast)
        contrastMatrix[3] = SIMD4<Float>(lift, lift, lift, 1)

        return contrastMatrix * saturationMatrix * warmthMatrix * exposureMatrix
    }

    private static func diagonal(_ scale: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(scale.x, 0, 0, 0),
            SIMD4<Float>(0, scale.y, 0, 0),
            SIMD4<Float>(0, 0, scale.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

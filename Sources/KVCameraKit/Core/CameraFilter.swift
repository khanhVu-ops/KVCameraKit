import Foundation
import simd

public enum CameraFilterCategory: String, CaseIterable, Equatable, Sendable {
    case styles
    case film
    case lut

    var title: LocalizedStringResource {
        switch self {
        case .styles: return .cameraKit("Styles")
        case .film: return .cameraKit("Film")
        case .lut: return .cameraKit("LUT")
        }
    }
}

/// A named look whose tone, LUT and film texture travel together to every render target.
/// Beauty stays separate so it can compose with every preset.
public struct CameraFilter: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: LocalizedStringResource
    public let category: CameraFilterCategory
    public let tone: CameraTone
    public let lut: CameraLUT?
    public let film: CameraFilmSimulation

    public init(
        id: String,
        title: LocalizedStringResource,
        category: CameraFilterCategory = .styles,
        tone: CameraTone,
        lut: CameraLUT? = nil,
        film: CameraFilmSimulation = .none
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.tone = tone
        self.lut = lut
        self.film = film
    }

    public var isNeutral: Bool { tone.isNeutral && lut == nil && !film.isEnabled }

    public static let original = CameraFilter(id: "original", title: .cameraKit("Original"), tone: .neutral)
    public static let vivid = CameraFilter(
        id: "vivid", title: .cameraKit("Vivid"),
        tone: CameraTone(contrast: 1.12, saturation: 1.35)
    )
    public static let warm = CameraFilter(
        id: "warm", title: .cameraKit("Warm"),
        tone: CameraTone(exposure: 0.06, saturation: 1.08, warmth: 0.55)
    )
    public static let cool = CameraFilter(
        id: "cool", title: .cameraKit("Cool"),
        tone: CameraTone(contrast: 1.06, saturation: 0.95, warmth: -0.5)
    )
    public static let mono = CameraFilter(
        id: "mono", title: .cameraKit("Mono"),
        tone: CameraTone(contrast: 1.15, saturation: 0)
    )

    public static let portra400 = CameraFilter(
        id: "film-portra-400", title: .cameraKit("Portra 400"), category: .film,
        tone: CameraTone(exposure: 0.05, contrast: 0.94, saturation: 0.98, warmth: 0.14),
        lut: PresetLUT.portra400,
        film: CameraFilmSimulation(grain: 0.10, lightLeak: 0.0)
    )
    public static let fujiSuperia = CameraFilter(
        id: "film-fuji-superia", title: .cameraKit("Fuji Superia"), category: .film,
        tone: CameraTone(exposure: 0.02, contrast: 1.06, saturation: 1.08, warmth: -0.06),
        lut: PresetLUT.fujiSuperia,
        film: CameraFilmSimulation(grain: 0.12, lightLeak: 0.0)
    )
    public static let cinestill800T = CameraFilter(
        id: "film-cinestill-800t", title: .cameraKit("Cinestill 800T"), category: .film,
        tone: CameraTone(contrast: 1.08, saturation: 1.06, warmth: -0.16),
        lut: PresetLUT.cinestill800T,
        film: CameraFilmSimulation(grain: 0.18, lightLeak: 0.03)
    )
    public static let polaroid = CameraFilter(
        id: "film-polaroid", title: .cameraKit("Polaroid"), category: .film,
        tone: CameraTone(exposure: 0.06, contrast: 0.90, saturation: 0.86, warmth: 0.18),
        lut: PresetLUT.polaroid,
        film: CameraFilmSimulation(grain: 0.14, lightLeak: 0.04)
    )
    public static let vintageY2K = CameraFilter(
        id: "film-vintage-y2k", title: .cameraKit("Vintage Y2K"), category: .film,
        tone: CameraTone(exposure: 0.08, contrast: 1.10, saturation: 1.08, warmth: 0.08),
        lut: PresetLUT.vintageY2K,
        film: CameraFilmSimulation(grain: 0.15, lightLeak: 0.05)
    )

    public static let tealOrange = CameraFilter(
        id: "lut-teal-orange", title: .cameraKit("Teal & Orange"), category: .lut,
        tone: CameraTone(contrast: 1.08, saturation: 1.04), lut: PresetLUT.tealOrange
    )
    public static let cyberpunk = CameraFilter(
        id: "lut-cyberpunk", title: .cameraKit("Cyberpunk"), category: .lut,
        tone: CameraTone(contrast: 1.15, saturation: 1.15), lut: PresetLUT.cyberpunk
    )
    public static let filmNoir = CameraFilter(
        id: "lut-film-noir", title: .cameraKit("Film Noir"), category: .lut,
        tone: CameraTone(contrast: 1.22, saturation: 0.12), lut: PresetLUT.filmNoir
    )
    public static let warmSunset = CameraFilter(
        id: "lut-warm-sunset", title: .cameraKit("Warm Sunset"), category: .lut,
        tone: CameraTone(exposure: 0.04, contrast: 1.06, saturation: 1.08, warmth: 0.22),
        lut: PresetLUT.warmSunset
    )

    public static let styles: [CameraFilter] = [.original, .vivid, .warm, .cool, .mono]
    public static let filmPresets: [CameraFilter] = [.portra400, .fujiSuperia, .cinestill800T, .polaroid, .vintageY2K]
    public static let lutPresets: [CameraFilter] = [.tealOrange, .cyberpunk, .filmNoir, .warmSunset]
    public static let all: [CameraFilter] = styles + filmPresets + lutPresets
}

private enum PresetLUT {
    static let portra400 = CameraLUT.generated(id: "portra-400") { rgb in
        // Kodak Portra 400: gentle toe lift, warm peach skin tones, golden highlights, cyan shadow separation
        let soft = softClip(rgb, toe: 0.028, shoulder: 0.94)
        let luma = simd_dot(soft, CameraTone.lumaWeights)
        var col = soft
        // Golden-amber highlights and luminous warm skin tones
        let highlightWeight = smoothstep(0.35, 0.92, luma)
        col.x += 0.055 * highlightWeight
        col.y += 0.028 * highlightWeight
        col.z -= 0.035 * highlightWeight
        // Subtle cool cyan shadow separation in low tones
        let shadowWeight = 1.0 - smoothstep(0.04, 0.38, luma)
        col.x -= 0.025 * shadowWeight
        col.z += 0.035 * shadowWeight
        // Pastel color harmony
        let chroma = col - SIMD3<Float>(repeating: luma)
        return SIMD3<Float>(repeating: luma) + chroma * SIMD3<Float>(1.04, 0.94, 0.92)
    }

    static let fujiSuperia = CameraLUT.generated(id: "fuji-superia") { rgb in
        // Fujifilm Superia 400: Emerald green boost, crisp cyan sky, magenta shadow cast
        let soft = softClip(rgb, toe: 0.018, shoulder: 0.96)
        let luma = simd_dot(soft, CameraTone.lumaWeights)
        var col = soft
        // Patented 4th Cyan Color layer emerald greens
        let greenBias = max(0, soft.y - max(soft.x, soft.z))
        col.y += greenBias * 0.32
        col.z += greenBias * 0.12
        // Crisp cyan sky in upper midtones
        let skyWeight = smoothstep(0.25, 0.85, soft.z) * smoothstep(0.2, 0.75, luma)
        col.z += 0.06 * skyWeight
        col.y += 0.03 * skyWeight
        // Distinctive Fuji magenta-tinted shadows
        let shadowWeight = 1.0 - smoothstep(0.06, 0.42, luma)
        col.x += 0.040 * shadowWeight
        col.y -= 0.020 * shadowWeight
        col.z += 0.030 * shadowWeight
        return col
    }

    static let cinestill800T = CameraLUT.generated(id: "cinestill-800t") { rgb in
        // CineStill 800T: Tungsten teal ambient + red-orange halation around lights
        let luma = simd_dot(rgb, CameraTone.lumaWeights)
        var col = rgb
        // Deep cinematic teal/cyan in shadows and ambient light
        let shadowTeal = 1.0 - smoothstep(0.10, 0.65, luma)
        col.x -= 0.060 * shadowTeal
        col.y += 0.020 * shadowTeal
        col.z += 0.100 * shadowTeal
        // Warm amber-gold in mid-highlights
        let warmHighlight = smoothstep(0.45, 0.85, luma)
        col.x += 0.085 * warmHighlight
        col.y += 0.035 * warmHighlight
        col.z -= 0.055 * warmHighlight
        // Signature fiery red-orange halation in bright light sources (luma > 0.65)
        let halation = smoothstep(0.65, 0.98, luma)
        col.x += 0.140 * halation
        col.y += 0.030 * halation
        col.z -= 0.040 * halation
        return col
    }

    static let polaroid = CameraLUT.generated(id: "polaroid") { rgb in
        // Polaroid 600: Matte lifted blacks, olive-cyan shadows, sepia-cream midtones
        let lifted = rgb * 0.84 + SIMD3<Float>(0.055, 0.058, 0.048)
        let luma = simd_dot(lifted, CameraTone.lumaWeights)
        var col = lifted
        // Olive-cyan tint in lower shadows
        let shadowOlive = 1.0 - smoothstep(0.10, 0.55, luma)
        col.x -= 0.025 * shadowOlive
        col.y += 0.030 * shadowOlive
        col.z += 0.010 * shadowOlive
        // Warm sepia-cream midtones
        let warmMid = smoothstep(0.20, 0.70, luma) * (1.0 - smoothstep(0.70, 0.98, luma))
        col.x += 0.060 * warmMid
        col.y += 0.025 * warmMid
        col.z -= 0.040 * warmMid
        return col
    }

    static let vintageY2K = CameraLUT.generated(id: "vintage-y2k") { rgb in
        // Vintage Y2K: 2000s compact flash aesthetic, punchy vivid primaries, warm glow
        let soft = softClip(rgb, toe: 0.020, shoulder: 0.96)
        let luma = simd_dot(soft, CameraTone.lumaWeights)
        var col = soft
        // Golden flash illumination in midtones
        let warmFlash = smoothstep(0.18, 0.78, luma)
        col.x += 0.070 * warmFlash
        col.y += 0.028 * warmFlash
        col.z -= 0.035 * warmFlash
        // Saturated vivid colors
        let chroma = col - SIMD3<Float>(repeating: luma)
        return SIMD3<Float>(repeating: luma) + chroma * 1.22
    }

    static let tealOrange = CameraLUT.generated(id: "teal-orange") { rgb in
        let luma = simd_dot(rgb, CameraTone.lumaWeights)
        return rgb
            + SIMD3<Float>(-0.06, 0.035, 0.07) * (1 - smoothstep(0.18, 0.72, luma))
            + SIMD3<Float>(0.075, 0.018, -0.055) * smoothstep(0.35, 0.92, luma)
    }

    static let cyberpunk = CameraLUT.generated(id: "cyberpunk") { rgb in
        let luma = simd_dot(rgb, CameraTone.lumaWeights)
        return rgb
            + SIMD3<Float>(-0.035, 0.015, 0.11) * (1 - smoothstep(0.2, 0.8, luma))
            + SIMD3<Float>(0.105, -0.025, 0.07) * smoothstep(0.45, 1, luma)
    }

    static let filmNoir = CameraLUT.generated(id: "film-noir") { rgb in
        let luma = pow(min(max(simd_dot(rgb, SIMD3<Float>(0.24, 0.68, 0.08)), 0), 1), 0.92)
        return SIMD3<Float>(luma * 1.01, luma, luma * 0.98)
    }

    static let warmSunset = CameraLUT.generated(id: "warm-sunset") { rgb in
        let luma = simd_dot(rgb, CameraTone.lumaWeights)
        return rgb + SIMD3<Float>(0.075, 0.025, -0.055) * smoothstep(0.12, 0.9, luma)
    }

    private static func softClip(_ rgb: SIMD3<Float>, toe: Float, shoulder: Float) -> SIMD3<Float> {
        let lifted = rgb * (1 - toe) + SIMD3<Float>(repeating: toe)
        return SIMD3<Float>(
            lifted.x / (lifted.x + (1 - lifted.x) / shoulder),
            lifted.y / (lifted.y + (1 - lifted.y) / shoulder),
            lifted.z / (lifted.z + (1 - lifted.z) / shoulder)
        )
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

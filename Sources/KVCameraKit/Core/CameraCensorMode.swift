import Foundation

/// The privacy censor look applied to detected faces in the viewfinder, captured photos,
/// and recorded videos.
public enum CameraCensorMode: Equatable, Sendable, Hashable, CaseIterable {
    /// No face censoring applied.
    case off
    /// Pixelated mosaic blocks (Japanese 18+ / censorship style).
    case mosaic
    /// Smooth Gaussian face blur.
    case blur
    /// Solid black censor bar across the face / eye region.
    case censorBar

    public static var allCases: [CameraCensorMode] {
        [.off, .mosaic, .blur, .censorBar]
    }

    public var isEnabled: Bool {
        self != .off
    }

    /// The value the fragment shader switches on, and the one the Core Image path switches on
    /// for the still and the recording.
    ///
    /// A number rather than the enum, because it crosses into Metal — where an enum is an
    /// `int` in a uniform buffer whichever way it is spelled. Kept beside the cases so adding
    /// a mode without giving it a code is a compile error rather than a mode that silently
    /// does nothing.
    var shaderCode: Int {
        switch self {
        case .off:          return 0
        case .mosaic:       return 1
        case .blur:         return 2
        case .censorBar:    return 3
        }
    }

    public var title: LocalizedStringResource {
        switch self {
        case .off:
            return .cameraKit("Off")
        case .mosaic:
            return .cameraKit("Mosaic")
        case .blur:
            return .cameraKit("Blur")
        case .censorBar:
            return .cameraKit("Censor Bar")
        }
    }

    public var systemIconName: String {
        switch self {
        case .off:
            return "face.smiling"
        case .mosaic:
            return "square.grid.3x3.fill"
        case .blur:
            return "aqi.medium"
        case .censorBar:
            return "eye.slash.fill"
        }
    }
}

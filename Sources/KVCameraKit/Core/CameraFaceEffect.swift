import Foundation

/// Playful face warps, kept separate from `CameraCensorMode` because these effects do not
/// promise anonymity. They reuse the privacy tracker's stable face geometry, so enabling one
/// does not add a second Vision request to the camera pipeline.
public enum CameraFaceEffect: Equatable, Sendable, Hashable, CaseIterable {
    case off
    case bigEyes
    case slimFace
    case funhouse

    public var isEnabled: Bool { self != .off }

    /// Crosses the Swift/Metal uniform boundary. Kept beside the cases so a new effect cannot
    /// silently render as another one.
    var shaderCode: Int {
        switch self {
        case .off:      return 0
        case .bigEyes:  return 1
        case .slimFace: return 2
        case .funhouse: return 3
        }
    }

    public var title: LocalizedStringResource {
        switch self {
        case .off:      return .cameraKit("Off")
        case .bigEyes:  return .cameraKit("Big Eyes")
        case .slimFace: return .cameraKit("Slim Face")
        case .funhouse: return .cameraKit("Funhouse")
        }
    }

    public var systemIconName: String {
        switch self {
        case .off:      return "face.smiling"
        case .bigEyes:  return "eyes"
        case .slimFace: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .funhouse: return "face.dashed"
        }
    }
}

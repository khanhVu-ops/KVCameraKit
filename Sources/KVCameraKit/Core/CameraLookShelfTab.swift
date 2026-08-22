import Foundation

/// Which page of the look shelf is showing, and — as an `Optional` in `CameraState` — whether
/// the shelf is showing at all.
///
/// One value where there used to be two booleans, and that is the whole reason this type exists.
/// `isFilterPickerOpen` and `isCensorPickerOpen` were two independent flags describing one
/// mutually-exclusive thing, so every action that opened either had to remember to close the
/// other, the view had to compose them into an `if`/`else if` chain, and the swipe gesture had to
/// consult both before deciding anything. Three places to keep in step, and the failure mode was
/// two shelves fighting over the same twelve points at the bottom of the screen.
///
/// An optional enum cannot be in that state. Opening is an assignment and closing is `nil`.
public enum CameraLookShelfTab: String, CaseIterable, Identifiable, Equatable, Sendable {
    case styles
    case film
    case lut
    case beauty
    /// Playful face deformation. Separate from Privacy because it does not anonymize anyone.
    case faceFX
    /// Face censoring. Grouped with the looks rather than kept apart because it is the same kind
    /// of decision — something applied to every pixel on the way out — and because keeping it
    /// apart is what produced two competing shelves.
    case privacy

    public var id: String { rawValue }

    /// The filter category this tab lists, or `nil` for the two that are not lists of filters.
    var category: CameraFilterCategory? {
        switch self {
        case .styles:   return .styles
        case .film:     return .film
        case .lut:      return .lut
        case .beauty, .faceFX, .privacy: return nil
        }
    }

    /// Whether opening this tab needs `CameraMode.supportsFilters` and a preview that can draw a
    /// look. Privacy does not: the censor runs in the same pipeline but is not a *look*, and it is
    /// gated on `CameraService.isCensorSupported` instead.
    var needsLookSupport: Bool { self != .privacy && self != .faceFX }

    var title: LocalizedStringResource {
        switch self {
        case .styles:   return .cameraKit("Styles")
        case .film:     return .cameraKit("Film")
        case .lut:      return .cameraKit("LUT")
        case .beauty:   return .cameraKit("Beauty")
        case .faceFX:   return .cameraKit("Face FX")
        case .privacy:  return .cameraKit("Privacy")
        }
    }

    var systemIconName: String {
        switch self {
        case .styles:   return "camera.filters"
        case .film:     return "film"
        case .lut:      return "swatchpalette"
        case .beauty:   return "sparkles"
        case .faceFX:   return "face.dashed"
        case .privacy:  return "eye.slash"
        }
    }

    /// The tab that lists a given category, so opening the shelf lands on the page the current
    /// selection came from rather than always on the first one.
    init(category: CameraFilterCategory) {
        switch category {
        case .styles: self = .styles
        case .film:   self = .film
        case .lut:    self = .lut
        }
    }
}

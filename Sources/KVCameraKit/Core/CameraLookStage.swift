import Foundation

/// One stage of the pipeline that is currently doing something, for the shelf's header to name.
///
/// It exists so the screen can answer "why does the picture look like that" without the user
/// having to open three tabs and read three selections. A film preset, a beauty slider and a
/// censor all compose — that is the design — but composing invisibly is what makes stacking them
/// feel like a bug: turn on Beauty over Cinestill and the result is neither, with nothing on
/// screen saying both are on.
///
/// Deliberately not `CameraFilterCategory` or `CameraLookShelfTab`. Those describe where a control
/// *lives*; this describes what is *applied*, and the two are not the same list — Styles, Film and
/// LUT are three tabs and one stage, because only one of them can be selected at a time.
struct CameraLookStage: Identifiable, Equatable, Sendable {

    enum Kind: String, Equatable, Sendable {
        case filter
        case beauty
        case censor

        var systemIconName: String {
            switch self {
            case .filter: return "camera.filters"
            case .beauty: return "sparkles"
            case .censor: return "eye.slash.fill"
            }
        }
    }

    let kind: Kind
    let title: LocalizedStringResource

    var id: String { kind.rawValue }
}

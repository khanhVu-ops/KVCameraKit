import Foundation

/// What the shutter does.
///
/// A `Bool` named `isPhotoMode` right up until the third mode was on the roadmap. The cost
/// of the `Bool` is not the ugliness of `!isPhotoMode` — it is that `false` has to mean
/// "video" by convention, so adding a scanner means finding every `if isPhotoMode` and
/// asking, one at a time, which of the two branches the new mode belongs in. The compiler
/// cannot help with that; with a `switch` over this enum it can.
///
/// Ordered as the switcher shows them, left to right, so the mode picker can be built from
/// `allCases` instead of a hand-written list that drifts from this one.
public enum CameraMode: String, CaseIterable, Equatable, Sendable {
    case video
    case photo

    /// The switcher's label. A key in the package's own table — see `CameraAlert`.
    var title: LocalizedStringResource {
        switch self {
        case .video: return .cameraKit("VIDEO")
        case .photo: return .cameraKit("PHOTO")
        }
    }

    /// Whether the microphone has to be attached for this mode.
    ///
    /// Asked as a question about the mode rather than as `!isPhotoMode` at the call site,
    /// because it is the *reason* the mic is attached: a screen that may only ever take a
    /// photo must not hold the mic, and a third mode that records audio should not have to
    /// remember to be excluded from a negation somewhere else.
    var needsAudio: Bool {
        switch self {
        case .video: return true
        case .photo: return false
        }
    }

    /// The neighbouring mode, for the carousel swipe. `+1` brings the mode on the right
    /// into the middle.
    ///
    /// Does not wrap, matching the system Camera: a strip that jumps from the last mode back
    /// to the first reads as a mis-swipe rather than as a feature. The previous code was
    /// `onSetPhotoMode(translation.width < 0)`, which was only ever a two-mode answer
    /// dressed as a direction.
    func stepped(by offset: Int) -> CameraMode {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let next = index + offset
        guard all.indices.contains(next) else { return self }
        return all[next]
    }

    /// Whether the shutter starts and stops rather than firing once.
    var isContinuousCapture: Bool {
        switch self {
        case .video: return true
        case .photo: return false
        }
    }
}

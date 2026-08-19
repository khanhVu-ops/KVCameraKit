import SwiftUI

/// Titles for the Camera Control HUD, supplied by the host.
///
/// The HUD is drawn by the system and wants plain `String`s, so they cannot stay
/// `LocalizedStringResource` for a view to resolve later — and only the host knows which
/// localisation system it uses. The lens numbers are *not* here: those are derived from
/// the hardware and formatted against the environment locale inside the package.
public struct CameraControlTitles: Sendable {
    public let zoom: String
    public let exposure: String
    public let timer: String
    /// One per self-timer option, in `CameraTimerOption.all` order.
    public let timerOptions: [String]

    public init(zoom: String, exposure: String, timer: String, timerOptions: [String]) {
        self.zoom = zoom
        self.exposure = exposure
        self.timer = timer
        self.timerOptions = timerOptions
    }
}

/// Called when the corner thumbnail is tapped.
///
/// The source id and namespace are handed over because a zoom transition needs both
/// halves in the same namespace, and the source half — the thumbnail — lives in this
/// package while the destination is the host's own library screen.
public typealias CameraLibraryOpener = @MainActor (String, Namespace.ID) -> Void

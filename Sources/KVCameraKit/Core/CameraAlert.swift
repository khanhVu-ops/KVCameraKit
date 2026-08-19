import Foundation

/// An alert the camera needs shown, described as data.
///
/// The package cannot use the app's `AlertState`, and should not: an alert is a *state*
/// the screen is in, so it survives a rebuild and can be asserted without SwiftUI. Same
/// reasoning as the host's version, own type.
public struct CameraAlert: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: LocalizedStringResource
    public let message: LocalizedStringResource

    public init(
        id: UUID = UUID(),
        title: LocalizedStringResource,
        message: LocalizedStringResource
    ) {
        self.id = id
        self.title = title
        self.message = message
    }
}

extension LocalizedStringResource {

    /// Resolves against this package's own tables.
    ///
    /// A bare literal defaults to `Bundle.main`, which is the *host app* — so in any
    /// project that does not happen to carry these keys the alert would show the key
    /// itself. Nothing crashes and nothing logs, which is exactly why it needs a named
    /// helper rather than a convention to remember.
    static func cameraKit(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
    }
}

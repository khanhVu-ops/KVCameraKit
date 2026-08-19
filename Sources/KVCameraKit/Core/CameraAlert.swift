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

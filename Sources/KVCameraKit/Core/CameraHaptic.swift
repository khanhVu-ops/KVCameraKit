import UIKit

/// Feedback, owned by the package.
///
/// Forty lines duplicated from the host on purpose: the alternative is a dependency on
/// the app's design system, which is the kind of thread that makes a package
/// un-reusable. There is no modifier form here — one that swallowed a `Button`'s tap by
/// attaching `.onTapGesture` is a mistake the host learned once already.
enum CameraHaptic {
    case light, medium, rigid
    case success, error
    case selection

    @MainActor
    func play() {
        switch self {
        case .light:     UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rigid:     UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success:   UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:     UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

import CoreGraphics

/// What a drag across the viewfinder means.
///
/// One gesture recogniser, one classifier, and that is the whole design. The screen has two
/// things a swipe could do — step the mode strip, open or close the filter shelf — and the
/// obvious implementation is two `DragGesture`s with different rules. SwiftUI will happily
/// recognise both, so a diagonal drag fires both, and the user gets a mode change *and* a
/// shelf they did not ask for. There is no ordering or `exclusively(before:)` that makes two
/// overlapping drags safe; there is only not having two.
///
/// So the screen has one drag, and this decides what it was:
///
/// ```text
///                    ▲ open the shelf
///          ╲    ▲    ╱
///           ╲   │   ╱          horizontal wins when |dx| > 1.5·|dy|
///     mode ◀──╳─────╳──▶ mode  vertical   wins when |dy| > 1.5·|dx|
///           ╱   │   ╲          the wedges between are nothing at all
///          ╱    ▼    ╲
///                    ▼ close the shelf
/// ```
///
/// The dead wedges are the point: a drag that is *nearly* diagonal does nothing, rather than
/// doing whichever of two things won a race. Every gesture on this screen is therefore
/// unambiguous by construction rather than by tuning, which is what makes it testable — see
/// `CameraViewfinderSwipeTests`, which asserts that no translation can ever produce two
/// intents.
enum CameraViewfinderSwipe {

    /// Below this, it is a tap that wandered. 60 pt is roughly a thumb roll.
    static let minimumTravel: CGFloat = 60
    /// How decisively one axis has to beat the other.
    static let dominance: CGFloat = 1.5

    enum Intent: Equatable, Sendable {
        /// Step the mode strip. `+1` moves towards the mode on the right of the current one.
        case mode(step: Int)
        /// Open or close the filter shelf.
        case filters(open: Bool)
    }

    /// The intent, or `nil` when the drag was too small or too diagonal to be either.
    ///
    /// `canFilter` is passed in rather than assumed, because in video and scan mode there is no
    /// shelf to open — and a vertical swipe that silently does nothing is better than one that
    /// opens a shelf whose look the mode cannot carry.
    static func classify(_ translation: CGSize, canFilter: Bool) -> Intent? {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)

        guard max(horizontal, vertical) >= minimumTravel else { return nil }

        if horizontal > vertical * dominance {
            // Carousel direction: dragging right brings the mode on the left into the middle.
            return .mode(step: translation.width < 0 ? 1 : -1)
        }

        if vertical > horizontal * dominance {
            guard canFilter else { return nil }
            // Up opens, matching the direction the shelf travels when it appears.
            return .filters(open: translation.height < 0)
        }

        return nil
    }
}

import CoreGraphics
import XCTest
@testable import KVCameraKit

/// The gesture arbitration, which exists so two gestures cannot both fire.
///
/// This is the test the feature was designed around rather than one written after it. Two
/// `DragGesture`s with different rules are both recognised on a diagonal drag, and no ordering
/// modifier fixes it — so the screen has one drag and this decides what it was. That only
/// helps if the decision is provably single-valued, which is what most of these assert.
final class CameraViewfinderSwipeTests: XCTestCase {

    private func classify(_ dx: CGFloat, _ dy: CGFloat, canFilter: Bool = true) -> CameraViewfinderSwipe.Intent? {
        CameraViewfinderSwipe.classify(CGSize(width: dx, height: dy), canFilter: canFilter)
    }

    // MARK: - One intent, never two

    /// Swept over the whole plane: every drag is one intent or none, and the boundaries are
    /// where the doc comment says they are.
    ///
    /// The exhaustive version of the assertion, because "no translation produces two intents"
    /// is a property of the classifier rather than of any particular example — and a returned
    /// enum can only be one case, so what is actually being checked is that the *rules* do not
    /// overlap: anything horizontal-dominant is a mode step and never a shelf, and the reverse.
    func test_everyDragIsOneIntentOrNone() {
        for dx in stride(from: CGFloat(-200), through: 200, by: 10) {
            for dy in stride(from: CGFloat(-200), through: 200, by: 10) {
                let intent = classify(dx, dy)
                let horizontal = abs(dx), vertical = abs(dy)

                switch intent {
                case .mode:
                    XCTAssertGreaterThan(horizontal, vertical * CameraViewfinderSwipe.dominance,
                                         "a mode step fired on a drag that was not horizontal (\(dx), \(dy))")
                case .filters:
                    XCTAssertGreaterThan(vertical, horizontal * CameraViewfinderSwipe.dominance,
                                         "the shelf fired on a drag that was not vertical (\(dx), \(dy))")
                case .none:
                    let dominates = horizontal > vertical * CameraViewfinderSwipe.dominance
                        || vertical > horizontal * CameraViewfinderSwipe.dominance
                    let travelled = max(horizontal, vertical) >= CameraViewfinderSwipe.minimumTravel
                    XCTAssertFalse(dominates && travelled,
                                   "a decisive drag was ignored (\(dx), \(dy))")
                }
            }
        }
    }

    /// The diagonal wedge does nothing at all — which is the point of it.
    ///
    /// A 45° drag is a user who has not decided yet. Picking one of two actions for them is how
    /// a swipe down to see filters changes the mode instead.
    func test_aDiagonalDragDoesNothing() {
        XCTAssertNil(classify(100, 100))
        XCTAssertNil(classify(-100, 100))
        XCTAssertNil(classify(120, -90))
        XCTAssertNil(classify(-90, -120))
    }

    // MARK: - Thresholds

    func test_aSmallDragIsATapThatWandered() {
        XCTAssertNil(classify(59, 0))
        XCTAssertNil(classify(0, -59))
        XCTAssertNotNil(classify(60, 0))
        XCTAssertNotNil(classify(0, -60))
    }

    // MARK: - Directions

    /// Carousel semantics: dragging right brings the mode on the left into the middle.
    func test_horizontalDragsStepTheModeLikeACarousel() {
        XCTAssertEqual(classify(-120, 10), .mode(step: 1))
        XCTAssertEqual(classify(120, -10), .mode(step: -1))
    }

    /// Up opens, down closes — the direction the shelf itself travels.
    func test_verticalDragsOpenAndCloseTheShelf() {
        XCTAssertEqual(classify(0, -120), .filters(open: true))
        XCTAssertEqual(classify(0, 120), .filters(open: false))
    }

    /// In a mode with no shelf, a vertical drag is nothing — not a mode change.
    ///
    /// Falling through to the other intent would mean a swipe up in video mode silently
    /// switching the mode, which is the worst possible answer: the user asked for the thing
    /// this mode does not have, and got a different thing it does.
    func test_verticalDragsDoNothingWhereThereIsNoShelf() {
        XCTAssertNil(classify(0, -120, canFilter: false))
        XCTAssertNil(classify(0, 120, canFilter: false))
        // Horizontal still works there.
        XCTAssertEqual(classify(-120, 0, canFilter: false), .mode(step: 1))
    }
}

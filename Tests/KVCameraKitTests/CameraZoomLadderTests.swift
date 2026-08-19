import XCTest
@testable import KVCameraKit

/// The zoom ladder, without a camera.
///
/// These used to hang off `CameraService` as `static` methods, which worked but read as an
/// exception. As its own type the arithmetic is the unit, and that is the whole reason the
/// split was worth doing: every bug listed below was a real one, and each needed a
/// different phone to reproduce — an iPhone 16, an SE, a wide + tele dual — which is three
/// devices nobody has on a desk.
final class CameraZoomLadderTests: XCTestCase {

    /// The shapes real phones produce.
    func test_ladderMatchesRealDevices() {
        // The point of the ladder: the same list from different hardware. iPhone 16 has
        // ultra wide + wide, and its 2x is a sensor crop no API reports as a lens.
        XCTAssertEqual(
            CameraZoomLadder.levels(optical: [0.5, 1.0], maxFactor: 15.0),
            [0.5, 1.0, 2.0, 3.0, 5.0]
        )

        // A Pro has the 5x optically, so only 2 and 3 are added — and the result matches
        // the iPhone 16 list exactly.
        XCTAssertEqual(
            CameraZoomLadder.levels(optical: [0.5, 1.0, 5.0], maxFactor: 15.0),
            [0.5, 1.0, 2.0, 3.0, 5.0]
        )

        // A 3x tele must not get a 3.0 rung stacked on top of it.
        XCTAssertEqual(
            CameraZoomLadder.levels(optical: [0.5, 1.0, 3.0], maxFactor: 15.0),
            [0.5, 1.0, 2.0, 3.0, 5.0]
        )

        // Single lens: still worth a pill, because the added rungs are real zoom.
        XCTAssertEqual(
            CameraZoomLadder.levels(optical: [1.0], maxFactor: 5.0),
            [1.0, 2.0, 3.0, 5.0]
        )

        // Nothing beyond the range may be offered — that was the whole bug with the
        // hard-coded `0,5` on a phone that has no ultra wide.
        XCTAssertEqual(
            CameraZoomLadder.levels(optical: [1.0], maxFactor: 1.0),
            []
        )
    }

    /// A rung within a fifth of one already on the list is the same chip to the user, so it
    /// is not offered twice.
    func test_nearbyCandidatesAreNotStackedOnOpticalLenses() {
        XCTAssertEqual(
            CameraZoomLadder.levels(optical: [1.0, 2.1], maxFactor: 15.0),
            [1.0, 2.1, 3.0, 5.0]
        )
    }

    /// The list is capped, because past `5×` it is plain digital crop and a chip offering
    /// `10×` is advertising a blurry photo.
    func test_ladderStopsAtTheLimit() {
        let levels = CameraZoomLadder.levels(optical: [0.5, 1.0, 2.0, 3.0, 5.0], maxFactor: 15.0)
        XCTAssertEqual(levels.count, 5)
        XCTAssertEqual(levels.last, 5.0)
    }

    /// The nearest rung is what the Camera Control HUD highlights. Pure arithmetic, which
    /// is exactly why it no longer takes a device.
    func test_nearestIndexPicksTheClosestRung() {
        let ladder: [CGFloat] = [0.5, 1.0, 2.0, 3.0, 5.0]

        XCTAssertEqual(CameraZoomLadder.nearestIndex(in: ladder, forUIFactor: 0.5), 0)
        XCTAssertEqual(CameraZoomLadder.nearestIndex(in: ladder, forUIFactor: 1.2), 1)
        // Mid-pinch between two rungs: the HUD still has to highlight one of them.
        XCTAssertEqual(CameraZoomLadder.nearestIndex(in: ladder, forUIFactor: 2.4), 2)
        // Past the top rung it stays on the top rung rather than falling off the end.
        XCTAssertEqual(CameraZoomLadder.nearestIndex(in: ladder, forUIFactor: 12.0), 4)

        // An iPhone SE has one lens and gets an empty ladder — no rung to highlight, and
        // not a crash.
        XCTAssertNil(CameraZoomLadder.nearestIndex(in: [], forUIFactor: 1.0))
    }
}

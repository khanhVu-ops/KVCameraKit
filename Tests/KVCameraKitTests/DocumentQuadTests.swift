import CoreGraphics
import XCTest
@testable import KVCameraKit

/// The geometry behind the scanner, without Vision or a camera.
///
/// Every assertion here is about a coordinate space, which is where this kind of code
/// actually breaks: Vision hands back 0…1 with the origin at the **bottom** left, and every
/// other space this package touches puts it at the top. An overlay drawn upside down and a
/// crop that takes the wrong half of the page are the same bug.
final class DocumentQuadTests: XCTestCase {

    /// A quad filling the frame, in Vision space.
    private func fullFrame() -> DocumentQuad {
        DocumentQuad(
            topLeft: CGPoint(x: 0, y: 1),
            topRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 1, y: 0)
        )
    }

    // MARK: - Coordinate spaces

    /// The flip lives in exactly one place, and this is the test that says so.
    func test_viewSpaceFlipsTheYAxis() {
        let corners = fullFrame().inViewSpace(of: CGSize(width: 200, height: 100))

        // Order is top-left, top-right, bottom-right, bottom-left — a drawable path.
        // Vision's top-left (y = 1) must come out at the view's y = 0.
        XCTAssertEqual(corners[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(corners[1], CGPoint(x: 200, y: 0))
        XCTAssertEqual(corners[2], CGPoint(x: 200, y: 100))
        XCTAssertEqual(corners[3], CGPoint(x: 0, y: 100))
    }

    /// Image space keeps Vision's bottom-left origin, because that is what Core Image wants.
    /// Flipping here too would silently un-flip the crop.
    func test_imageSpaceScalesButDoesNotFlip() {
        let corners = fullFrame().inImageSpace(of: CGSize(width: 400, height: 300))

        XCTAssertEqual(corners.topLeft, CGPoint(x: 0, y: 300))
        XCTAssertEqual(corners.topRight, CGPoint(x: 400, y: 300))
        XCTAssertEqual(corners.bottomLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(corners.bottomRight, CGPoint(x: 400, y: 0))
    }

    /// The same normalised quad describes any resolution — which is the reason it is stored
    /// normalised at all, since it is detected on one image and drawn over another.
    func test_theSameQuadScalesToAnySize() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.25, y: 0.75),
            topRight: CGPoint(x: 0.75, y: 0.75),
            bottomLeft: CGPoint(x: 0.25, y: 0.25),
            bottomRight: CGPoint(x: 0.75, y: 0.25)
        )
        XCTAssertEqual(quad.inViewSpace(of: CGSize(width: 100, height: 100))[0], CGPoint(x: 25, y: 25))
        XCTAssertEqual(quad.inViewSpace(of: CGSize(width: 1000, height: 1000))[0], CGPoint(x: 250, y: 250))
    }

    // MARK: - Area

    func test_areaOfTheFullFrameIsOne() {
        XCTAssertEqual(fullFrame().areaFraction, 1, accuracy: 0.0001)
    }

    func test_areaOfAQuarterFrameIsAQuarter() {
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0.5),
            topRight: CGPoint(x: 0.5, y: 0.5),
            bottomLeft: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 0.5, y: 0)
        )
        XCTAssertEqual(quad.areaFraction, 0.25, accuracy: 0.0001)
    }

    /// The shoelace formula is signed, so a quad wound the other way must still report a
    /// positive area rather than a negative one that fails every minimum-area check.
    func test_areaIsPositiveRegardlessOfWinding() {
        let reversed = DocumentQuad(
            topLeft: CGPoint(x: 1, y: 1),
            topRight: CGPoint(x: 0, y: 1),
            bottomLeft: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(reversed.areaFraction, 1, accuracy: 0.0001)
    }

    // MARK: - Usability

    /// Vision will happily report a business card at the far end of a table. Cropping to 3%
    /// of the frame produces an unreadable smear, not a scan.
    func test_tinyDetectionsAreRejected() {
        let speck = DocumentQuad(
            topLeft: CGPoint(x: 0.40, y: 0.52),
            topRight: CGPoint(x: 0.52, y: 0.52),
            bottomLeft: CGPoint(x: 0.40, y: 0.48),
            bottomRight: CGPoint(x: 0.52, y: 0.48)
        )
        XCTAssertLessThan(speck.areaFraction, 0.10)
        XCTAssertFalse(speck.isUsable())
        XCTAssertTrue(speck.isUsable(minimumArea: 0.001), "the threshold must be the only reason it failed")
    }

    /// A self-intersecting quad still has a plausible area, and `CIPerspectiveCorrection`
    /// given one returns a folded, unreadable image rather than failing — so it is caught
    /// here instead.
    func test_crossedCornersAreRejected() {
        let verticallyCrossed = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 1, y: 0),
            bottomLeft: CGPoint(x: 0, y: 1),
            bottomRight: CGPoint(x: 1, y: 1)
        )
        XCTAssertFalse(verticallyCrossed.isUsable(), "top edge below the bottom edge")

        let horizontallyCrossed = DocumentQuad(
            topLeft: CGPoint(x: 1, y: 1),
            topRight: CGPoint(x: 0, y: 1),
            bottomLeft: CGPoint(x: 1, y: 0),
            bottomRight: CGPoint(x: 0, y: 0)
        )
        XCTAssertFalse(horizontallyCrossed.isUsable(), "left edge right of the right edge")
    }

    /// A quad hugging every frame edge is the detector reporting that it found no page.
    ///
    /// Measured, not assumed: pointed at a featureless surface,
    /// `VNDetectDocumentSegmentationRequest` returns the whole frame inset by well under one
    /// percent on each side. Accepting that would mean the hint never appears and a "scan" is
    /// an uncropped photo.
    func test_aFrameHuggingQuadIsRejectedAsNoPageFound() {
        XCTAssertTrue(fullFrame().hugsFrame())
        XCTAssertFalse(fullFrame().isUsable())

        // The observed shape: inset by 0.7% horizontally, 0.4% vertically.
        let featureless = DocumentQuad(
            topLeft: CGPoint(x: 0.0069, y: 0.9961),
            topRight: CGPoint(x: 0.9931, y: 0.9961),
            bottomLeft: CGPoint(x: 0.0069, y: 0.0039),
            bottomRight: CGPoint(x: 0.9931, y: 0.0039)
        )
        XCTAssertTrue(featureless.hugsFrame())
        XCTAssertFalse(featureless.isUsable())
    }

    /// A page held close still leaves margins, so it must sit comfortably inside the check.
    /// Filling all four edges at once would mean its borders are off-frame — nothing to crop.
    func test_aLargeButRealPageIsUsable() {
        let closeUp = DocumentQuad(
            topLeft: CGPoint(x: 0.04, y: 0.96),
            topRight: CGPoint(x: 0.96, y: 0.95),
            bottomLeft: CGPoint(x: 0.05, y: 0.05),
            bottomRight: CGPoint(x: 0.95, y: 0.04)
        )
        XCTAssertGreaterThan(closeUp.areaFraction, 0.80)
        XCTAssertFalse(closeUp.hugsFrame())
        XCTAssertTrue(closeUp.isUsable())
    }

    /// Touching *some* edges is normal — a page can run off one side of the frame and still be
    /// worth cropping to. Only all four at once means nothing was found.
    func test_touchingOnlySomeEdgesIsNotHugging() {
        let runsOffTheRight = DocumentQuad(
            topLeft: CGPoint(x: 0.3, y: 0.9),
            topRight: CGPoint(x: 1.0, y: 0.9),
            bottomLeft: CGPoint(x: 0.3, y: 0.1),
            bottomRight: CGPoint(x: 1.0, y: 0.1)
        )
        XCTAssertFalse(runsOffTheRight.hugsFrame())
        XCTAssertTrue(runsOffTheRight.isUsable())
    }

    // MARK: - Smoothing and stability

    /// Vision re-detects from scratch every frame, so a stationary page still moves a pixel
    /// or two. Drawn raw the outline shivers.
    func test_interpolationMovesPartWayTowardsTheNewReading() {
        let from = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 1), topRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 1, y: 0)
        )
        let to = DocumentQuad(
            topLeft: CGPoint(x: 0.2, y: 1), topRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 0), bottomRight: CGPoint(x: 1, y: 0)
        )

        let half = from.interpolated(towards: to, factor: 0.5)
        XCTAssertEqual(half.topLeft.x, 0.1, accuracy: 0.0001)

        // A factor of 1 is no smoothing at all, which is the documented escape hatch.
        XCTAssertEqual(from.interpolated(towards: to, factor: 1), to)
        XCTAssertEqual(from.interpolated(towards: to, factor: 0), from)
    }

    /// The stability signal: near zero means the user has stopped moving the page.
    func test_cornerShiftReportsTheFurthestCorner() {
        let quad = fullFrame()
        XCTAssertEqual(quad.maximumCornerShift(from: quad), 0, accuracy: 0.0001)

        let nudged = DocumentQuad(
            topLeft: CGPoint(x: 0, y: 1),
            topRight: CGPoint(x: 1, y: 1),
            bottomLeft: CGPoint(x: 0, y: 0),
            // Only this corner moved, and by 0.3 — the maximum must be that, not an average.
            bottomRight: CGPoint(x: 1.3, y: 0)
        )
        XCTAssertEqual(quad.maximumCornerShift(from: nudged), 0.3, accuracy: 0.0001)
    }
}

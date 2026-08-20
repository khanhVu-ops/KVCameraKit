import CoreGraphics
import simd
import XCTest
@testable import KVCameraKit

/// The preview transform and the colour matrices, without a GPU.
///
/// Both are arithmetic with a plausible-looking wrong version, and both fail in ways that are
/// easy to look at and hard to *notice*: a preview squashed in landscape, black bars down the
/// sides in portrait, a mirror on the wrong axis, skin tones tilted a few percent. None of
/// those should need a camera to catch.
final class CameraPreviewRendererTests: XCTestCase {

    /// Applies the transform to a clip-space corner, the way the vertex shader does.
    private func mapped(_ point: SIMD2<Float>, _ matrix: simd_float4x4) -> SIMD2<Float> {
        let result = matrix * SIMD4<Float>(point.x, point.y, 0, 1)
        return SIMD2<Float>(result.x, result.y)
    }

    // MARK: - Aspect fill

    /// Matching aspect ratios need no scaling at all: the quad already fits.
    func test_matchingAspectRatioLeavesTheQuadAlone() {
        let matrix = CameraPreviewRenderer.transform(
            source: CGSize(width: 1000, height: 2000),
            destination: CGSize(width: 500, height: 1000),
            rotationAngle: 0,
            mirrored: false
        )
        let corner = mapped(SIMD2<Float>(1, 1), matrix)
        XCTAssertEqual(corner.x, 1, accuracy: 0.001)
        XCTAssertEqual(corner.y, 1, accuracy: 0.001)
    }

    /// Fill, not fit. A 16:9 buffer in a taller window must overflow the sides rather than
    /// leave bars — `AVCaptureVideoPreviewLayer` was doing `.resizeAspectFill`, and switching
    /// engines must not change how much of the scene the user sees or the framing they
    /// composed a shot with moves under them.
    func test_aWiderSourceOverflowsHorizontallyRatherThanLettingBarsIn() {
        let matrix = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 400, height: 800),
            rotationAngle: 0,
            mirrored: false
        )
        let corner = mapped(SIMD2<Float>(1, 1), matrix)

        // Vertically exact, horizontally overflowing: that is fill.
        XCTAssertEqual(corner.y, 1, accuracy: 0.001)
        XCTAssertGreaterThan(corner.x, 1)
        // 1920/1080 scaled to 800 tall is 1422 wide in a 400 window.
        XCTAssertEqual(corner.x, Float(1422.0 / 400.0), accuracy: 0.01)
    }

    /// A quarter turn swaps which dimension has to fill which.
    ///
    /// This is the bug worth having a test for: scaling against the *unrotated* size leaves
    /// black bars down the sides of a portrait preview, and it looks like a layout problem
    /// rather than an arithmetic one.
    func test_aQuarterTurnFillsAgainstTheRotatedDimensions() {
        let upright = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 1080, height: 1920),
            rotationAngle: 0,
            mirrored: false
        )
        let turned = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 1080, height: 1920),
            rotationAngle: 90,
            mirrored: false
        )

        // Unrotated, a 16:9 buffer in a 9:16 window has to overflow enormously.
        XCTAssertGreaterThan(abs(mapped(SIMD2<Float>(1, 1), upright).x), 3)
        // Rotated, it fits exactly — 1080x1920 rotated is exactly the window.
        let turnedCorner = mapped(SIMD2<Float>(1, 1), turned)
        XCTAssertEqual(hypot(turnedCorner.x, turnedCorner.y), hypot(1, 1), accuracy: 0.01)
    }

    func test_270DegreesIsTreatedAsAQuarterTurnToo() {
        let ninety = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 1080, height: 1920),
            rotationAngle: 90, mirrored: false
        )
        let twoSeventy = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 1080, height: 1920),
            rotationAngle: 270, mirrored: false
        )
        // Different rotation, same fill scale — the dimension swap depends on the turn being
        // a quarter, not on its direction.
        XCTAssertEqual(
            hypot(mapped(SIMD2<Float>(1, 1), ninety).x, mapped(SIMD2<Float>(1, 1), ninety).y),
            hypot(mapped(SIMD2<Float>(1, 1), twoSeventy).x, mapped(SIMD2<Float>(1, 1), twoSeventy).y),
            accuracy: 0.001
        )
    }

    func test_180DegreesIsNotADimensionSwap() {
        let none = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 400, height: 800),
            rotationAngle: 0, mirrored: false
        )
        let flipped = CameraPreviewRenderer.transform(
            source: CGSize(width: 1920, height: 1080),
            destination: CGSize(width: 400, height: 800),
            rotationAngle: 180, mirrored: false
        )
        XCTAssertEqual(
            abs(mapped(SIMD2<Float>(1, 1), none).x),
            abs(mapped(SIMD2<Float>(1, 1), flipped).x),
            accuracy: 0.001
        )
    }

    // MARK: - Mirroring

    /// Horizontally, and only horizontally. Mirroring the other axis turns a selfie upside
    /// down, which is a different bug that looks like a rotation problem.
    func test_mirroringFlipsXAndLeavesYAlone() {
        let plain = CameraPreviewRenderer.transform(
            source: CGSize(width: 1000, height: 2000),
            destination: CGSize(width: 500, height: 1000),
            rotationAngle: 0, mirrored: false
        )
        let mirrored = CameraPreviewRenderer.transform(
            source: CGSize(width: 1000, height: 2000),
            destination: CGSize(width: 500, height: 1000),
            rotationAngle: 0, mirrored: true
        )

        let right = mapped(SIMD2<Float>(1, 1), plain)
        let mirroredRight = mapped(SIMD2<Float>(1, 1), mirrored)

        XCTAssertEqual(mirroredRight.x, -right.x, accuracy: 0.001)
        XCTAssertEqual(mirroredRight.y, right.y, accuracy: 0.001)
    }

    // MARK: - Degenerate input

    /// A zero-sized drawable happens for one layout pass on appearance. Dividing by it would
    /// put NaN in the matrix, and a NaN vertex silently draws nothing at all — a black
    /// viewfinder with no error anywhere.
    func test_zeroSizesYieldAFiniteMatrix() {
        for (source, destination) in [
            (CGSize.zero, CGSize(width: 100, height: 100)),
            (CGSize(width: 100, height: 100), CGSize.zero),
            (CGSize.zero, CGSize.zero)
        ] {
            let matrix = CameraPreviewRenderer.transform(
                source: source, destination: destination, rotationAngle: 90, mirrored: true
            )
            for column in 0..<4 {
                for row in 0..<4 {
                    XCTAssertTrue(matrix[column][row].isFinite, "NaN at [\(column)][\(row)] for \(source)/\(destination)")
                }
            }
        }
    }

    // MARK: - Colour

    /// Full range maps luma 0…1 directly; video range starts at 16/255. Swapping them looks
    /// *almost* right — slightly washed out or slightly crushed — which is how it ships.
    func test_theTwoYCbCrRangesHaveDifferentLumaOffsets() {
        XCTAssertEqual(CameraPreviewRenderer.ycbcrOffset(isFullRange: true).x, 0, accuracy: 0.0001)
        XCTAssertEqual(CameraPreviewRenderer.ycbcrOffset(isFullRange: false).x, 16.0 / 255.0, accuracy: 0.0001)

        // Chroma is centred on 128/255 either way.
        for isFullRange in [true, false] {
            let offset = CameraPreviewRenderer.ycbcrOffset(isFullRange: isFullRange)
            XCTAssertEqual(offset.y, 0.5, accuracy: 0.0001)
            XCTAssertEqual(offset.z, 0.5, accuracy: 0.0001)
        }
    }

    /// Neutral grey has to come out grey. If the matrix is transposed — easy, since
    /// `simd_float3x3` is column-major — red and blue swap their corrections and the result
    /// reads as a white-balance fault rather than a bug.
    func test_neutralChromaConvertsToGrey() throws {
        for isFullRange in [true, false] {
            let matrix = CameraPreviewRenderer.ycbcrToRGB(isFullRange: isFullRange)
            let offset = CameraPreviewRenderer.ycbcrOffset(isFullRange: isFullRange)

            // Mid grey: half luma, neutral chroma.
            let ycbcr = SIMD3<Float>(isFullRange ? 0.5 : (16.0 + 0.5 * 219.0) / 255.0, 0.5, 0.5)
            let rgb = matrix * (ycbcr - offset)

            XCTAssertEqual(rgb.x, rgb.y, accuracy: 0.01, "R and G differ, full range: \(isFullRange)")
            XCTAssertEqual(rgb.y, rgb.z, accuracy: 0.01, "G and B differ, full range: \(isFullRange)")
            XCTAssertEqual(rgb.x, 0.5, accuracy: 0.02, "mid grey did not stay mid, full range: \(isFullRange)")
        }
    }

    /// White and black have to land on the ends, or the whole range is shifted.
    func test_fullRangeWhiteAndBlackLandOnTheEnds() {
        let matrix = CameraPreviewRenderer.ycbcrToRGB(isFullRange: true)
        let offset = CameraPreviewRenderer.ycbcrOffset(isFullRange: true)

        let white = matrix * (SIMD3<Float>(1, 0.5, 0.5) - offset)
        let black = matrix * (SIMD3<Float>(0, 0.5, 0.5) - offset)

        XCTAssertEqual(white.x, 1, accuracy: 0.01)
        XCTAssertEqual(white.z, 1, accuracy: 0.01)
        XCTAssertEqual(black.x, 0, accuracy: 0.01)
        XCTAssertEqual(black.z, 0, accuracy: 0.01)
    }

    // MARK: - The flag

    func test_onlyTheMetalEngineNeedsFrames() {
        XCTAssertFalse(CameraPreviewEngine.system.needsFrames)
        XCTAssertTrue(CameraPreviewEngine.metal.needsFrames)
    }
}

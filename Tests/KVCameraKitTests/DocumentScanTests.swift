import CoreImage
import UIKit
import XCTest
@testable import KVCameraKit

/// The scan pipeline: mode behaviour, perspective correction, and what happens when there is
/// no document to find.
final class DocumentScanTests: XCTestCase {

    // MARK: - Mode

    /// The switcher is built from `allCases`, so the order here is the order on screen.
    func test_scanIsAModeBesidePhotoAndVideo() {
        XCTAssertEqual(CameraMode.allCases, [.video, .photo, .scan])
    }

    /// Asked as questions about the mode rather than `mode == .scan` at call sites — the
    /// point being that a fourth mode cannot be silently left out of a negation somewhere.
    func test_onlyScanNeedsFrames_andOnlyVideoNeedsAudio() {
        XCTAssertTrue(CameraMode.scan.needsFrames)
        XCTAssertFalse(CameraMode.photo.needsFrames)
        XCTAssertFalse(CameraMode.video.needsFrames)

        XCTAssertTrue(CameraMode.video.needsAudio)
        XCTAssertFalse(CameraMode.scan.needsAudio, "a scanner must not hold the microphone")

        XCTAssertTrue(CameraMode.video.isContinuousCapture)
        XCTAssertFalse(CameraMode.scan.isContinuousCapture, "one page per shutter press")
    }

    /// Three modes now, and the ends still do not wrap.
    func test_swipeStepsThroughAllThreeAndStopsAtTheEnds() {
        XCTAssertEqual(CameraMode.video.stepped(by: 1), .photo)
        XCTAssertEqual(CameraMode.photo.stepped(by: 1), .scan)
        XCTAssertEqual(CameraMode.scan.stepped(by: 1), .scan, "must not wrap round to video")

        XCTAssertEqual(CameraMode.scan.stepped(by: -1), .photo)
        XCTAssertEqual(CameraMode.photo.stepped(by: -1), .video)
        XCTAssertEqual(CameraMode.video.stepped(by: -1), .video, "must not wrap round to scan")
    }

    // MARK: - Perspective correction

    /// Correcting a quad out of an image squares it up: the output extent is the flattened
    /// page, not the original frame.
    func test_correctionFlattensTheQuadToItsOwnExtent() throws {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))

        // A trapezoid: the top edge is inset, the bottom edge is full width. Flattened, that
        // becomes a rectangle roughly 400 wide.
        let quad = DocumentQuad(
            topLeft: CGPoint(x: 0.25, y: 0.9),
            topRight: CGPoint(x: 0.75, y: 0.9),
            bottomLeft: CGPoint(x: 0.0, y: 0.1),
            bottomRight: CGPoint(x: 1.0, y: 0.1)
        )

        let corrected = try XCTUnwrap(DocumentPageRenderer.correctingPerspective(of: image, to: quad))
        XCTAssertGreaterThan(corrected.extent.width, 0)
        XCTAssertGreaterThan(corrected.extent.height, 0)
        // The flattened page is wider than it is tall for this trapezoid, and crucially it is
        // no longer the 400x400 of the source — the crop actually happened.
        XCTAssertNotEqual(corrected.extent.size, CGSize(width: 400, height: 400))
    }

    /// The tone pass has to be mild enough that the page is still recoverable. A scanner that
    /// thresholds hard to black-and-white destroys a pencil note irreversibly, because the
    /// vault keeps what it was handed.
    func test_enhancementIsMildEnoughToKeepMidTones() throws {
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))

        let enhanced = DocumentPageRenderer.enhanced(grey)
        let data = try XCTUnwrap(DocumentPageRenderer.jpeg(from: enhanced))
        let pixel = try XCTUnwrap(Self.averageBrightness(of: data))

        // Mid grey must stay mid grey — lifted a little, nowhere near clipped to either end.
        XCTAssertGreaterThan(pixel, 0.40)
        XCTAssertLessThan(pixel, 0.70)
    }

    func test_jpegRefusesADegenerateImage() {
        let empty = CIImage(color: .white).cropped(to: .zero)
        XCTAssertNil(DocumentPageRenderer.jpeg(from: empty))
    }

    // MARK: - Detection

    /// There is deliberately **no** test here asserting what the detector finds in a
    /// synthesised frame, and that is a finding rather than an omission.
    ///
    /// Measured, on this simulator: `VNDetectDocumentSegmentationRequest` fed a flat colour
    /// returns the whole frame at confidence 0.0; fed flat white or flat black it returns a
    /// meaningless band across the bottom quarter at confidence 0.83–0.97; and fed a white
    /// rectangle drawn on a dark ground — the obvious way to fake a page — it returns that
    /// same band at 0.99, nowhere near the rectangle. The request is trained on photographs,
    /// and none of those inputs is one.
    ///
    /// So a test built on synthetic frames would be asserting the shape of that junk, and
    /// every guard tuned until it passed would be fitted to noise. What is testable without a
    /// camera is the geometry that stands behind the detector — `DocumentQuadTests` — and the
    /// two failure paths below. The detector itself needs a device pointed at real paper.

    /// Corrupt bytes must not crash the pipeline — `CIImage(data:)` simply fails.
    func test_scanReturnsNilForBytesThatAreNotAnImage() {
        let garbage = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertNil(DocumentPageRenderer.orientedImage(from: garbage))
        XCTAssertNil(DocumentPageRenderer.scan(data: garbage, detector: DocumentDetector()))
    }

    // MARK: - Helpers

    private static func jpegData(size: CGSize, draw: (CGContext, CGRect) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(context.cgContext, CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }

    private static func averageBrightness(of data: Data) -> CGFloat? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { sum, index in
            sum + (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3
        }
        return CGFloat(total / Double(width * height) / 255.0)
    }
}

import UIKit
import XCTest
@testable import KVCameraKit

/// What the container sniffing actually claims.
///
/// Untested until the decoder came out of `CameraService`, because reaching it meant a
/// `AVCapturePhoto` and therefore a device. It is a header check over `Data` and nothing
/// else, and it had a real bug: a HEIC written to disk named `.jpg`.
final class CapturedPhotoDecoderTests: XCTestCase {

    func test_jpegIsDetectedFromItsSOIMarker() {
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            .jpegData(compressionQuality: 0.9)

        let data = try? XCTUnwrap(jpeg)
        XCTAssertEqual(CapturedPhotoDecoder.fileExtension(for: data ?? Data()), "jpg")
    }

    /// Capturing HEVC yields an HEIC container. Trusting the codec *request* instead of the
    /// bytes is how the wrong extension got onto disk.
    func test_heicIsDetectedFromItsFtypBox() {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data("heic".utf8))

        XCTAssertEqual(CapturedPhotoDecoder.fileExtension(for: data), "heic")
    }

    /// Anything unrecognised is called a JPEG rather than left without an extension: a
    /// file the vault cannot name is worse than one named by the common case.
    func test_unknownBytesFallBackToJPEG() {
        XCTAssertEqual(CapturedPhotoDecoder.fileExtension(for: Data()), "jpg")
        XCTAssertEqual(CapturedPhotoDecoder.fileExtension(for: Data([0x01, 0x02, 0x03])), "jpg")
        // Long enough to reach the box-type read, but not a `ftyp` box.
        XCTAssertEqual(
            CapturedPhotoDecoder.fileExtension(for: Data(repeating: 0x00, count: 32)),
            "jpg"
        )
    }

    /// A non-`.up` orientation has to be baked into pixels, because `UIImage.jpegData` is
    /// not reliably upright otherwise. The proof is that the sides swap.
    func test_uprightJPEGBakesARotationIntoThePixels() throws {
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20))
            .image { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            }
        let cgImage = try XCTUnwrap(wide.cgImage)

        let rotated = try XCTUnwrap(CapturedPhotoDecoder.uprightJPEG(from: cgImage, orientation: .right))
        let decoded = try XCTUnwrap(UIImage(data: rotated))

        // The ratio, not the pixel count: `UIGraphicsImageRenderer` renders at the screen
        // scale, so the absolute size depends on which simulator this runs on. The claim
        // being made is that a landscape frame came back portrait.
        XCTAssertEqual(decoded.size.height / decoded.size.width, 2, accuracy: 0.01)
        // And the rotation is in the pixels rather than in a flag a later consumer has to
        // honour — which is the entire reason this function exists.
        XCTAssertEqual(decoded.imageOrientation, .up)
    }

    /// `.up` is the common case and must not be a no-op that silently changes the ratio.
    func test_uprightJPEGLeavesAnAlreadyUprightFrameAlone() throws {
        let tall = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40))
            .image { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
            }
        let cgImage = try XCTUnwrap(tall.cgImage)

        let data = try XCTUnwrap(CapturedPhotoDecoder.uprightJPEG(from: cgImage, orientation: .up))
        let decoded = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(decoded.size.height / decoded.size.width, 2, accuracy: 0.01)
    }
}

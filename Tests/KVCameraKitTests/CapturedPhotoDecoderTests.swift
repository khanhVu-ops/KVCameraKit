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
        let cgImage = try Self.opaqueCGImage(width: 40, height: 20)

        let rotated = try XCTUnwrap(CapturedPhotoDecoder.uprightJPEG(from: cgImage, orientation: .right))
        let decoded = try XCTUnwrap(UIImage(data: rotated))

        // Exact pixels, not a ratio. A ratio was all this could assert while the renderer
        // ran at the screen scale — see `test_uprightJPEGDoesNotResampleTheFrame`.
        XCTAssertEqual(decoded.size, CGSize(width: 20, height: 40))
        // And the rotation is in the pixels rather than in a flag a later consumer has to
        // honour — which is the entire reason this function exists.
        XCTAssertEqual(decoded.imageOrientation, .up)
    }

    /// `.up` is the common case and must not be a no-op that silently changes the size.
    func test_uprightJPEGLeavesAnAlreadyUprightFrameAlone() throws {
        let cgImage = try Self.opaqueCGImage(width: 20, height: 40)

        let data = try XCTUnwrap(CapturedPhotoDecoder.uprightJPEG(from: cgImage, orientation: .up))
        let decoded = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(decoded.size, CGSize(width: 20, height: 40))
    }

    /// One output pixel per source pixel.
    ///
    /// This is a regression test with a specific bug behind it: the renderer used to run at
    /// the default *screen* scale, so a 40x20 source came back 120x60 on a 3x simulator —
    /// nine times the pixels to interpolate and JPEG-encode, on the code path between the
    /// shutter closing and the first frame of feedback. Upsampling never looks wrong, which
    /// is why it survived; it only costs the capture animation the time it exists to hide.
    func test_uprightJPEGDoesNotResampleTheFrame() throws {
        let cgImage = try Self.opaqueCGImage(width: 40, height: 20)
        XCTAssertEqual(cgImage.width, 40, "the source itself must be 1x for this to mean anything")

        for orientation in [CGImagePropertyOrientation.up, .right, .down, .left] {
            let data = try XCTUnwrap(CapturedPhotoDecoder.uprightJPEG(from: cgImage, orientation: orientation))
            let decoded = try XCTUnwrap(UIImage(data: data))
            // `UIImage(data:)` reports a scale of 1 for JPEG, so `size` is the pixel count.
            let pixels = decoded.size.width * decoded.size.height
            XCTAssertEqual(pixels, 800, "\(orientation) resampled: \(decoded.size)")
        }
    }

    /// A source at 1x regardless of the screen this runs on, so the assertions above are
    /// about `uprightJPEG` and not about the simulator that produced the input.
    private static func opaqueCGImage(width: Int, height: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.cgImage)
    }
}

import CoreImage
import UIKit
import XCTest
import simd
@testable import KVCameraKit

/// The look, as arithmetic — and the one assertion that matters most: that the still path and
/// the preview path compute the *same* look.
///
/// A filtered viewfinder over a differently-filtered photo is the worst failure available in
/// this feature, and it is the normal outcome of writing the look twice. So the matrix is built
/// once and this file checks both that the arithmetic is right and that Core Image agrees with
/// it to within a JPEG round trip.
final class CameraToneTests: XCTestCase {

    private func mapped(_ rgb: SIMD3<Float>, through tone: CameraTone) -> SIMD3<Float> {
        let result = tone.colorMatrix * SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
        return SIMD3<Float>(result.x, result.y, result.z)
    }

    // MARK: - The matrix

    /// Neutral has to be exactly identity, not approximately.
    ///
    /// It is what lets the whole stage be skipped rather than multiplied per pixel, and
    /// `isNeutral` is the flag the still path checks before deciding whether to re-encode a
    /// photo at all.
    func test_neutralIsIdentity() {
        XCTAssertTrue(CameraTone.neutral.isNeutral)
        let matrix = CameraTone.neutral.colorMatrix
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(matrix[column][row], matrix_identity_float4x4[column][row], accuracy: 0.0001)
            }
        }
    }

    func test_exposureIsAGainInStops() {
        let brighter = mapped(SIMD3<Float>(0.25, 0.25, 0.25), through: CameraTone(exposure: 1))
        XCTAssertEqual(brighter.x, 0.5, accuracy: 0.0001, "one stop has to be exactly twice the light")

        let darker = mapped(SIMD3<Float>(0.5, 0.5, 0.5), through: CameraTone(exposure: -1))
        XCTAssertEqual(darker.x, 0.25, accuracy: 0.0001)
    }

    /// Contrast pivots on mid grey, or it is a brightness control wearing the wrong name.
    func test_contrastLeavesMidGreyAlone() {
        for contrast in [Float(0.5), 1.0, 1.5, 2.0] {
            let grey = mapped(SIMD3<Float>(0.5, 0.5, 0.5), through: CameraTone(contrast: contrast))
            XCTAssertEqual(grey.x, 0.5, accuracy: 0.0001, "contrast \(contrast) moved mid grey")
        }
        // And it does separate the ends.
        let lifted = mapped(SIMD3<Float>(0.75, 0.75, 0.75), through: CameraTone(contrast: 2))
        XCTAssertEqual(lifted.x, 1.0, accuracy: 0.0001)
    }

    /// Zero saturation is the BT.709 luma of the pixel in all three channels — the same
    /// weights the YCbCr decode uses, so desaturating does not shift the grey it collapses to.
    func test_zeroSaturationCollapsesToLuma() {
        let colour = SIMD3<Float>(0.8, 0.4, 0.2)
        let grey = mapped(colour, through: CameraTone(saturation: 0))
        let luma = simd_dot(colour, CameraTone.lumaWeights)

        XCTAssertEqual(grey.x, luma, accuracy: 0.0001)
        XCTAssertEqual(grey.y, luma, accuracy: 0.0001)
        XCTAssertEqual(grey.z, luma, accuracy: 0.0001)
    }

    /// A neutral grey must stay neutral at any saturation: there is nothing to saturate.
    func test_saturationCannotTintGrey() {
        for saturation in [Float(0), 0.5, 1.5, 2.0] {
            let grey = mapped(SIMD3<Float>(0.6, 0.6, 0.6), through: CameraTone(saturation: saturation))
            XCTAssertEqual(grey.x, grey.y, accuracy: 0.0001)
            XCTAssertEqual(grey.y, grey.z, accuracy: 0.0001)
            XCTAssertEqual(grey.x, 0.6, accuracy: 0.0001, "saturation \(saturation) moved a grey")
        }
    }

    /// Warmth gains red against blue and leaves green alone — otherwise a warmth slider is a
    /// tint slider.
    func test_warmthTradesRedAgainstBlueAndSparesGreen() {
        let source = SIMD3<Float>(0.5, 0.5, 0.5)
        let warm = mapped(source, through: CameraTone(warmth: 1))
        XCTAssertGreaterThan(warm.x, source.x)
        XCTAssertEqual(warm.y, source.y, accuracy: 0.0001)
        XCTAssertLessThan(warm.z, source.z)

        // Symmetric: cooling by the same amount is warming with the channels swapped. What it
        // must *not* be is "cooling lowers blue" — cooling raises blue and lowers red, and
        // getting that backwards is a warmth slider that only ever warms.
        let cool = mapped(source, through: CameraTone(warmth: -1))
        XCTAssertGreaterThan(cool.z, source.z)
        XCTAssertLessThan(cool.x, source.x)
        XCTAssertEqual(warm.x - source.x, cool.z - source.z, accuracy: 0.0001)
        XCTAssertEqual(source.x - cool.x, source.z - warm.z, accuracy: 0.0001)
    }

    /// The stages compose in one order, and it is not interchangeable — saturating and then
    /// lifting exposure is a different picture from the reverse. Pinned so a reordering is a
    /// failing test rather than a look that quietly changed.
    func test_theCompositionOrderIsPinned() {
        let tone = CameraTone(exposure: 1, contrast: 1.5, saturation: 0.5, warmth: 0.5)
        let result = mapped(SIMD3<Float>(0.3, 0.2, 0.1), through: tone)

        // exposure → warmth → saturation → contrast, worked through by hand.
        var rgb = SIMD3<Float>(0.3, 0.2, 0.1) * 2                            // exposure
        rgb = SIMD3<Float>(rgb.x * 1.125, rgb.y, rgb.z * 0.875)              // warmth
        let luma = simd_dot(rgb, CameraTone.lumaWeights)
        rgb = SIMD3<Float>(repeating: luma) + (rgb - SIMD3<Float>(repeating: luma)) * 0.5   // saturation
        rgb = (rgb - SIMD3<Float>(repeating: 0.5)) * 1.5 + SIMD3<Float>(repeating: 0.5)     // contrast

        XCTAssertEqual(result.x, rgb.x, accuracy: 0.0001)
        XCTAssertEqual(result.y, rgb.y, accuracy: 0.0001)
        XCTAssertEqual(result.z, rgb.z, accuracy: 0.0001)
    }

    func test_absurdValuesAreClampedAtConstruction() {
        let tone = CameraTone(exposure: 99, contrast: -4, saturation: 40, warmth: 7)
        XCTAssertEqual(tone.exposure, 3)
        XCTAssertEqual(tone.contrast, 0)
        XCTAssertEqual(tone.saturation, 3)
        XCTAssertEqual(tone.warmth, 1)
    }

    // MARK: - Parity with the still path

    /// Core Image, through the real `ToneRenderer`, has to produce what the matrix says.
    ///
    /// This is the whole reason the tone is a matrix. It goes through the production call —
    /// including its unmanaged colour space, which is the detail that makes the numbers
    /// comparable at all: Core Image's default is to convert to linear light first, and a
    /// preview multiplying gamma-encoded values would then differ from every photo it took.
    func test_theStillPathComputesTheSameLookAsTheMatrix() throws {
        let source = SIMD3<Float>(0.4, 0.55, 0.7)
        let jpeg = try Self.solidJPEG(rgb: source)

        for tone in [
            CameraTone(saturation: 0),
            CameraTone(exposure: 0.5),
            CameraTone(contrast: 1.4),
            CameraTone(warmth: 0.6),
            CameraFilter.vivid.tone,
            CameraFilter.cool.tone
        ] {
            let filtered = try XCTUnwrap(ToneRenderer.apply(tone, to: jpeg), "the still path produced nothing")
            XCTAssertEqual(filtered.fileExtension, "jpg", "a filtered photo is a re-encode and must say so")

            let actual = try Self.centrePixel(of: filtered.data)
            let expected = simd_clamp(mapped(source, through: tone), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

            // A JPEG round trip is worth about two levels; four is generous and still nowhere
            // near the difference a wrong colour space would make.
            let tolerance: Float = 4.0 / 255.0
            XCTAssertEqual(actual.x, expected.x, accuracy: tolerance, "red differs for \(tone)")
            XCTAssertEqual(actual.y, expected.y, accuracy: tolerance, "green differs for \(tone)")
            XCTAssertEqual(actual.z, expected.z, accuracy: tolerance, "blue differs for \(tone)")
        }
    }

    /// A neutral look must not re-encode the photo at all.
    ///
    /// Not an optimisation — re-encoding a JPEG is generational loss, and paying it to apply an
    /// identity matrix would degrade every unfiltered photo the app takes.
    func test_aNeutralToneReturnsTheOriginalBytesUntouched() throws {
        let jpeg = try Self.solidJPEG(rgb: SIMD3<Float>(0.4, 0.55, 0.7))
        let result = try XCTUnwrap(ToneRenderer.apply(.neutral, to: jpeg))
        XCTAssertEqual(result.data, jpeg, "an unfiltered photo was re-encoded")
    }

    func test_bytesThatAreNotAnImageAreRefusedRatherThanPassedThrough() {
        XCTAssertNil(ToneRenderer.apply(CameraFilter.vivid.tone, to: Data("not an image".utf8)))
    }

    /// `CIColorMatrix` reads the transform out by rows, with the offset in its own vector —
    /// leaving the offset in the colour vectors would multiply it by the pixel's alpha.
    func test_theCoreImageParametersAreTheMatrixByRows() throws {
        let matrix = CameraTone(contrast: 1.5, saturation: 0.5).colorMatrix
        let parameters = ToneRenderer.parameters(for: matrix)

        let red = try XCTUnwrap(parameters["inputRVector"] as? CIVector)
        XCTAssertEqual(Float(red.x), matrix[0][0], accuracy: 0.0001)
        XCTAssertEqual(Float(red.y), matrix[1][0], accuracy: 0.0001)
        XCTAssertEqual(Float(red.z), matrix[2][0], accuracy: 0.0001)
        XCTAssertEqual(red.w, 0, "alpha must not bleed into a colour channel")

        let bias = try XCTUnwrap(parameters["inputBiasVector"] as? CIVector)
        XCTAssertEqual(Float(bias.x), matrix[3][0], accuracy: 0.0001)
        XCTAssertEqual(bias.w, 0)

        let alpha = try XCTUnwrap(parameters["inputAVector"] as? CIVector)
        XCTAssertEqual(alpha.w, 1, "alpha has to survive the filter")
    }

    // MARK: - The presets

    func test_thePresetsAreDistinctAndOriginalIsFirstAndNeutral() {
        XCTAssertEqual(CameraFilter.all.first?.id, CameraFilter.original.id, "getting back to no filter has to be the first chip")
        XCTAssertTrue(CameraFilter.original.tone.isNeutral)

        let ids = CameraFilter.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two filters share an id")

        // Every other preset has to actually do something, or it is a chip that lies.
        for filter in CameraFilter.all.dropFirst() {
            XCTAssertFalse(filter.tone.isNeutral, "\(filter.id) is a no-op")
        }
    }

    func test_onlyPhotoModeCarriesALook() {
        XCTAssertTrue(CameraMode.photo.supportsFilters)
        // A recording on the default engine never passes through the app, and a warmed-up
        // receipt is a document somebody adjusted.
        XCTAssertFalse(CameraMode.video.supportsFilters)
        XCTAssertFalse(CameraMode.scan.supportsFilters)
    }

    // MARK: - Helpers

    private static func solidJPEG(rgb: SIMD3<Float>) throws -> Data {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(
                red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1
            ).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
    }

    private static func centrePixel(of jpeg: Data) throws -> SIMD3<Float> {
        let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // One pixel from the middle, so JPEG ringing at the edges cannot contribute.
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return SIMD3<Float>(Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255)
    }
}

import CoreGraphics
import Metal
import UIKit
import XCTest
import simd
@testable import KVCameraKit

final class CameraLUTTests: XCTestCase {

    func test_cubeLoaderReordersBlueFastestInputForMetalAndCoreImage() throws {
        let text = """
        TITLE "Identity"
        LUT_3D_SIZE 2
        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """

        let lut = try CameraLUT.cube(id: "identity-cube", data: Data(text.utf8))
        XCTAssertEqual(lut.dimension, 2)
        XCTAssertEqual(lut.sample(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(lut.sample(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 1, 0))
        assertEqual(lut.sample(SIMD3<Float>(0.5, 0.5, 0.5)), SIMD3<Float>(repeating: 0.5), accuracy: 0.0001)
    }

    func test_cubeLoaderNormalizesAnExplicitInputDomain() throws {
        let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN -1 -1 -1
        DOMAIN_MAX 1 1 1
        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """

        let lut = try CameraLUT.cube(id: "domain", data: Data(text.utf8))
        assertEqual(lut.sample(.zero), SIMD3<Float>(repeating: 0.5), accuracy: 0.0001)
        assertEqual(lut.sample(SIMD3<Float>(repeating: 1)), SIMD3<Float>(repeating: 1), accuracy: 0.0001)
    }

    func test_cubeLoaderRefusesAnIncompleteCube() {
        let text = "LUT_3D_SIZE 2\n0 0 0\n"
        XCTAssertThrowsError(try CameraLUT.cube(id: "broken", data: Data(text.utf8))) { error in
            XCTAssertEqual(error as? CameraLUTError, .invalidEntryCount(expected: 8, actual: 1))
        }
    }

    func test_haldLoaderDecodesTheFlattenedCube() throws {
        let png = try Self.identityHaldPNG(level: 2)
        let lut = try CameraLUT.haldCLUT(id: "hald", pngData: png)

        XCTAssertEqual(lut.dimension, 4)
        assertEqual(lut.sample(.zero), .zero, accuracy: 1.0 / 255.0)
        assertEqual(lut.sample(SIMD3<Float>(repeating: 1)), SIMD3<Float>(repeating: 1), accuracy: 1.0 / 255.0)
        assertEqual(lut.sample(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(1, 0, 0), accuracy: 1.0 / 255.0)
    }

    func test_beautyMaskAcceptsSkinChrominanceAndRejectsBlue() {
        let skin = CameraBeauty.skinWeight(SIMD3<Float>(0.72, 0.48, 0.36))
        let blue = CameraBeauty.skinWeight(SIMD3<Float>(0.12, 0.28, 0.88))
        XCTAssertGreaterThan(skin, 0.45)
        XCTAssertLessThan(blue, 0.05)
    }

    func test_phaseTwoPresetsHaveStableUniqueIDsAndExpectedShelves() {
        XCTAssertEqual(CameraFilter.filmPresets.count, 5)
        XCTAssertEqual(CameraFilter.lutPresets.count, 4)
        XCTAssertTrue(CameraFilter.filmPresets.allSatisfy { $0.category == .film && $0.lut != nil && $0.film.isEnabled })
        XCTAssertTrue(CameraFilter.lutPresets.allSatisfy { $0.category == .lut && $0.lut != nil })
        XCTAssertEqual(Set(CameraFilter.all.map(\.id)).count, CameraFilter.all.count)
    }

    func test_metalLoaderCreatesAReal3DTexture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(CameraLUTTextureLoader(device: device).texture(for: .identity))

        XCTAssertEqual(texture.textureType, .type3D)
        XCTAssertEqual(texture.pixelFormat, .rgba16Float)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.depth, 2)
    }

    private static func identityHaldPNG(level: Int) throws -> Data {
        let dimension = level * level
        let side = level * level * level
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 255, count: side * side * bytesPerPixel)
        let divisor = Float(dimension - 1)

        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let index = red + green * dimension + blue * dimension * dimension
                    let offset = index * bytesPerPixel
                    pixels[offset] = UInt8((Float(red) / divisor * 255).rounded())
                    pixels[offset + 1] = UInt8((Float(green) / divisor * 255).rounded())
                    pixels[offset + 2] = UInt8((Float(blue) / divisor * 255).rounded())
                }
            }
        }

        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(UIImage(cgImage: image).pngData())
    }
}

private extension XCTestCase {
    func assertEqual(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>,
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }
}

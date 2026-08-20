import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
import simd
@testable import KVCameraKit

final class CameraLookRendererTests: XCTestCase {

    func test_neutralLookReturnsOriginalBytesWithoutGenerationLoss() throws {
        let jpeg = try Self.solidJPEG(SIMD3<Float>(0.35, 0.5, 0.7))
        let result = try XCTUnwrap(CameraLookRenderer.apply(filter: .original, beauty: .off, to: jpeg))
        XCTAssertEqual(result.data, jpeg)
    }

    func test_cubeLookIsBakedIntoTheCapturedStill() throws {
        let cube = """
        LUT_3D_SIZE 2
        1 1 1
        1 1 0
        1 0 1
        1 0 0
        0 1 1
        0 1 0
        0 0 1
        0 0 0
        """
        let lut = try CameraLUT.cube(id: "invert", data: Data(cube.utf8))
        let filter = CameraFilter(
            id: "invert",
            title: .cameraKit("Original"),
            category: .lut,
            tone: .neutral,
            lut: lut
        )
        let source = SIMD3<Float>(0.2, 0.35, 0.7)
        let jpeg = try Self.solidJPEG(source)
        let result = try XCTUnwrap(CameraLookRenderer.apply(filter: filter, beauty: .off, to: jpeg))
        let pixel = try Self.centrePixel(result.data)

        XCTAssertEqual(pixel.x, 1 - source.x, accuracy: 5.0 / 255.0)
        XCTAssertEqual(pixel.y, 1 - source.y, accuracy: 5.0 / 255.0)
        XCTAssertEqual(pixel.z, 1 - source.z, accuracy: 5.0 / 255.0)
    }

    func test_beautyReencodesTexturedSkinButLeavesTheControlClamped() throws {
        let jpeg = try Self.skinCheckerboardJPEG()
        let beauty = CameraBeauty(smoothing: 4, brightness: 3, rosy: 2, definition: 5)
        let result = try XCTUnwrap(CameraLookRenderer.apply(filter: .original, beauty: beauty, to: jpeg))

        XCTAssertEqual(beauty.intensity, 1)
        XCTAssertEqual(beauty.brightness, 1)
        XCTAssertEqual(beauty.rosy, 1)
        XCTAssertEqual(beauty.definition, 1)
        XCTAssertNotEqual(result.data, jpeg)
        XCTAssertEqual(result.fileExtension, "jpg")
    }

    func test_filteredCaptureBakesEXIFOrientationIntoPixels() throws {
        let jpeg = try Self.orientedJPEG(width: 40, height: 20, orientation: .right)
        let result = try XCTUnwrap(CameraLookRenderer.apply(filter: .vivid, beauty: .off, to: jpeg))
        let decoded = try XCTUnwrap(UIImage(data: result.data))

        XCTAssertEqual(decoded.size, CGSize(width: 20, height: 40))
        XCTAssertEqual(decoded.imageOrientation, .up)
        XCTAssertEqual(CapturedPhotoDecoder.orientation(for: result.data), .up)
    }

    private static func solidJPEG(_ rgb: SIMD3<Float>) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { context in
            UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 1))
    }

    private static func skinCheckerboardJPEG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
        let image = renderer.image { context in
            for y in 0..<12 {
                for x in 0..<12 {
                    let light = (x + y).isMultiple(of: 2)
                    UIColor(
                        red: light ? 0.78 : 0.64,
                        green: light ? 0.54 : 0.42,
                        blue: light ? 0.41 : 0.31,
                        alpha: 1
                    ).setFill()
                    context.fill(CGRect(x: x * 8, y: y * 8, width: 8, height: 8))
                }
            }
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 1))
    }

    private static func orientedJPEG(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation
    ) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func centrePixel(_ data: Data) throws -> SIMD3<Float> {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2,
                y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return SIMD3<Float>(Float(pixel[0]) / 255, Float(pixel[1]) / 255, Float(pixel[2]) / 255)
    }
}

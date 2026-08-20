import CoreMedia
import CoreVideo
import UIKit
import XCTest
@testable import KVCameraKit

/// The two coordinate conventions, and the poster that got them mixed up.
///
/// This file exists because the same mistake has now shipped twice — an upside-down Metal
/// viewfinder and a video thumbnail facing away from its own video — and both times the tests
/// that existed compared magnitudes. Every assertion here is about *direction*.
final class CaptureRotationTests: XCTestCase {

    // MARK: - The two conventions

    /// The same turn described in a y-up space is the opposite sign of the y-down one.
    ///
    /// If this ever passes with both the same, one of the two callers is 180° wrong and the
    /// other is not — which is exactly the pair of bugs that produced this type.
    func test_theTwoSpacesTurnOppositeWays() {
        let track = CaptureRotation.trackTransform(degrees: 90)
        let image = CaptureRotation.imageTransform(degrees: 90)

        // y-down: a quarter turn is [0, 1, -1, 0] — what a portrait recording carries.
        XCTAssertEqual(track.b, 1, accuracy: 0.0001)
        XCTAssertEqual(track.c, -1, accuracy: 0.0001)

        // y-up: the mirror of it.
        XCTAssertEqual(image.b, -track.b, accuracy: 0.0001)
        XCTAssertEqual(image.c, -track.c, accuracy: 0.0001)

        // And Metal's radians agree with Core Image's matrix rather than the track's.
        XCTAssertEqual(CaptureRotation.clipSpaceRadians(degrees: 90), Float(-Double.pi / 2), accuracy: 0.0001)
    }

    func test_aZeroTurnIsIdentityInBothSpaces() {
        XCTAssertTrue(CaptureRotation.trackTransform(degrees: 0).isIdentity)
        XCTAssertTrue(CaptureRotation.imageTransform(degrees: 0).isIdentity)
        XCTAssertEqual(CaptureRotation.clipSpaceRadians(degrees: 0), 0)
    }

    // MARK: - The preview angle

    /// Portrait is the anchor, and the other three are one quarter turn apart in the right
    /// order. Getting the *cycle* wrong is what makes a preview correct in portrait and
    /// sideways in landscape — the state this screen was in.
    func test_thePreviewAngleCompensatesForTheInterfaceTurn() {
        XCTAssertEqual(CaptureRotation.previewAngle(for: .portrait), 90)
        XCTAssertEqual(CaptureRotation.previewAngle(for: .landscapeRight), 0)
        XCTAssertEqual(CaptureRotation.previewAngle(for: .portraitUpsideDown), 270)
        XCTAssertEqual(CaptureRotation.previewAngle(for: .landscapeLeft), 180)
    }

    /// Turning the interface a quarter turn must take a quarter turn *out* of the
    /// compensation, or the preview turns twice — which is the bug: rotating the phone spun
    /// the picture inside the frame instead of leaving it alone.
    func test_everyQuarterTurnOfTheInterfaceRemovesAQuarterTurnOfCompensation() {
        let clockwise: [UIInterfaceOrientation] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
        for (index, orientation) in clockwise.enumerated() {
            let expected = (90 - CGFloat(index) * 90 + 360).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(
                CaptureRotation.previewAngle(for: orientation), expected,
                "\(orientation.rawValue) breaks the cycle — landscape will be sideways"
            )
        }
    }

    /// An unknown orientation must not produce an unrotated preview, which on a portrait
    /// phone is a sideways one.
    func test_anUnknownOrientationFallsBackToPortrait() {
        XCTAssertEqual(CaptureRotation.previewAngle(for: .unknown), 90)
    }

    // MARK: - The poster

    /// Where the picture actually ends up, measured in pixels.
    ///
    /// The assertion is deliberately *relative*: it finds the bright quadrant with no rotation
    /// and requires the rotated one to be its **clockwise** neighbour. Predicting the absolute
    /// corner would mean predicting Core Image's own origin convention, which is the thing
    /// that was got wrong in the first place — so the test refuses to depend on it and pins
    /// the turn instead.
    func test_thePosterTurnsClockwise() throws {
        let sample = try Self.sampleBuffer(brightQuadrant: 0)

        let unrotated = try XCTUnwrap(CapturePosterRenderer.jpeg(from: sample, rotationAngle: 0))
        let turned = try XCTUnwrap(CapturePosterRenderer.jpeg(from: sample, rotationAngle: 90))

        let before = try Self.brightQuadrant(of: unrotated)
        let after = try Self.brightQuadrant(of: turned)

        // Quadrants numbered clockwise from the top-left: 0 → 1 → 2 → 3.
        XCTAssertEqual(after, (before + 1) % 4, "the poster turned anticlockwise — it faces 180° away from its own video")
    }

    /// A quarter turn swaps the poster's dimensions, or the thumbnail is letterboxed into the
    /// wrong aspect ratio in every grid cell that shows it.
    func test_aQuarterTurnSwapsThePostersDimensions() throws {
        let sample = try Self.sampleBuffer(brightQuadrant: 0)

        let unrotated = try XCTUnwrap(UIImage(data: try XCTUnwrap(
            CapturePosterRenderer.jpeg(from: sample, rotationAngle: 0)
        )))
        let turned = try XCTUnwrap(UIImage(data: try XCTUnwrap(
            CapturePosterRenderer.jpeg(from: sample, rotationAngle: 90)
        )))

        XCTAssertEqual(unrotated.size.width, 640, accuracy: 1)
        XCTAssertEqual(unrotated.size.height, 480, accuracy: 1)
        XCTAssertEqual(turned.size.width, 480, accuracy: 1)
        XCTAssertEqual(turned.size.height, 640, accuracy: 1)
    }

    /// A frame with no image buffer must not produce a poster rather than crashing.
    func test_aBufferWithNoImageYieldsNoPoster() throws {
        XCTAssertNil(CapturePosterRenderer.jpeg(from: try Self.audioOnlySampleBuffer(), rotationAngle: 0))
    }

    // MARK: - Helpers

    /// 640x480 BGRA, black except for one bright quadrant. Quadrants are numbered clockwise
    /// from the top-left as the *buffer* is laid out in memory — row 0 first.
    private static func sampleBuffer(brightQuadrant: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
             kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary,
            &pixelBuffer
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let context = try XCTUnwrap(CGContext(
            data: base, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        // `CGContext` over a pixel buffer has y running *down* the rows, so quadrant 0 —
        // top-left in memory — is at origin zero here.
        let quadrants = [
            CGRect(x: 0, y: 0, width: 320, height: 240),
            CGRect(x: 320, y: 0, width: 320, height: 240),
            CGRect(x: 320, y: 240, width: 320, height: 240),
            CGRect(x: 0, y: 240, width: 320, height: 240)
        ]
        context.setFillColor(UIColor.white.cgColor)
        context.fill(quadrants[brightQuadrant])
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var formatDescription: CMFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription
        ), noErr)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 20, timescale: 600),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(formatDescription),
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    /// Which quadrant of a rendered JPEG is the bright one, numbered clockwise from the
    /// top-left of the image as a person looking at it would see it.
    private static func brightQuadrant(of jpeg: Data) throws -> Int {
        let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        let width = image.width
        let height = image.height

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sampled at the middle of each quadrant, well away from the JPEG's ringing at the
        // boundary between black and white.
        let points = [
            (width / 4, height / 4),
            (width * 3 / 4, height / 4),
            (width * 3 / 4, height * 3 / 4),
            (width / 4, height * 3 / 4)
        ]
        let luminance = points.map { point -> Int in
            let offset = (point.1 * width + point.0) * 4
            return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
        }
        let brightest = try XCTUnwrap(luminance.indices.max(by: { luminance[$0] < luminance[$1] }))
        // One quadrant has to be unambiguously brighter, or the sample points are wrong and
        // the answer is noise.
        for index in luminance.indices where index != brightest {
            XCTAssertGreaterThan(luminance[brightest], luminance[index] + 300, "quadrants are not distinguishable")
        }
        return brightest
    }

    private static func audioOnlySampleBuffer() throws -> CMSampleBuffer {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        ), noErr)

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 128,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 128, flags: 0, blockBufferOut: &blockBuffer
        ), noErr)
        let block = try XCTUnwrap(blockBuffer)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 128), noErr)

        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: try XCTUnwrap(format), sampleCount: 64,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        ), noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}

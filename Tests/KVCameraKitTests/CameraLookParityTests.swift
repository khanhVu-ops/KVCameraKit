import CoreImage
import Foundation
import Testing
import simd
@testable import KVCameraKit

/// Do the fragment shader and the Core Image path agree.
///
/// They are two implementations of one thing, which the package accepts for a stated reason — one
/// has to run per pixel per frame on a GPU and the other has to run on encoded bytes — but every
/// bug this suite exists for came from the *agreement* being a comment rather than a check:
///
/// · the shader placed film texture in **sensor** coordinates and Core Image in **upright** ones,
///   so one preset leaked light from the bottom of the viewfinder and the right of the chip;
/// · grain was hashed per source pixel in one and per output pixel in the other, so the same
///   number produced grain seven times coarser on a 160 px chip than in the photo;
/// · the shader censored **before** grading and the capture path **after**, and each carried a
///   comment claiming it matched the other.
///
/// None of those is visible in a diff, and none of them fails a build. So the constants both sides
/// read are asserted equal by parsing the shader, and the stage order is asserted by rendering.
@Suite("Camera Look Parity")
struct CameraLookParityTests {

    // MARK: - The shader's constants

    /// The shader source, read from the repository rather than from the bundle.
    ///
    /// SwiftPM compiles `.metal` into a `metallib` and does not ship the source, so there is
    /// nothing to read at runtime — but the test binary knows where its own file is, and the
    /// shader is two directories over. Fragile in exactly one way (someone moves the file) and
    /// that way is a loud failure, which is the trade worth making for a constant that is
    /// duplicated by necessity.
    private static let shaderSource: String = {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KVCameraKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // KVCameraKit (package root)
        let metal = tests
            .appendingPathComponent("Sources/KVCameraKit/Capture/Metal/CameraPreview.metal")
        return (try? String(contentsOf: metal, encoding: .utf8)) ?? ""
    }()

    /// A `constant float ... = <number>;` declaration, by name.
    private func shaderScalar(_ name: String) throws -> Double {
        let pattern = "constant\\s+float\\s+\(name)\\s*=\\s*(-?[0-9.]+)"
        let source = Self.shaderSource
        try #require(!source.isEmpty, "the shader source could not be read — has the file moved?")
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(
            regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            "\(name) is not declared in CameraPreview.metal"
        )
        let value = try #require(Range(match.range(at: 1), in: source))
        return try #require(Double(source[value]))
    }

    /// A `constant float2 ... = float2(a, b);` declaration, by name.
    private func shaderVector(_ name: String) throws -> (Double, Double) {
        let pattern = "constant\\s+float2\\s+\(name)\\s*=\\s*float2\\((-?[0-9.]+)\\s*,\\s*(-?[0-9.]+)\\)"
        let source = Self.shaderSource
        try #require(!source.isEmpty, "the shader source could not be read — has the file moved?")
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(
            regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
            "\(name) is not declared in CameraPreview.metal"
        )
        let first = try #require(Range(match.range(at: 1), in: source))
        let second = try #require(Range(match.range(at: 2), in: source))
        return (try #require(Double(source[first])), try #require(Double(source[second])))
    }

    /// Grain frequency is the constant that had no single owner, and the one whose drift was most
    /// visible: it decides whether a film preset looks like the same stock on a chip and in a
    /// photograph.
    @Test("the shader and CameraFilmSimulation agree on grain frequency")
    func grainFrequencyMatches() throws {
        #expect(
            try shaderScalar("kGrainCellsAcrossHeight")
                == Double(CameraFilmSimulation.grainCellsAcrossHeight)
        )
    }

    /// The censor's shape, shared with `CensorRenderer`. Three numbers that decide where a bar
    /// lands and where an ellipse stops, in two implementations.
    @Test("the shader and CensorRenderer agree on the censor's shape")
    func censorShapeMatches() throws {
        let barExtent = try shaderVector("kBarHalfExtent")
        #expect(barExtent.0 == Double(CensorRenderer.barHalfExtent.width))
        #expect(barExtent.1 == Double(CensorRenderer.barHalfExtent.height))

        // The sign flips because Core Image's y runs up and the shader's runs down. Asserted as a
        // negation rather than as two numbers, so a change on either side has to be deliberate.
        #expect(try shaderScalar("kBarCenterY") == -Double(CensorRenderer.barCenterY))

        #expect(try shaderScalar("kCensorFeatherStart") == Double(CensorRenderer.featherStart))

        let cells = try shaderVector("kMosaicCells")
        #expect(cells.0 == Double(CensorRenderer.mosaicCells))
    }

    // MARK: - Orientation

    /// A quarter turn takes the sensor buffer's top-left corner to the upright image's top-right,
    /// which is the same statement `CensorGeometry.sensorRegion` makes in the other direction.
    ///
    /// Asserted on a *corner* rather than on a magnitude, deliberately. Every rotation bug this
    /// package has had — three of them — survived a test that compared `hypot` or `abs`, because
    /// 180° wrong has the same magnitude as right.
    @Test("a quarter turn takes the buffer's top-left to the upright image's top-right")
    func uprightRotationDirection() {
        let matrix = CameraPreviewRenderer.uprightRotation(rotationAngle: 90, mirrored: false)
        // Texture coordinates centred on 0.5: the buffer's top-left corner is (-0.5, -0.5).
        let topLeft = matrix * SIMD2<Float>(-0.5, -0.5)
        #expect(topLeft.x > 0, "the corner should end up on the right")
        #expect(topLeft.y < 0, "and stay at the top")
    }

    /// The turn here and the turn in `CensorGeometry` are inverses. If they are not, film texture
    /// and face geometry disagree about which way up the picture is — and only one of them is
    /// visible enough to notice.
    @Test("the film turn inverts the censor's turn", arguments: [CGFloat(0), 90, 180, 270])
    func uprightRotationInvertsCensorGeometry(angle: CGFloat) {
        let matrix = CameraPreviewRenderer.uprightRotation(rotationAngle: angle, mirrored: false)

        // A point stated in upright space, pushed into sensor space by the censor's turn, then
        // pulled back by the film's. It has to come home.
        let upright = CGPoint(x: 0.8, y: 0.3)
        let sensor = CameraFilmSimulation.sensorPoint(upright: upright, rotationDegrees: angle)
        let recovered = matrix * SIMD2<Float>(Float(sensor.x) - 0.5, Float(sensor.y) - 0.5)

        #expect(abs(Double(recovered.x) + 0.5 - Double(upright.x)) < 0.0001)
        #expect(abs(Double(recovered.y) + 0.5 - Double(upright.y)) < 0.0001)
    }

    @Test("the upright size swaps axes on a quarter turn and not otherwise")
    func uprightSizeSwapsOnAQuarterTurn() {
        let source = CGSize(width: 1_440, height: 1_080)
        #expect(CameraPreviewRenderer.uprightSize(source: source, rotationAngle: 0) == source)
        #expect(CameraPreviewRenderer.uprightSize(source: source, rotationAngle: 180) == source)
        #expect(
            CameraPreviewRenderer.uprightSize(source: source, rotationAngle: 90)
                == CGSize(width: 1_080, height: 1_440)
        )
        #expect(
            CameraPreviewRenderer.uprightSize(source: source, rotationAngle: 270)
                == CGSize(width: 1_080, height: 1_440)
        )
    }

    /// Mirroring is folded in **backwards**, so that the display pass mirroring the scene does not
    /// also mirror the film stock. A leak on the right of the file is on the right on screen.
    @Test("mirroring the preview does not mirror the film stock")
    func mirroringCancels() {
        let plain = CameraPreviewRenderer.uprightRotation(rotationAngle: 90, mirrored: false)
        let mirrored = CameraPreviewRenderer.uprightRotation(rotationAngle: 90, mirrored: true)

        let point = SIMD2<Float>(0.3, -0.2)
        let a = plain * point
        let b = mirrored * point
        #expect(a.x == -b.x, "x is flipped, cancelling the display pass's flip")
        #expect(a.y == b.y, "and nothing else is")
    }

    /// Grain re-rolls in whole steps rather than sliding. A phase that advances by a fraction of a
    /// cell per frame translates the pattern across the picture — grain on a conveyor belt, which
    /// is the one thing real grain never does.
    @Test("the grain phase advances in whole steps")
    func grainPhaseIsQuantised() {
        let a = CameraPreviewRenderer.grainPhase(for: 10.0)
        let b = CameraPreviewRenderer.grainPhase(for: 10.01)
        let c = CameraPreviewRenderer.grainPhase(for: 10.5)
        #expect(a == b, "a 10 ms step must not move the field")
        #expect(c > a, "half a second must")
        #expect(a == a.rounded(), "and every value is a whole step")
    }

    // MARK: - Stage order

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: true
    ])

    private func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return bytes
    }

    private func flat(_ colour: CIColor, size: CGSize = CGSize(width: 400, height: 300)) -> CIImage {
        CIImage(color: colour).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// A region covering the centre of a 400x300 image, big enough that the bar is unambiguous.
    private var centreRegion: CensorRegion {
        CensorRegion(
            id: 1,
            center: CGPoint(x: 0.5, y: 0.5),
            radius: CGSize(width: 0.2, height: 0.2),
            roll: 0
        )
    }

    /// The bar is painted after grading, so it is black however strong the look is.
    ///
    /// This is the discrepancy that shipped: the shader censored first, so Film Noir's LUT lifted
    /// the bar to dark grey in the viewfinder, while Core Image censored last and wrote a black
    /// one to the file. One control, two results.
    @Test("a censor bar is black under a strong LUT")
    func theBarIsBlackAfterGrading() {
        let rendered = CameraLookRenderer.render(
            flat(CIColor(red: 0.55, green: 0.4, blue: 0.3)),
            filter: .filmNoir,
            beauty: .off,
            censorMode: .censorBar,
            regions: [centreRegion],
            grainSeed: 0.37
        )

        let centre = pixel(rendered, x: 200, y: 150)
        #expect(centre[0] == 0 && centre[1] == 0 && centre[2] == 0, "the bar was tinted by the look")
    }

    /// A mosaic is applied before grading, so the censored patch is graded with the rest of the
    /// picture rather than sitting in it as an ungraded rectangle.
    @Test("a mosaic under a monochrome LUT comes out monochrome")
    func theMosaicIsGradedWithThePicture() {
        let rendered = CameraLookRenderer.render(
            flat(CIColor(red: 0.8, green: 0.3, blue: 0.2)),
            filter: .filmNoir,
            beauty: .off,
            censorMode: .mosaic,
            regions: [centreRegion],
            grainSeed: 0.37
        )

        let centre = pixel(rendered, x: 200, y: 150)
        let spread = Int(centre.prefix(3).max() ?? 0) - Int(centre.prefix(3).min() ?? 0)
        #expect(spread <= 6, "the mosaic escaped the LUT: channels differ by \(spread)")
    }

    /// Where the light leak lands must not depend on which way the buffer is lying.
    ///
    /// Rendered twice from the same preset — once as an already-upright portrait, once as the
    /// landscape buffer a portrait capture actually produces — and the bright corner has to be the
    /// same corner of the *picture* both times. Before, it was the same corner of the *buffer*,
    /// which is a quarter turn away.
    @Test("the light leak lands in the same corner of the picture whichever way the buffer lies")
    func theLightLeakFollowsThePicture() {
        let leak = CameraFilter(
            id: "test-leak",
            title: .cameraKit("Original"),
            tone: .neutral,
            film: CameraFilmSimulation(lightLeak: 1)
        )
        let grey = CIColor(red: 0.5, green: 0.5, blue: 0.5)

        // Upright portrait, 300x400. The leak's centre is at (1.03, 0.22) — off the right edge,
        // near the top — so the top-right corner is the bright one.
        let upright = CameraLookRenderer.render(
            flat(grey, size: CGSize(width: 300, height: 400)),
            filter: leak, beauty: .off, rotationDegrees: 0, grainSeed: 0.37
        )
        // Core Image's y runs up, so the top-right corner is (high x, high y).
        let uprightBright = pixel(upright, x: 290, y: 390)
        let uprightDark = pixel(upright, x: 10, y: 10)
        #expect(uprightBright[0] > uprightDark[0] + 10, "the leak is not where the preset says")

        // The same picture as the camera delivers it: a 400x300 landscape buffer that needs a 90°
        // clockwise turn to display. The leak has to end up in the same corner of the picture,
        // which in this buffer is the *top-left*.
        let sensor = CameraLookRenderer.render(
            flat(grey, size: CGSize(width: 400, height: 300)),
            filter: leak, beauty: .off, rotationDegrees: 90, grainSeed: 0.37
        )
        let sensorBright = pixel(sensor, x: 10, y: 290)
        let sensorDark = pixel(sensor, x: 390, y: 10)
        #expect(sensorBright[0] > sensorDark[0] + 10, "the leak did not follow the picture's turn")
    }

    /// Grain is sized against the picture, not against the render, so a chip is a miniature of the
    /// photograph rather than a different film stock.
    @Test("grain cells are the same fraction of the image at any render size")
    func grainScalesWithTheImage() {
        let small = CameraFilmSimulation.grainCellSize(uprightHeight: 400)
        let large = CameraFilmSimulation.grainCellSize(uprightHeight: 4_000)
        #expect(abs(large / small - 10) < 0.0001, "cell size has to scale with the image")

        // And the chip has to be big enough to hold a cell, or the one control whose job is to
        // preview a film preset shows it as noise.
        let chip = CameraFilmSimulation.grainCellSize(uprightHeight: ToneRenderer.thumbnailMaxDimension)
        #expect(chip > 1, "a thumbnail cannot resolve its own grain")
    }
}

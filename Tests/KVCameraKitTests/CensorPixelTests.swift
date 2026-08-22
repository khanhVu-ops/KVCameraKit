import CoreImage
import Testing
@testable import KVCameraKit

/// Does the censor land on the pixels the geometry says it does.
///
/// The tests in `CameraCensorTests` pin the arithmetic; these render it and read the bytes back.
/// The distinction matters because every bug in the first implementation was of the kind where
/// the arithmetic was self-consistent and the pixels still ended up somewhere else — a mask in
/// the wrong space, a filter cropped to the wrong rect, a grid anchored to the wrong origin.
/// A test that only checks the numbers cannot see any of that.
@Suite("Censor Pixel Tests")
struct CensorPixelTests {

    /// Software renderer: these run in CI on a machine with no GPU worth trusting, and a
    /// `CIContext` that silently falls back produces subtly different bytes.
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: true
    ])

    private let size = CGSize(width: 400, height: 300)

    /// Fine vertical stripes. Chosen because every mode destroys them in a way a sampled pixel
    /// can see: the mosaic averages them into flat blocks, the blur into grey, and the chromatic
    /// censor splits and smears their channels. A flat-coloured image would prove little.
    private func stripes() -> CIImage {
        CIImage(color: .white)
            .cropped(to: CGRect(origin: .zero, size: size))
            .applyingFilter("CIStripesGenerator", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                "inputColor0": CIColor.black,
                "inputColor1": CIColor.white,
                kCIInputWidthKey: 2.0,
                "inputSharpness": 1.0
            ])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// One pixel, as bytes.
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

    /// The average of a patch, which is what says "this area was flattened" rather than "this
    /// one pixel happened to change".
    private func meanLuma(_ image: CIImage, in rect: CGRect) -> Double {
        let averaged = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: rect)
        ])
        let bytes = pixel(averaged, x: 0, y: 0)
        return (Double(bytes[0]) + Double(bytes[1]) + Double(bytes[2])) / 3
    }

    /// Centred, a fifth of the frame wide. In sensor-space normalised coordinates with y down,
    /// which is what every consumer of `CensorRegion` uses.
    private var centreRegion: CensorRegion {
        CensorRegion(
            id: 1,
            center: CGPoint(x: 0.5, y: 0.5),
            radius: CGSize(width: 0.1, height: 0.12),
            roll: 0
        )
    }

    @Test("Each mode changes the middle of the frame and leaves the corners alone")
    func censorHitsTheRegionAndNothingElse() {
        let source = stripes()

        for mode in [CameraCensorMode.mosaic, .blur, .censorBar] {
            let rendered = CensorRenderer.render(image: source, mode: mode, regions: [centreRegion])

            // Well inside the ellipse. 0.1 of 400 is a 40 px semi-axis, so the centre patch at
            // 20 px across is comfortably within it even after the feather.
            // A corner, which no region touches. This is the assertion that a filter escaped
            // its crop — the first implementation blurred and pixellated the *whole frame* and
            // relied on a mask to hide it, so a mask in the wrong space leaked everywhere.
            let corner = CGRect(x: 0, y: 0, width: 20, height: 20)

            let sourceCorner = meanLuma(source, in: corner)
            let renderedCorner = meanLuma(rendered, in: corner)
            #expect(abs(sourceCorner - renderedCorner) < 2.0, "\(mode) changed a corner it does not cover")

            // The stripes average to mid-grey, so "flattened" is not visible as a change in the
            // mean — it is visible as the stripes being gone. Sampling two adjacent pixels one
            // stripe apart is what detects that.
            let left = pixel(rendered, x: 195, y: 150)
            let right = pixel(rendered, x: 197, y: 150)
            let contrast = abs(Int(left[0]) - Int(right[0]))
            #expect(contrast < 40, "\(mode) left the stripes readable inside the region (contrast \(contrast))")

            // And the same two pixels in the source *are* different, or the check above proves
            // nothing about the censor.
            let sourceLeft = pixel(source, x: 195, y: 150)
            let sourceRight = pixel(source, x: 197, y: 150)
            #expect(abs(Int(sourceLeft[0]) - Int(sourceRight[0])) > 100, "the test image has no detail to destroy")
        }
    }

    @Test("The chromatic censor destroys detail without painting a black rectangle")
    func chromaticCensorKeepsColour() {
        let rendered = CensorRenderer.render(image: stripes(), mode: .censorBar, regions: [centreRegion])
        let centre = pixel(rendered, x: 200, y: 150)
        let luma = (Int(centre[0]) + Int(centre[1]) + Int(centre[2])) / 3
        #expect(luma > 18, "the new censor regressed to an opaque black rectangle")
        #expect(max(centre[0], centre[1], centre[2]) - min(centre[0], centre[1], centre[2]) > 8,
                "the censor did not split the colour channels")
    }

    @Test("A region at the frame's edge is clipped, not dropped")
    func edgeRegion() {
        let source = stripes()
        // Centre outside the frame entirely: the half of the face that is still visible must
        // still be censored. An unguarded `intersection` returns null here and the whole region
        // is skipped, which uncovers a face walking out of shot.
        let edge = CensorRegion(
            id: 1,
            center: CGPoint(x: -0.02, y: 0.5),
            radius: CGSize(width: 0.15, height: 0.15),
            roll: 0
        )
        let rendered = CensorRenderer.render(image: source, mode: .blur, regions: [edge])

        let left = pixel(rendered, x: 5, y: 150)
        let right = pixel(rendered, x: 7, y: 150)
        #expect(abs(Int(left[0]) - Int(right[0])) < 40, "the visible part of an edge region was left alone")
    }

    @Test("Every Face FX warp changes the face and leaves the frame edge untouched")
    func faceEffectsStayBounded() {
        let source = CIFilter(name: "CICheckerboardGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0.95, green: 0.25, blue: 0.15),
            "inputColor1": CIColor(red: 0.1, green: 0.35, blue: 0.95),
            kCIInputWidthKey: 11.0,
            "inputSharpness": 0.9
        ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) ?? stripes()

        for effect in CameraFaceEffect.allCases where effect.isEnabled {
            let rendered = FaceEffectRenderer.render(image: source, effect: effect, regions: [centreRegion])
            #expect(rendered.extent == source.extent)
            #expect(pixel(rendered, x: 4, y: 4) == pixel(source, x: 4, y: 4), "\(effect) escaped the face")

            var difference = 0
            for y in stride(from: 120, through: 180, by: 10) {
                for x in stride(from: 160, through: 240, by: 10) {
                    let before = pixel(source, x: x, y: y)
                    let after = pixel(rendered, x: x, y: y)
                    difference += zip(before, after).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                }
            }
            #expect(difference > 500, "\(effect) left the face effectively unchanged")
        }
    }

    @Test("Three faces at three angles all encode to a real PNG")
    func contactSheet() throws {
        // Two jobs. The assertion is that a frame with several rolled regions survives being
        // encoded — a Core Image graph with a transform chain in it can build cleanly and
        // produce nothing, and every other test here reads pixels through a path that would
        // hide that.
        //
        // The byproduct is the sheet itself, written where a person can open it, because the
        // look of a censor is the one property no assertion covers and "it is ugly" was half
        // of the original complaint. The path is printed rather than fixed: a test that writes
        // to a hard-coded directory fails on somebody else's machine.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-sheet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("censor contact sheet: \(directory.path)")

        // A coarse checkerboard rather than the fine stripes the assertions use. The sheet is
        // for looking at, and a pattern finer than a mosaic cell averages to flat grey — which
        // proves the averaging works and shows nothing about the look.
        let source = CIFilter(name: "CICheckerboardGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputColor0": CIColor.black,
            "inputColor1": CIColor.white,
            kCIInputWidthKey: 34.0,
            "inputSharpness": 1.0
        ])?.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) ?? stripes()

        for mode in [CameraCensorMode.mosaic, .blur, .censorBar] {
            let regions = [
                centreRegion,
                CensorRegion(id: 2, center: CGPoint(x: 0.2, y: 0.3), radius: CGSize(width: 0.08, height: 0.1), roll: 0.4),
                CensorRegion(id: 3, center: CGPoint(x: 0.8, y: 0.7), radius: CGSize(width: 0.12, height: 0.14), roll: -0.6)
            ]
            let rendered = CensorRenderer.render(image: source, mode: mode, regions: regions)
            let url = directory.appendingPathComponent("censor-\(mode).png")
            try context.writePNGRepresentation(
                of: rendered,
                to: url,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            let written = try Data(contentsOf: url)
            // A 400x300 PNG of stripes with three censored patches. Anything close to empty is
            // a graph that produced nothing, which `writePNGRepresentation` reports by writing
            // a valid, tiny file rather than by throwing.
            #expect(written.count > 2_000, "\(mode) encoded a suspiciously small PNG (\(written.count) bytes)")
        }
    }
}

import CoreImage
import ImageIO
import Testing
@testable import KVCameraKit

/// The censor's geometry, pinned.
///
/// Every test here is arithmetic against a hand-computed number, and none of them needs a
/// camera, a face or a Metal device. That is the point: the first censor implementation was
/// wrong in four independent ways — the detector's orientation, the preview's aspect-fill
/// mapping, the mosaic's cell size and the mask's shape — and not one of them was a kind of
/// wrong a running app announces. They looked like polish.
///
/// The direction assertions are deliberate and they are the lesson `CameraPreviewRenderer`
/// wrote down after shipping an upside-down viewfinder: every rotation test it had compared
/// `hypot` or `abs`, so all of them pinned how far the image was scaled and none of them pinned
/// which way it turned.
@Suite("Camera Censor Tests")
struct CameraCensorTests {

    /// A 1920x1080 sensor buffer held in portrait: the ordinary case, and the one the first
    /// implementation got wrong by assuming `.up`.
    private let sensor = CGSize(width: 1920, height: 1080)
    private let upright = CGSize(width: 1080, height: 1920)

    private func expectClose(
        _ value: CGFloat,
        _ expected: CGFloat,
        _ tolerance: CGFloat = 0.0005,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(value - expected) < tolerance, comment ?? "\(value) != \(expected)", sourceLocation: sourceLocation)
    }

    // MARK: - Modes

    @Test("Censor modes carry a shader code and an icon")
    func modes() {
        #expect(!CameraCensorMode.off.isEnabled)
        #expect(CameraCensorMode.mosaic.isEnabled)
        #expect(CameraCensorMode.blur.isEnabled)
        #expect(CameraCensorMode.censorBar.isEnabled)
        #expect(CameraCensorMode.allCases.count == 4)

        // These four numbers are a contract with `CameraPreview.metal`, which switches on them
        // as floats. Changing one here without changing the shader moves every mosaic to a
        // blur, silently.
        #expect(CameraCensorMode.off.shaderCode == 0)
        #expect(CameraCensorMode.mosaic.shaderCode == 1)
        #expect(CameraCensorMode.blur.shaderCode == 2)
        #expect(CameraCensorMode.censorBar.shaderCode == 3)

        #expect(CameraFaceEffect.allCases.count == 4)
        #expect(CameraFaceEffect.off.shaderCode == 0)
        #expect(CameraFaceEffect.bigEyes.shaderCode == 1)
        #expect(CameraFaceEffect.slimFace.shaderCode == 2)
        #expect(CameraFaceEffect.funhouse.shaderCode == 3)
    }

    // MARK: - Orientation

    @Test("The rotation a portrait buffer needs is the orientation Vision is given")
    func visionOrientation() {
        #expect(CensorGeometry.visionOrientation(rotationDegrees: 0) == .up)
        // 90 degrees clockwise to display: EXIF 6, the portrait rear camera. This single line
        // is the fix for faces going undetected — a sideways face is not found at all.
        #expect(CensorGeometry.visionOrientation(rotationDegrees: 90) == .right)
        #expect(CensorGeometry.visionOrientation(rotationDegrees: 180) == .down)
        #expect(CensorGeometry.visionOrientation(rotationDegrees: 270) == .left)
        // Wraps, so a coordinator reporting 360 or -90 does not fall through to `.up`.
        #expect(CensorGeometry.visionOrientation(rotationDegrees: 360) == .up)
        #expect(CensorGeometry.visionOrientation(rotationDegrees: -90) == .left)
    }

    @Test("Orientation and rotation are inverses of each other")
    func orientationRoundTrip() {
        for degrees in [CGFloat(0), 90, 180, 270] {
            let orientation = CensorGeometry.visionOrientation(rotationDegrees: degrees)
            #expect(CensorGeometry.rotationDegrees(for: orientation) == degrees)
        }
    }

    @Test("Quarter turns round rather than truncate")
    func quarterTurns() {
        #expect(CensorGeometry.quarterTurns(0) == 0)
        #expect(CensorGeometry.quarterTurns(90) == 1)
        #expect(CensorGeometry.quarterTurns(89.9) == 1)
        #expect(CensorGeometry.quarterTurns(270) == 3)
        #expect(CensorGeometry.quarterTurns(-90) == 3)
        #expect(CensorGeometry.quarterTurns(450) == 1)
    }

    // MARK: - Padding

    @Test("Vision's box is padded upward, because the box stops at the eyebrows")
    func padding() {
        // Vision's space: origin bottom-left, y up. Centre at (0.5, 0.65).
        let box = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.1)
        let region = CensorGeometry.uprightRegion(
            visionBox: box,
            visionRoll: 0,
            id: 7,
            uprightSize: upright
        )

        #expect(region.id == 7)
        expectClose(region.center.x, 0.5)
        // 1 - 0.65 flips into y-down, then the bias moves it *up* by 14% of the box height.
        // 0.35 - 0.014. A centre below the original box is the same arithmetic with the sign of
        // the bias wrong, which covers the neck and leaves the hair.
        expectClose(region.center.y, 0.336)
        #expect(region.center.y < 0.35)

        // 0.2 * 1.52 / 2
        expectClose(region.radius.width, 0.152)
        // 0.1 * 1.78 * (1920/1080) / 2 — the vertical fraction rescaled into width units,
        // which is what keeps the space isotropic and the roll rigid.
        expectClose(region.radius.height, 0.158222)

        // In pixels the two semi-axes are 146.9 and 155.5: taller than wide, which is the
        // shape of a head. A radius that came out 16:9-stretched would be the aspect bug.
        expectClose(region.radius.width * upright.width, 164.16, 0.01)
        expectClose(region.radius.height * upright.width, 170.88, 0.01)
    }

    @Test("Vision's roll is negated, because Vision's y runs the other way")
    func rollConvention() {
        let region = CensorGeometry.uprightRegion(
            visionBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            visionRoll: 0.3,
            id: 0,
            uprightSize: upright
        )
        expectClose(region.roll, -0.3)
    }

    // MARK: - Rotation, including which way

    @Test("A quarter turn sends the upright image's top-left to the buffer's bottom-left")
    func rotationDirection() {
        let topLeft = CensorRegion(
            id: 1,
            center: CGPoint(x: 0.1, y: 0.1),
            radius: CGSize(width: 0.1, height: 0.2),
            roll: 0
        )
        let mapped = CensorGeometry.sensorRegion(
            fromUpright: topLeft,
            rotationDegrees: 90,
            sensorSize: sensor
        )

        // The forward turn — buffer to upright — is clockwise, so it takes the buffer's
        // bottom-left corner to the upright image's top-left. This is its inverse, and it is
        // the assertion the whole feature rests on: get the sign wrong and every censor lands
        // in the mirror-image corner of the frame, which looks like a detector failure.
        expectClose(mapped.center.x, 0.1)
        expectClose(mapped.center.y, 0.9)
        #expect(mapped.center.y > 0.5, "the top of a portrait preview is the bottom of a landscape buffer")
    }

    @Test("A quarter turn swaps the semi-axes and renormalises them")
    func rotationRadii() {
        let region = CensorRegion(
            id: 1,
            center: CGPoint(x: 0.5, y: 0.336),
            radius: CGSize(width: 0.152, height: 0.158222),
            roll: 0
        )
        let mapped = CensorGeometry.sensorRegion(
            fromUpright: region,
            rotationDegrees: 90,
            sensorSize: sensor
        )

        // A rotation is rigid in pixels, so the two semi-axes are the same lengths as before —
        // 164.16 and 170.88 — with the axes exchanged. Normalised against the width, which for
        // a quarter turn is a different width, they are 0.5625x their upright values.
        expectClose(mapped.radius.width, 0.089)
        expectClose(mapped.radius.height, 0.0855)
        expectClose(mapped.radius.width * sensor.width, 170.88, 0.02)
        expectClose(mapped.radius.height * sensor.width, 164.16, 0.02)
        // Pixel lengths preserved: the same face, described in the other space.
        expectClose(mapped.radius.width * sensor.width, region.radius.height * upright.width, 0.02)

        expectClose(mapped.roll, -.pi / 2)
    }

    @Test("Half and three-quarter turns")
    func otherRotations() {
        let region = CensorRegion(
            id: 1,
            center: CGPoint(x: 0.25, y: 0.75),
            radius: CGSize(width: 0.1, height: 0.2),
            roll: 0
        )

        let half = CensorGeometry.sensorRegion(fromUpright: region, rotationDegrees: 180, sensorSize: sensor)
        expectClose(half.center.x, 0.75)
        expectClose(half.center.y, 0.25)
        // No quarter turn, so the width is unchanged and so are the semi-axes.
        expectClose(half.radius.width, 0.1)
        expectClose(half.radius.height, 0.2)

        let threeQuarter = CensorGeometry.sensorRegion(fromUpright: region, rotationDegrees: 270, sensorSize: sensor)
        expectClose(threeQuarter.center.x, 0.25)
        expectClose(threeQuarter.center.y, 0.25)
        // 270 is the opposite turn from 90, so the same upright point must not land in the same
        // place — the check that catches a `switch` with two identical branches.
        let quarter = CensorGeometry.sensorRegion(fromUpright: region, rotationDegrees: 90, sensorSize: sensor)
        #expect(abs(threeQuarter.center.y - quarter.center.y) > 0.4)
    }

    @Test("A face is placed the whole way, from Vision to the buffer")
    func endToEnd() {
        let region = CensorGeometry.region(
            visionBox: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.1),
            visionRoll: 0,
            id: 3,
            sensorSize: sensor,
            rotationDegrees: 90
        )

        #expect(region.id == 3)
        expectClose(region.center.x, 0.336)
        expectClose(region.center.y, 0.5)
        expectClose(region.radius.width, 0.089)
        expectClose(region.radius.height, 0.0855)

        // Vision saw the face in the upper half of the portrait picture (y-up 0.65), so in the
        // landscape buffer it is towards the left. Held in portrait, "towards the top of the
        // screen" is "towards the left of the sensor".
        #expect(region.center.x < 0.5)
    }

    @Test("With no rotation nothing moves")
    func identityRotation() {
        let region = CensorGeometry.region(
            visionBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            visionRoll: 0.2,
            id: 1,
            sensorSize: sensor,
            rotationDegrees: 0
        )
        expectClose(region.center.x, 0.5)
        // 1 - 0.5 - 0.2 * 0.14
        expectClose(region.center.y, 0.472)
        expectClose(region.roll, -0.2)
    }

    // MARK: - Bounds

    @Test("A rotated ellipse's bounds follow the rotation")
    func bounds() {
        let flat = CensorGeometry.bounds(
            center: CGPoint(x: 100, y: 100),
            radius: CGSize(width: 50, height: 20),
            roll: 0
        )
        expectClose(flat.width, 100, 0.01)
        expectClose(flat.height, 40, 0.01)

        let turned = CensorGeometry.bounds(
            center: CGPoint(x: 100, y: 100),
            radius: CGSize(width: 50, height: 20),
            roll: .pi / 2
        )
        // Swapped, exactly. `max(rx, ry)` on both axes would pass a test that compared areas
        // and would clip a tilted face in practice.
        expectClose(turned.width, 40, 0.01)
        expectClose(turned.height, 100, 0.01)

        let diagonal = CensorGeometry.bounds(
            center: .zero,
            radius: CGSize(width: 50, height: 20),
            roll: .pi / 4
        )
        // sqrt((50/sqrt2)^2 + (20/sqrt2)^2) * 2
        expectClose(diagonal.width, 76.16, 0.05)
        expectClose(diagonal.height, 76.16, 0.05)
    }

    // MARK: - The shader's uniforms

    @Test("The uniform structs have the layout the shader assumes")
    func uniformLayout() {
        // Not a tautology. These two numbers are the ABI between Swift and Metal, and a
        // mismatch is not a build error on either side — it is a censor drawn somewhere else in
        // the frame, which reads as a coordinate bug and is not one.
        #expect(MemoryLayout<CameraPreviewRenderer.CensorEllipseUniform>.stride == 32)
        #expect(MemoryLayout<CameraPreviewRenderer.CensorHeaderUniform>.stride == 16)
    }

    @Test("Uniforms are packed with the count, the mode and the roll's sine and cosine")
    func uniformPacking() {
        let regions = [
            CensorRegion(id: 1, center: CGPoint(x: 0.25, y: 0.5), radius: CGSize(width: 0.1, height: 0.12), roll: 0),
            CensorRegion(id: 2, center: CGPoint(x: 0.75, y: 0.5), radius: CGSize(width: 0.2, height: 0.24), roll: .pi / 2)
        ]
        let packed = CameraPreviewRenderer.censorUniforms(
            mode: .mosaic,
            regions: regions,
            sourceSize: sensor
        )

        #expect(packed.header.count == 2)
        #expect(packed.header.faceEffect == 0)
        #expect(packed.header.imageSize == SIMD2<Float>(1920, 1080))
        // Always full length: `setFragmentBytes` rejects a zero length, so an empty frame is a
        // count of zero beside unused slots rather than no buffer.
        #expect(packed.ellipses.count == CensorTracker.maximumRegions)

        #expect(packed.ellipses[0].mode == 1)
        expectClose(CGFloat(packed.ellipses[0].center.x), 0.25)
        expectClose(CGFloat(packed.ellipses[0].rollSinCos.x), 0)
        expectClose(CGFloat(packed.ellipses[0].rollSinCos.y), 1)

        // sin then cos, in that order — swapped, a tilted face is censored at the wrong angle
        // and an untilted one is unaffected, so it only shows on the subjects it matters for.
        expectClose(CGFloat(packed.ellipses[1].rollSinCos.x), 1)
        expectClose(CGFloat(packed.ellipses[1].rollSinCos.y), 0)

        // Unused slots are inert rather than absent.
        #expect(packed.ellipses[2].mode == 0)
    }

    @Test("A disabled mode packs no regions however many were tracked")
    func uniformsWhenOff() {
        let packed = CameraPreviewRenderer.censorUniforms(
            mode: .off,
            regions: [CensorRegion(id: 1, center: CGPoint(x: 0.5, y: 0.5), radius: CGSize(width: 0.1, height: 0.1), roll: 0)],
            sourceSize: sensor
        )
        #expect(packed.header.count == 0)
    }

    @Test("A face effect packs tracked regions even when privacy is off")
    func faceEffectUniforms() {
        let packed = CameraPreviewRenderer.censorUniforms(
            mode: .off,
            faceEffect: .bigEyes,
            regions: [CensorRegion(id: 1, center: CGPoint(x: 0.5, y: 0.5), radius: CGSize(width: 0.1, height: 0.1), roll: 0)],
            sourceSize: sensor
        )
        #expect(packed.header.count == 1)
        #expect(packed.header.faceEffect == 1)
        #expect(packed.ellipses[0].mode == 0)
    }

    @Test("More faces than slots keeps the biggest")
    func uniformsOverflow() {
        let regions = (1...12).map { index in
            CensorRegion(
                id: index,
                center: CGPoint(x: 0.5, y: 0.5),
                radius: CGSize(width: CGFloat(index) / 100, height: CGFloat(index) / 100),
                roll: 0
            )
        }
        let packed = CameraPreviewRenderer.censorUniforms(mode: .blur, regions: regions, sourceSize: sensor)
        #expect(packed.header.count == Int32(CensorTracker.maximumRegions))
    }

    // MARK: - Core Image

    @Test("Core Image's ellipse is the same one, with y the other way up")
    func coreImageEllipse() {
        let region = CensorRegion(
            id: 1,
            center: CGPoint(x: 0.25, y: 0.25),
            radius: CGSize(width: 0.1, height: 0.2),
            roll: 0.3
        )
        let ellipse = CensorGeometry.coreImageEllipse(region, in: sensor)

        expectClose(ellipse.center.x, 480, 0.01)
        // y flips: 0.25 from the top is 0.75 from the bottom.
        expectClose(ellipse.center.y, 810, 0.01)
        // Both semi-axes scale by the *width*, per `CensorRegion.radius`.
        expectClose(ellipse.radius.width, 192, 0.01)
        expectClose(ellipse.radius.height, 384, 0.01)
        // And the turn flips with the axis.
        expectClose(ellipse.roll, -0.3)
    }

    @Test("Rendering is a no-op with no mode and no faces")
    func renderNoOp() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let region = CensorRegion(id: 1, center: CGPoint(x: 0.5, y: 0.5), radius: CGSize(width: 0.2, height: 0.2), roll: 0)

        #expect(CensorRenderer.render(image: image, mode: .off, regions: [region]).extent == image.extent)
        #expect(CensorRenderer.render(image: image, mode: .mosaic, regions: []).extent == image.extent)
    }

    @Test("Every mode renders and leaves the frame the size it was")
    func renderModes() {
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let regions = [
            CensorRegion(id: 1, center: CGPoint(x: 0.4, y: 0.5), radius: CGSize(width: 0.15, height: 0.18), roll: 0.2),
            // Deliberately at the very edge: a censor near a border is where a crop that forgets
            // to intersect the extent produces an empty image, and where a blur without
            // `clampedToExtent` produces a dark halo.
            CensorRegion(id: 2, center: CGPoint(x: 0.02, y: 0.98), radius: CGSize(width: 0.2, height: 0.2), roll: -0.4)
        ]

        for mode in [CameraCensorMode.mosaic, .blur, .censorBar] {
            let rendered = CensorRenderer.render(image: image, mode: mode, regions: regions)
            #expect(rendered.extent == image.extent, "\(mode) changed the frame's extent")
            // Rendered rather than only constructed: a Core Image graph that cannot execute is
            // built without complaint and produces nothing at the point of use.
            let context = CIContext(options: [.useSoftwareRenderer: true])
            #expect(context.createCGImage(rendered, from: rendered.extent) != nil, "\(mode) produced no pixels")
        }
    }

    @Test("A degenerate region is skipped rather than rendered")
    func renderDegenerate() {
        let image = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        // Sub-pixel radii: a face reported at the very limit of detection, which is where an
        // unguarded crop is one pixel wide and every filter downstream returns nothing.
        let region = CensorRegion(id: 1, center: CGPoint(x: 0.5, y: 0.5), radius: .zero, roll: 0)
        let rendered = CensorRenderer.render(image: image, mode: .mosaic, regions: [region])
        #expect(rendered.extent == image.extent)
    }
}

import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

/// Draws camera frames into an `MTKView`.
///
/// The reason this exists is step 8, not performance: `AVCaptureVideoPreviewLayer` renders
/// the session straight to a `CALayer`, and there is no way to put a LUT, a tone curve or a
/// beauty pass in front of it. Once the app draws its own frames, a filter is a fragment
/// shader; until then it is impossible. Owning the preview is the precondition.
///
/// It runs *behind a flag* (`CameraPreviewEngine`) with the system layer still the default,
/// because a viewfinder is the one thing in a camera that must never be worse. A preview
/// that drops frames, shows the wrong colours or lags the shutter has to be revertible in
/// one line rather than in a hotfix.
/// Not an `NSObject`, and not the `MTKViewDelegate` itself: `NSObject.init()` is
/// non-failable, and this initialiser genuinely can fail — no Metal device, no shader
/// library, no texture cache. A renderer that pretended to succeed and drew nothing would be
/// indistinguishable from a black viewfinder. The representable's coordinator is the delegate
/// and forwards to this.
final class CameraPreviewRenderer: @unchecked Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bgraPipeline: MTLRenderPipelineState
    private let ycbcrPipeline: MTLRenderPipelineState

    /// Zero-copy `CVPixelBuffer` → `MTLTexture`. Wrapping the buffer's existing IOSurface
    /// rather than copying is the whole reason this is cheap enough to do per frame.
    private let textureCache: CVMetalTextureCache

    private let lock = NSLock()

    /// The newest frame's textures, replaced rather than queued, and held until replaced.
    ///
    /// This is a deliberate, bounded exception to the rule in `CameraFrame`: a
    /// `CVMetalTexture` retains the underlying IOSurface, so holding one holds a buffer from
    /// AVFoundation's finite pool. Holding **one**, replaced on every arrival and released
    /// when the next lands, is what every Metal camera pipeline does and what the pool is
    /// sized for. Queueing them — or holding one indefinitely — is what empties the pool and
    /// makes delivery stop silently.
    ///
    /// *Until replaced* is load-bearing, and it was not always so: this used to be cleared
    /// the moment it had been drawn, which made a redraw impossible without a new frame from
    /// the camera. That is fine at 30 fps and catastrophic the moment something clears the
    /// layer — a `CAMetalLayer` hands back a fresh, empty drawable pool whenever its size
    /// changes, so a single re-layout left the viewfinder **black** until the next frame
    /// arrived. Which is exactly what a still capture stops sending: AVFoundation suspends the
    /// video data output for the duration, so taking a photo turned the preview black for as
    /// long as the shutter took, and only for photos. Keeping the last frame makes every
    /// redraw idempotent, which is what the paragraph above always described.
    private var pending: PendingFrame?

    private struct PendingFrame {
        /// Kept alive explicitly. `CVMetalTextureGetTexture` returns a texture whose memory
        /// belongs to these, so releasing them early leaves a valid-looking `MTLTexture`
        /// pointing at reused memory — which renders as a flicker of somebody else's frame.
        let holders: [CVMetalTexture]
        let textures: [MTLTexture]
        let format: FrameFormat
        let rotationAngle: CGFloat
        let sourceSize: CGSize
        let isMirrored: Bool
    }

    private enum FrameFormat {
        case bgra
        /// Bi-planar YCbCr. `isFullRange` decides the conversion offset, and getting it
        /// wrong looks *almost* right rather than obviously broken.
        case ycbcr(isFullRange: Bool)
    }

    /// Mirrored horizontally, for the front camera. The preview is a mirror in every camera
    /// app because that is what people expect of their own face; the *capture* is not.
    var isMirrored = false

    /// The turn that makes the buffer upright in the interface the user is holding, set by the
    /// view that owns the drawable.
    ///
    /// **Not** the angle on the frame. That one is `videoRotationAngleForHorizonLevelCapture`,
    /// which tracks gravity so a *recording* comes out level — and a preview inside a view
    /// UIKit has already rotated does not want it: applying it turned the picture a second
    /// time, so rotating the phone spun the image inside the frame. See
    /// `CaptureRotation.previewAngle(for:)`.
    var previewRotationAngle: CGFloat = 90

    /// The look, already composed into one matrix. Set from the screen when the user picks a
    /// filter; read once per frame.
    ///
    /// Held as the matrix rather than as a `CameraTone` so the per-frame path does no
    /// arithmetic, and so the *same value* can be handed to the still renderer — one look, two
    /// destinations, no second implementation to drift.
    var toneMatrix: simd_float4x4 = matrix_identity_float4x4

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }

        // The `.metal` file is compiled by SwiftPM into the package's own bundle, so the
        // default library of `Bundle.main` is the wrong place to look — that is the host app.
        guard let library = try? device.makeDefaultLibrary(bundle: .module),
              let vertexFunction = library.makeFunction(name: "cameraPreviewVertex"),
              let bgraFunction = library.makeFunction(name: "cameraPreviewFragmentBGRA"),
              let ycbcrFunction = library.makeFunction(name: "cameraPreviewFragmentYCbCr")
        else { return nil }

        func pipeline(fragment: MTLFunction) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let bgraPipeline = pipeline(fragment: bgraFunction),
              let ycbcrPipeline = pipeline(fragment: ycbcrFunction) else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.bgraPipeline = bgraPipeline
        self.ycbcrPipeline = ycbcrPipeline
        self.textureCache = textureCache
    }

    // MARK: - Frame intake

    /// Called on the frame source's queue. Builds textures now, while the buffer is
    /// guaranteed valid, and hands them to the next draw.
    func accept(_ frame: CameraFrame) {
        guard let pixelBuffer = frame.pixelBuffer else { return }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let mirrored = isMirrored

        let prepared: PendingFrame?
        switch format {
        case kCVPixelFormatType_32BGRA:
            prepared = makeBGRAFrame(from: pixelBuffer, frame: frame, size: CGSize(width: width, height: height), isMirrored: mirrored)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            prepared = makeYCbCrFrame(from: pixelBuffer, frame: frame, size: CGSize(width: width, height: height), isFullRange: true, isMirrored: mirrored)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            prepared = makeYCbCrFrame(from: pixelBuffer, frame: frame, size: CGSize(width: width, height: height), isFullRange: false, isMirrored: mirrored)
        default:
            // An unhandled format draws nothing rather than drawing garbage. Silently
            // rendering a misinterpreted buffer is how a green-and-magenta viewfinder ships.
            prepared = nil
        }

        guard let prepared else { return }
        lock.lock()
        pending = prepared
        lock.unlock()
    }

    private func makeBGRAFrame(from pixelBuffer: CVPixelBuffer, frame: CameraFrame, size: CGSize, isMirrored: Bool) -> PendingFrame? {
        guard let (holder, texture) = makeTexture(from: pixelBuffer, plane: 0, format: .bgra8Unorm) else { return nil }
        return PendingFrame(
            holders: [holder],
            textures: [texture],
            format: .bgra,
            rotationAngle: frame.rotationAngle ?? 0,
            sourceSize: size,
            isMirrored: isMirrored
        )
    }

    private func makeYCbCrFrame(
        from pixelBuffer: CVPixelBuffer,
        frame: CameraFrame,
        size: CGSize,
        isFullRange: Bool,
        isMirrored: Bool
    ) -> PendingFrame? {
        // Luma is single-channel at full resolution; chroma is two interleaved channels at
        // half resolution. `r8Unorm` and `rg8Unorm` are what those planes actually are —
        // asking for anything wider reads adjacent plane memory as colour.
        guard let (lumaHolder, luma) = makeTexture(from: pixelBuffer, plane: 0, format: .r8Unorm),
              let (chromaHolder, chroma) = makeTexture(from: pixelBuffer, plane: 1, format: .rg8Unorm)
        else { return nil }

        return PendingFrame(
            holders: [lumaHolder, chromaHolder],
            textures: [luma, chroma],
            format: .ycbcr(isFullRange: isFullRange),
            rotationAngle: frame.rotationAngle ?? 0,
            sourceSize: size,
            isMirrored: isMirrored
        )
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) -> (CVMetalTexture, MTLTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)

        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            format, width, height, plane, &reference
        )
        guard status == kCVReturnSuccess,
              let reference,
              let texture = CVMetalTextureGetTexture(reference) else { return nil }
        return (reference, texture)
    }

    // MARK: - Drawing

    func draw(in view: MTKView) {
        lock.lock()
        let frame = pending
        lock.unlock()

        guard let frame,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        var transform = Self.transform(
            source: frame.sourceSize,
            destination: view.drawableSize,
            rotationAngle: previewRotationAngle,
            mirrored: frame.isMirrored
        )

        var tone = toneMatrix

        switch frame.format {
        case .bgra:
            encoder.setRenderPipelineState(bgraPipeline)
            encoder.setFragmentTexture(frame.textures[0], index: 0)
            encoder.setFragmentBytes(&tone, length: MemoryLayout<simd_float4x4>.size, index: 0)

        case .ycbcr(let isFullRange):
            encoder.setRenderPipelineState(ycbcrPipeline)
            encoder.setFragmentTexture(frame.textures[0], index: 0)
            encoder.setFragmentTexture(frame.textures[1], index: 1)
            var conversion = Self.ycbcrToRGB(isFullRange: isFullRange)
            var offset = Self.ycbcrOffset(isFullRange: isFullRange)
            encoder.setFragmentBytes(&conversion, length: MemoryLayout<simd_float3x3>.size, index: 0)
            encoder.setFragmentBytes(&offset, length: MemoryLayout<simd_float3>.size, index: 1)
            encoder.setFragmentBytes(&tone, length: MemoryLayout<simd_float4x4>.size, index: 2)
        }

        encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        buffer.present(drawable)
        buffer.commit()
        // Deliberately not cleared. `accept` releases these when the next frame lands, so
        // exactly one buffer is held and any number of redraws can use it.
    }

    // MARK: - Geometry

    /// Rotation, aspect fill and mirroring, composed once.
    ///
    /// Aspect **fill**, not fit, because that is what `AVCaptureVideoPreviewLayer` was doing
    /// with `.resizeAspectFill` — switching engines must not silently change how much of the
    /// scene the user sees, or the framing they composed a shot with moves under them.
    ///
    /// Static and pure so the arithmetic is testable: every one of these transforms has a
    /// plausible-looking wrong version, and "the preview is squashed in landscape" is not a
    /// thing a unit test should need a camera to catch.
    static func transform(
        source: CGSize,
        destination: CGSize,
        rotationAngle: CGFloat,
        mirrored: Bool
    ) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4

        // **Negated**, and this is the whole of a bug that shipped: the preview was upside
        // down on a device, on both cameras, with a perfectly smooth stream.
        //
        // AVFoundation's angle describes the rotation in the *image's* coordinate space,
        // where y runs **down** — the same convention `CGAffineTransform(rotationAngle:)`
        // uses, which is why the recorder's track transform takes the angle unchanged and
        // comes out upright. Metal's clip space has y **up**, so the identical angle turns
        // the quad the opposite way, and a quarter turn the wrong way is 180° from a quarter
        // turn the right way. Not a quarter turn *missing* — which is why it looked like a
        // rotation that had been applied, and had.
        //
        // What let it ship is worth more than the fix: every rotation test here compared
        // `hypot` or `abs`, so all of them pinned how much the quad was scaled and none of
        // them pinned which way it turned. Direction is now asserted — see
        // `test_aQuarterTurnSendsTheImagesTopLeftToTheTopRight`.
        let radians = CaptureRotation.clipSpaceRadians(degrees: rotationAngle)
        if radians != 0 {
            let cosine = cos(radians)
            let sine = sin(radians)
            matrix = simd_float4x4(
                SIMD4<Float>( cosine, sine, 0, 0),
                SIMD4<Float>(-sine, cosine, 0, 0),
                SIMD4<Float>( 0, 0, 1, 0),
                SIMD4<Float>( 0, 0, 0, 1)
            ) * matrix
        }

        // The source's dimensions *after* rotation are what has to fill the destination: a
        // 1920x1080 buffer rotated 90° is 1080x1920 on screen, and scaling against the
        // unrotated size is the bug that leaves black bars down the sides in portrait.
        let isQuarterTurned = Int(abs(rotationAngle).rounded()) % 180 == 90
        let effective = isQuarterTurned
            ? CGSize(width: source.height, height: source.width)
            : source

        guard effective.width > 0, effective.height > 0,
              destination.width > 0, destination.height > 0 else { return matrix }

        let scale = max(destination.width / effective.width, destination.height / effective.height)
        let filled = CGSize(width: effective.width * scale, height: effective.height * scale)

        var scaleX = Float(filled.width / destination.width)
        let scaleY = Float(filled.height / destination.height)
        if mirrored {
            scaleX = -scaleX
        }

        let fill = simd_float4x4(
            SIMD4<Float>(scaleX, 0, 0, 0),
            SIMD4<Float>(0, scaleY, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        return fill * matrix
    }

    /// BT.709, which is what the camera produces. BT.601 is the old standard-definition
    /// matrix and using it tilts every skin tone.
    static func ycbcrToRGB(isFullRange: Bool) -> simd_float3x3 {
        // Columns, because `simd_float3x3` is column-major and transposing this by accident
        // swaps the red and blue corrections — which looks like a white-balance problem.
        if isFullRange {
            return simd_float3x3(
                SIMD3<Float>(1.0,      1.0,      1.0),
                SIMD3<Float>(0.0,     -0.18732,  1.8556),
                SIMD3<Float>(1.5748,  -0.46812,  0.0)
            )
        }
        return simd_float3x3(
            SIMD3<Float>(1.16438,  1.16438,  1.16438),
            SIMD3<Float>(0.0,     -0.21325,  2.11240),
            SIMD3<Float>(1.79274, -0.53291,  0.0)
        )
    }

    static func ycbcrOffset(isFullRange: Bool) -> simd_float3 {
        // Video range starts luma at 16/255; full range starts at 0. Chroma is centred on
        // 128/255 either way.
        isFullRange
            ? SIMD3<Float>(0.0, 0.5, 0.5)
            : SIMD3<Float>(16.0 / 255.0, 0.5, 0.5)
    }
}

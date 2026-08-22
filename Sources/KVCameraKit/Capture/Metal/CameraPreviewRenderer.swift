import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
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
    private let bgraLookPipeline: MTLRenderPipelineState
    private let ycbcrLookPipeline: MTLRenderPipelineState
    private let displayPipeline: MTLRenderPipelineState
    private let lutTextureLoader: CameraLUTTextureLoader
    private var lutTexture: MTLTexture
    private let grainTexture: MTLTexture

    /// Where the look pass writes and the display pass reads.
    ///
    /// Sized to the **camera frame**, not to the drawable, which is the whole point of having
    /// two passes: the expensive stages run once per source pixel per camera frame instead of
    /// once per screen pixel per display refresh. On a Pro screen against a 30 fps 1440x1080
    /// stream that is a quarter of the shading work for an identical picture.
    private var lookTexture: MTLTexture?

    /// What the look pass has already produced, against what it *would* produce now.
    ///
    /// Two counters rather than one, because they have different writers and combining them
    /// would need a lock on the display path. `frameRevision` moves on the frame queue under
    /// `lock`, beside the textures it describes; `configRevision` moves on the main thread in
    /// `configure` and the property setters, which is also where `draw` reads it.
    ///
    /// The look pass re-runs when either moves; the display pass runs whenever the display
    /// asks. So a still scene with the shelf open costs one textured quad per refresh instead
    /// of the entire recipe, and a 30 fps camera stops paying for a 60 Hz screen.
    private var frameRevision: UInt64 = 0
    private var configRevision: UInt64 = 0
    private var renderedRevision: (frame: UInt64, config: UInt64)?
    /// The drawable size the picture currently on screen was drawn for.
    private var presentedDrawableSize: CGSize = .zero

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
        let timestamp: Float
        let colorSpace: CGColorSpace?
    }

    private enum FrameFormat {
        case bgra
        /// Bi-planar YCbCr. `isFullRange` decides the conversion offset, and getting it
        /// wrong looks *almost* right rather than obviously broken.
        case ycbcr(isFullRange: Bool, standard: YCbCrStandard)
    }

    enum YCbCrStandard: Equatable {
        case bt601
        case bt709
        case bt2020
    }

    /// Mirrored horizontally, for the front camera. The preview is a mirror in every camera
    /// app because that is what people expect of their own face; the *capture* is not.
    ///
    /// The mirror is applied by the *display* pass, and folded into the look pass's upright
    /// transform in the opposite direction — so film texture lands where the saved file has it
    /// rather than being flipped along with the scene. A light leak is a property of the stock,
    /// not of what is in front of the lens.
    var isMirrored = false {
        didSet { if isMirrored != oldValue { configRevision &+= 1 } }
    }

    /// The turn that makes the buffer upright in the interface the user is holding, set by the
    /// view that owns the drawable.
    ///
    /// **Not** the angle on the frame. That one is `videoRotationAngleForHorizonLevelCapture`,
    /// which tracks gravity so a *recording* comes out level — and a preview inside a view
    /// UIKit has already rotated does not want it: applying it turned the picture a second
    /// time, so rotating the phone spun the image inside the frame. See
    /// `CaptureRotation.previewAngle(for:)`.
    var previewRotationAngle: CGFloat = 90 {
        didSet { if previewRotationAngle != oldValue { configRevision &+= 1 } }
    }

    /// The look, already composed into one matrix. Set from the screen when the user picks a
    /// filter; read once per frame.
    ///
    /// Held as the matrix rather than as a `CameraTone` so the per-frame path does no
    /// arithmetic, and so the *same value* can be handed to the still renderer — one look, two
    /// destinations, no second implementation to drift.
    var toneMatrix: simd_float4x4 = matrix_identity_float4x4

    /// Mirrors `LookUniform` in `CameraPreview.metal` field for field.
    ///
    /// The two matrix-shaped fields come first because Metal aligns `float2x2` to 8 bytes and
    /// scalars to 4: putting the floats first would leave Swift and Metal free to disagree
    /// about where the padding goes, and a padding disagreement here is not a build error — it
    /// is grain at the wrong intensity, which reads as a shader bug and is not one.
    struct LookUniform {
        /// Sensor texture coordinate (centred on 0.5) → upright image space. See `applyFilm`.
        var uprightRotation: simd_float2x2 = matrix_identity_float2x2
        var uprightSize: SIMD2<Float> = .one
        var imageSize: SIMD2<Float> = .one
        var beautySmoothing: Float = 0
        var beautyBrightness: Float = 0
        var beautyRosy: Float = 0
        var beautyDefinition: Float = 0
        var grainIntensity: Float = 0
        var lightLeakIntensity: Float = 0
        var grainPhase: Float = 0
        var unused: Float = 0
    }

    private var look = LookUniform()
    private var selectedLUTID = CameraLUT.identity.id

    /// Prepares everything that changes when the user selects a look. LUT upload happens on
    /// selection, never on the display-link draw path.
    ///
    /// Called from `updateUIView`, which SwiftUI runs on every re-render of the screen — so
    /// this has to be cheap *and* has to not invalidate the look pass unless something actually
    /// changed. Hence the comparison before the bump: tapping the grid toggle re-renders the
    /// camera screen, and a viewfinder that re-shaded the whole frame for that would be paying
    /// the old cost with extra steps.
    func configure(filter: CameraFilter, beauty: CameraBeauty) {
        let nextTone = filter.tone.colorMatrix
        var changed = nextTone != toneMatrix
        toneMatrix = nextTone

        func set(_ keyPath: WritableKeyPath<LookUniform, Float>, _ value: Float) {
            if look[keyPath: keyPath] != value {
                look[keyPath: keyPath] = value
                changed = true
            }
        }
        set(\.beautySmoothing, beauty.smoothing)
        set(\.beautyBrightness, beauty.brightness)
        set(\.beautyRosy, beauty.rosy)
        set(\.beautyDefinition, beauty.definition)
        set(\.grainIntensity, filter.film.grain)
        set(\.lightLeakIntensity, filter.film.lightLeak)

        let nextID = filter.lut?.id ?? CameraLUT.identity.id
        if nextID != selectedLUTID, let texture = lutTextureLoader.texture(for: filter.lut) {
            lutTexture = texture
            selectedLUTID = nextID
            changed = true
        }

        if changed { configRevision &+= 1 }
    }

    /// The censor look, set from the screen when the user picks one.
    var censorMode: CameraCensorMode = .off {
        didSet { if censorMode != oldValue { configRevision &+= 1 } }
    }

    var faceEffect: CameraFaceEffect = .off {
        didSet { if faceEffect != oldValue { configRevision &+= 1 } }
    }

    /// Where the face geometry comes from, asked **once per drawn frame**.
    ///
    /// A closure rather than a stored array, and that is not a style choice. The regions are
    /// produced on the detector's own queue at whatever rate Vision manages, while a stored
    /// property on a `UIViewRepresentable` is only refreshed when SwiftUI decides to call
    /// `updateUIView` — which for a value nothing in `CameraState` mentions is approximately
    /// never. Pulled here, the viewfinder always draws the newest geometry; pushed, it would
    /// draw whichever geometry happened to be current the last time an unrelated piece of
    /// state changed.
    var censorRegions: (@Sendable () -> [CensorRegion])?

    /// One face, packed for the shader. Mirrors `CensorEllipse` in `CameraPreview.metal` field
    /// for field.
    ///
    /// Explicit trailing padding rather than trusting two compilers to agree: Swift and Metal
    /// both align `SIMD2<Float>`/`float2` to 8 bytes, so a struct ending in a single `Float`
    /// has four bytes of tail padding either way — but "either way" is doing a lot of work in
    /// that sentence, and a layout mismatch here is not a build error. It is a censor drawn
    /// somewhere else in the frame, which looks like a coordinate bug and is not one.
    struct CensorEllipseUniform {
        var center: SIMD2<Float> = .zero
        var radius: SIMD2<Float> = .zero
        var rollSinCos: SIMD2<Float> = .zero
        var mode: Float = 0
        var unused: Float = 0
    }

    struct CensorHeaderUniform {
        var imageSize: SIMD2<Float> = .zero
        var count: Int32 = 0
        var faceEffect: Int32 = 0
    }

    /// The uniforms for one frame.
    ///
    /// Static and pure so the packing is testable without a Metal device — the same reason
    /// `transform` is. Always returns a full-length array: `setFragmentBytes` rejects a zero
    /// length, so "no faces" is a header with `count == 0` beside a buffer of unused slots
    /// rather than no buffer at all.
    static func censorUniforms(
        mode: CameraCensorMode,
        faceEffect: CameraFaceEffect = .off,
        regions: [CensorRegion],
        sourceSize: CGSize
    ) -> (header: CensorHeaderUniform, ellipses: [CensorEllipseUniform]) {
        var ellipses = [CensorEllipseUniform](repeating: CensorEllipseUniform(), count: CensorTracker.maximumRegions)
        var header = CensorHeaderUniform(
            imageSize: SIMD2<Float>(Float(sourceSize.width), Float(sourceSize.height)),
            count: 0,
            faceEffect: Int32(faceEffect.shaderCode)
        )

        guard mode.isEnabled || faceEffect.isEnabled else { return (header, ellipses) }

        for (index, region) in regions.prefix(CensorTracker.maximumRegions).enumerated() {
            ellipses[index] = CensorEllipseUniform(
                center: SIMD2<Float>(Float(region.center.x), Float(region.center.y)),
                radius: SIMD2<Float>(Float(region.radius.width), Float(region.radius.height)),
                rollSinCos: SIMD2<Float>(Float(sin(region.roll)), Float(cos(region.roll))),
                mode: Float(mode.shaderCode)
            )
            header.count = Int32(index + 1)
        }
        return (header, ellipses)
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        let lutTextureLoader = CameraLUTTextureLoader(device: device)
        guard let lutTexture = lutTextureLoader.texture(for: nil),
              let grainTexture = Self.makeGrainTexture(device: device) else { return nil }

        // The `.metal` file is compiled by SwiftPM into the package's own bundle, so the
        // default library of `Bundle.main` is the wrong place to look — that is the host app.
        guard let library = try? device.makeDefaultLibrary(bundle: .module),
              let vertexFunction = library.makeFunction(name: "cameraPreviewVertex"),
              let bgraFunction = library.makeFunction(name: "cameraLookFragmentBGRA"),
              let ycbcrFunction = library.makeFunction(name: "cameraLookFragmentYCbCr"),
              let displayFunction = library.makeFunction(name: "cameraDisplayFragment")
        else { return nil }

        func pipeline(fragment: MTLFunction, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let bgraPipeline = pipeline(fragment: bgraFunction, pixelFormat: Self.lookPixelFormat),
              let ycbcrPipeline = pipeline(fragment: ycbcrFunction, pixelFormat: Self.lookPixelFormat),
              let displayPipeline = pipeline(fragment: displayFunction, pixelFormat: .bgra8Unorm) else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.bgraLookPipeline = bgraPipeline
        self.ycbcrLookPipeline = ycbcrPipeline
        self.displayPipeline = displayPipeline
        self.lutTextureLoader = lutTextureLoader
        self.lutTexture = lutTexture
        self.grainTexture = grainTexture
        self.textureCache = textureCache
    }

    /// Uploads the one emulsion field used by Core Image, byte for byte.
    private static func makeGrainTexture(device: MTLDevice) -> MTLTexture? {
        let dimension = CameraFilmSimulation.grainTileDimension
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        CameraFilmSimulation.grainTileBytes.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, dimension, dimension),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: dimension
            )
        }
        texture.label = "KVCameraKit shared film emulsion"
        return texture
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
        // Bumped under the same lock that publishes the frame, so a draw can never see the new
        // textures with the old revision and skip the pass that would have used them.
        frameRevision &+= 1
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
            isMirrored: isMirrored,
            timestamp: Self.timestamp(for: frame),
            colorSpace: CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
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
            format: .ycbcr(
                isFullRange: isFullRange,
                standard: Self.ycbcrStandard(
                    attachment: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
                    width: Int(size.width)
                )
            ),
            rotationAngle: frame.rotationAngle ?? 0,
            sourceSize: size,
            isMirrored: isMirrored,
            timestamp: Self.timestamp(for: frame),
            colorSpace: CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue()
        )
    }

    private static func timestamp(for frame: CameraFrame) -> Float {
        let seconds = frame.presentationTime.seconds
        return seconds.isFinite ? Float(seconds) : 0
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

    /// The pixel format both passes render into.
    ///
    /// Film grain is deliberately subtler than one 8-bit code value for fine-grain stocks.
    /// Keeping the look pass in half-float preserves that modulation until the final display
    /// conversion; writing it straight into BGRA8 quantised Portra's texture back out.
    static let lookPixelFormat: MTLPixelFormat = .rgba16Float

    /// Called by the display link, which runs faster than the camera and does not stop when
    /// the camera does.
    ///
    /// So the first thing it does is work out whether there is anything to draw. A `MTKView`
    /// asks up to 120 times a second; a photo session delivers 30 frames. The three-quarters of
    /// calls that would re-present an identical picture return here, before a drawable is even
    /// acquired — the one already on screen stays there, which is both correct and free.
    ///
    /// Returning early rather than drawing anyway is what makes the display link affordable.
    /// The alternative — pushing draws from the frame queue — means `MTKView` being driven from
    /// a thread it is not documented as safe on, and a viewfinder is a poor place to find out.
    func draw(in view: MTKView) {
        lock.lock()
        let frame = pending
        let frameRevision = self.frameRevision
        lock.unlock()

        guard let frame else { return }

        let drawableSize = view.drawableSize
        let wanted = (frame: frameRevision, config: configRevision)
        let lookIsStale = renderedRevision == nil || renderedRevision! != wanted
        // A resize hands back a fresh, empty drawable pool, so the picture has to be redrawn
        // even when the look has not changed — this is the black-viewfinder-on-re-layout bug
        // that `pending` is retained for, and skipping the draw would reintroduce it.
        let sizeChanged = presentedDrawableSize != drawableSize

        guard lookIsStale || sizeChanged else { return }

        // Preserve the primaries carried by the camera buffer (sRGB/P3/BT.2020) so Core
        // Animation performs the same display conversion as the system preview and the
        // Core Image thumbnail path. sRGB is the safe fallback for an untagged frame.
        //
        // Assigned only on a change: writing `CAMetalLayer.colorspace` re-creates the drawable
        // pool, and this used to run on every single frame.
        let colorSpace = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        if let layer = view.layer as? CAMetalLayer, layer.colorspace != colorSpace {
            layer.colorspace = colorSpace
        }

        guard let target = lookTarget(for: frame.sourceSize),
              let displayDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer()
        else { return }

        // Everything expensive lives behind this `if`. `lookTarget` may have cleared
        // `renderedRevision` by handing back a new texture, so it is re-read rather than reused.
        if renderedRevision == nil || renderedRevision! != wanted {
            encodeLookPass(into: target, frame: frame, buffer: buffer)
            renderedRevision = wanted
        }

        encodeDisplayPass(
            from: target,
            frame: frame,
            descriptor: displayDescriptor,
            drawableSize: drawableSize,
            buffer: buffer
        )

        buffer.present(drawable)
        buffer.commit()
        presentedDrawableSize = drawableSize
        // `pending` is deliberately not cleared. `accept` releases it when the next frame
        // lands, so exactly one buffer is held and any number of redraws can use it.
    }

    /// The offscreen texture, made on the first frame and remade when the frame's size changes.
    ///
    /// A size change is a camera switch or a format change, not something that happens per
    /// frame — so allocating here rather than pre-emptively costs one allocation per session.
    private func lookTarget(for size: CGSize) -> MTLTexture? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)

        if let existing = lookTexture, existing.width == width, existing.height == height {
            return existing
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.lookPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        // Never read by the CPU and never needed after the frame it is displayed in, so it can
        // live in tile memory on Apple silicon rather than in system memory.
        descriptor.storageMode = .private

        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "KVCameraKit look \(width)x\(height)"
        lookTexture = texture
        // A new target holds nothing, so whatever was rendered into the old one is not a
        // reason to skip the pass.
        renderedRevision = nil
        return texture
    }

    /// Censor, tone, LUT, beauty and film, at the frame's own resolution.
    private func encodeLookPass(into target: MTLTexture, frame: PendingFrame, buffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        // Every texel is written by the quad, so there is nothing worth loading.
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "KVCameraKit look pass"

        // Identity: this pass draws the frame into a texture the same shape as the frame.
        // Rotation, aspect fill and mirroring are the display pass's business.
        var transform = matrix_identity_float4x4
        var tone = toneMatrix

        var frameLook = look
        frameLook.imageSize = SIMD2<Float>(Float(frame.sourceSize.width), Float(frame.sourceSize.height))
        let upright = Self.uprightSize(source: frame.sourceSize, rotationAngle: previewRotationAngle)
        frameLook.uprightSize = SIMD2<Float>(Float(upright.width), Float(upright.height))
        frameLook.uprightRotation = Self.uprightRotation(
            rotationAngle: previewRotationAngle,
            mirrored: frame.isMirrored
        )
        frameLook.grainPhase = Self.grainPhase(for: frame.timestamp)

        // Pulled now rather than stored — see `censorRegions`. Geometry is in normalised
        // sensor-buffer space, which is exactly what `texCoord` is, so nothing is converted
        // here and the mirroring and rotation of the display pass carry the censor along with
        // the picture for free.
        var censor = Self.censorUniforms(
            mode: censorMode,
            faceEffect: faceEffect,
            regions: (censorMode.isEnabled || faceEffect.isEnabled) ? (censorRegions?() ?? []) : [],
            sourceSize: frame.sourceSize
        )
        let ellipseStride = MemoryLayout<CensorEllipseUniform>.stride * censor.ellipses.count

        switch frame.format {
        case .bgra:
            encoder.setRenderPipelineState(bgraLookPipeline)
            encoder.setFragmentTexture(frame.textures[0], index: 0)
            encoder.setFragmentTexture(lutTexture, index: 1)
            encoder.setFragmentTexture(grainTexture, index: 2)
            encoder.setFragmentBytes(&tone, length: MemoryLayout<simd_float4x4>.size, index: 0)
            encoder.setFragmentBytes(&frameLook, length: MemoryLayout<LookUniform>.stride, index: 1)
            encoder.setFragmentBytes(&censor.header, length: MemoryLayout<CensorHeaderUniform>.stride, index: 2)
            encoder.setFragmentBytes(&censor.ellipses, length: ellipseStride, index: 3)

        case .ycbcr(let isFullRange, let standard):
            encoder.setRenderPipelineState(ycbcrLookPipeline)
            encoder.setFragmentTexture(frame.textures[0], index: 0)
            encoder.setFragmentTexture(frame.textures[1], index: 1)
            encoder.setFragmentTexture(lutTexture, index: 2)
            encoder.setFragmentTexture(grainTexture, index: 3)
            var conversion = Self.ycbcrToRGB(isFullRange: isFullRange, standard: standard)
            var offset = Self.ycbcrOffset(isFullRange: isFullRange)
            encoder.setFragmentBytes(&conversion, length: MemoryLayout<simd_float3x3>.size, index: 0)
            encoder.setFragmentBytes(&offset, length: MemoryLayout<simd_float3>.size, index: 1)
            encoder.setFragmentBytes(&tone, length: MemoryLayout<simd_float4x4>.size, index: 2)
            encoder.setFragmentBytes(&frameLook, length: MemoryLayout<LookUniform>.stride, index: 3)
            encoder.setFragmentBytes(&censor.header, length: MemoryLayout<CensorHeaderUniform>.stride, index: 4)
            encoder.setFragmentBytes(&censor.ellipses, length: ellipseStride, index: 5)
        }

        encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// The finished frame, turned the right way up and filled to the drawable.
    private func encodeDisplayPass(
        from target: MTLTexture,
        frame: PendingFrame,
        descriptor: MTLRenderPassDescriptor,
        drawableSize: CGSize,
        buffer: MTLCommandBuffer
    ) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "KVCameraKit display pass"

        var transform = Self.transform(
            source: frame.sourceSize,
            destination: drawableSize,
            rotationAngle: previewRotationAngle,
            mirrored: frame.isMirrored
        )

        encoder.setRenderPipelineState(displayPipeline)
        encoder.setFragmentTexture(target, index: 0)
        encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// How far the grain pattern has moved, from the frame's presentation time.
    ///
    /// Quantised to whole steps at 24 Hz on purpose. Grain that advances by a fraction of a
    /// cell every frame does not shimmer, it *crawls* — the pattern slides across the picture
    /// like a texture on a conveyor, which is the one thing real film grain never does. Whole
    /// steps re-roll the field instead of translating it, and 24 Hz is slower than the display
    /// so it reads as film rather than as noise.
    static func grainPhase(for timestamp: Float) -> Float {
        (timestamp * 24).rounded(.down)
    }

    /// The upright image's pixel size — the frame's, axes swapped on a quarter turn.
    static func uprightSize(source: CGSize, rotationAngle: CGFloat) -> CGSize {
        Int(abs(rotationAngle).rounded()) % 180 == 90
            ? CGSize(width: source.height, height: source.width)
            : source
    }

    /// Sensor texture coordinates, centred on 0.5, into the **upright** image's own space.
    ///
    /// The inverse of the turn `CensorGeometry.sensorRegion` applies, and it has to stay that
    /// way: both describe the same relationship between the buffer the shader samples and the
    /// picture a person sees, one for face geometry and one for film texture.
    ///
    /// `mirrored` is folded in **backwards**. The display pass mirrors the front camera, so a
    /// leak placed in plain upright space would arrive on screen flipped from where the same
    /// preset puts it on the saved file — and the file is not mirrored. Flipping here cancels
    /// the flip there, which is what makes the viewfinder and the photo agree about which side
    /// of the frame the light came in.
    static func uprightRotation(rotationAngle: CGFloat, mirrored: Bool) -> simd_float2x2 {
        let turns = ((Int((rotationAngle / 90).rounded()) % 4) + 4) % 4

        // Columns. `M * v` is `col0 * v.x + col1 * v.y`, so a row of this matrix is spread
        // across both columns — which is exactly the transpose mistake that turns a quarter
        // turn into the other quarter turn.
        var columns: (SIMD2<Float>, SIMD2<Float>)
        switch turns {
        case 1:  columns = (SIMD2<Float>(0, 1), SIMD2<Float>(-1, 0))
        case 2:  columns = (SIMD2<Float>(-1, 0), SIMD2<Float>(0, -1))
        case 3:  columns = (SIMD2<Float>(0, -1), SIMD2<Float>(1, 0))
        default: columns = (SIMD2<Float>(1, 0), SIMD2<Float>(0, 1))
        }

        if mirrored {
            columns.0.x = -columns.0.x
            columns.1.x = -columns.1.x
        }
        return simd_float2x2(columns.0, columns.1)
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

    /// Uses the matrix attached to each buffer. Core Image already honours this for the
    /// filter thumbnails; hard-coding BT.709 here is why the live preview had different skin
    /// tones from both those thumbnails and `AVCaptureVideoPreviewLayer`.
    static func ycbcrToRGB(
        isFullRange: Bool,
        standard: YCbCrStandard = .bt709
    ) -> simd_float3x3 {
        // Columns, because `simd_float3x3` is column-major and transposing this by accident
        // swaps the red and blue corrections — which looks like a white-balance problem.
        switch (standard, isFullRange) {
        case (.bt601, true):
            return Self.ycbcrMatrix(y: 1, cbGreen: -0.344136, cbBlue: 1.772, crRed: 1.402, crGreen: -0.714136)
        case (.bt601, false):
            return Self.ycbcrMatrix(y: 1.16438, cbGreen: -0.39176, cbBlue: 2.01723, crRed: 1.59603, crGreen: -0.81297)
        case (.bt709, true):
            return Self.ycbcrMatrix(y: 1, cbGreen: -0.18732, cbBlue: 1.8556, crRed: 1.5748, crGreen: -0.46812)
        case (.bt709, false):
            return Self.ycbcrMatrix(y: 1.16438, cbGreen: -0.21325, cbBlue: 2.11240, crRed: 1.79274, crGreen: -0.53291)
        case (.bt2020, true):
            return Self.ycbcrMatrix(y: 1, cbGreen: -0.16455, cbBlue: 1.8814, crRed: 1.4746, crGreen: -0.57135)
        case (.bt2020, false):
            return Self.ycbcrMatrix(y: 1.16438, cbGreen: -0.18733, cbBlue: 2.14177, crRed: 1.67867, crGreen: -0.65042)
        }
    }

    static func ycbcrStandard(attachment: CFTypeRef?, width: Int) -> YCbCrStandard {
        if let attachment {
            if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { return .bt601 }
            if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_2020) { return .bt2020 }
            if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2) { return .bt709 }
        }
        // Core Video's conventional fallback when the attachment is missing.
        return width >= 1_280 ? .bt709 : .bt601
    }

    private static func ycbcrMatrix(
        y: Float,
        cbGreen: Float,
        cbBlue: Float,
        crRed: Float,
        crGreen: Float
    ) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(y, y, y),
            SIMD3<Float>(0, cbGreen, cbBlue),
            SIMD3<Float>(crRed, crGreen, 0)
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

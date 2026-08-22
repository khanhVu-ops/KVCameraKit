import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Rewrites a frame's pixels before the recorder appends it.
///
/// This exists because of what the first censor implementation did not do. It censored the
/// viewfinder — with a SwiftUI overlay that did not touch the camera's pixels at all — and it
/// censored a captured still. A recording it left completely alone: `grep censor` over
/// `AssetWriterRecorder` found nothing. So with the feature switched on, a video came out of the
/// vault with every face in it perfectly legible, and the only thing that had ever suggested
/// otherwise was an overlay drawn on top of the preview while it recorded.
///
/// That is the worst shape a privacy bug can take. Nothing failed, nothing was logged, and the
/// screen actively said the opposite of the truth for the whole duration of the recording.
///
/// Two properties of the implementation are load-bearing:
///
/// **A frame with no faces is returned untouched.** Not re-rendered, not re-encoded — the same
/// `CMSampleBuffer` object. Censoring is mostly idle: a subject enters, is covered, leaves. Paying
/// a full-frame Core Image render on frames with nothing to hide would be paying it nearly always.
///
/// **The buffer is a copy, into a pool.** The source belongs to AVFoundation's finite pool and
/// rendering into it in place would hand a mutated buffer to whatever else is reading the same
/// frame — the viewfinder, on the same stream. Which would look like the censor working
/// perfectly, right up until the two disagreed about timing.
final class CensorVideoStage: @unchecked Sendable {

    /// Unmanaged, matching `ToneRenderer` and the shader: the effect operates on the same
    /// gamma-encoded values the preview does. Colour-managing here would make every recorded
    /// frame differ from the viewfinder it was composed in.
    /// Shared for the camera session instead of rebuilt per recording. Constructing a
    /// `CIContext` creates a Metal command queue and its first render compiles the distortion
    /// graph; doing either on the first recorded frame is the 1–2 second opening hitch this
    /// stage must avoid.
    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    fileprivate struct WarmupRecipe: Hashable, Sendable {
        let mode: CameraCensorMode
        let faceEffect: CameraFaceEffect
    }

    private static let warmupCoordinator = CensorVideoWarmupCoordinator()

    /// Compiles the selected Core Image graph before the writer accepts its first sample.
    /// Calls for the same recipe coalesce, so selecting an effect and then immediately tapping
    /// record waits for the existing warm-up rather than compiling it twice.
    static func prepare(mode: CameraCensorMode, faceEffect: CameraFaceEffect) async {
        guard mode.isEnabled || faceEffect.isEnabled else { return }
        let recipe = WarmupRecipe(mode: mode, faceEffect: faceEffect)
        await warmupCoordinator.prepare(recipe) {
            performWarmup(recipe)
        }
    }

    /// Starts preparation when a mode is selected. `CameraService.prepareRecordingEffects()`
    /// still awaits the same task at record time, closing the race when the user taps record
    /// immediately after choosing the effect.
    static func schedulePreparation(mode: CameraCensorMode, faceEffect: CameraFaceEffect) {
        guard mode.isEnabled || faceEffect.isEnabled else { return }
        Task.detached(priority: .userInitiated) {
            await prepare(mode: mode, faceEffect: faceEffect)
        }
    }

    /// Set once, before the recording starts.
    var mode: CameraCensorMode = .off
    /// A playful warp can compose with a censor and uses the same face regions.
    var faceEffect: CameraFaceEffect = .off
    /// Read per frame — the geometry is produced on the detector's queue and this is called on
    /// the writer's, so the newest value is the only correct one to use.
    var regions: (@Sendable () -> [CensorRegion])?

    /// Writer queue only, all three. The recorder calls `process` from one serial queue, which
    /// is what makes a pool with no lock around it correct.
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0
    private var poolDimensions = CGSize.zero
    private var outputFormat: CMFormatDescription?

    /// The frame to append, censored — or the frame that came in, when there is nothing to do.
    ///
    /// Never `nil` for a failure: a stage that cannot render returns the original rather than
    /// dropping the frame. A dropped frame is a recording that plays fast, and a censor that
    /// silently drops frames when it fails is worse than one that visibly does nothing.
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard (mode.isEnabled || faceEffect.isEnabled),
              let faces = regions?(), !faces.isEmpty,
              let source = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return sampleBuffer }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = renderableFormat(CVPixelBufferGetPixelFormatType(source))

        guard let pool = pool(for: format, width: width, height: height) else { return sampleBuffer }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return sampleBuffer }

        let image = CIImage(cvPixelBuffer: source)
        let warped = FaceEffectRenderer.render(image: image, effect: faceEffect, regions: faces)
        let censored = CensorRenderer.render(image: warped, mode: mode, regions: faces)
        Self.context.render(
            censored,
            to: destination,
            bounds: image.extent,
            // `nil`, to match the unmanaged working space above. Passing a colour space here
            // converts, which is the change that makes a recording not match its preview.
            colorSpace: nil
        )

        guard let description = formatDescription(for: destination) else { return sampleBuffer }

        // Timing comes off the original, unchanged. Deriving it instead — from a frame counter,
        // or from a clock read here — is how a recording ends up a frame short or a few
        // milliseconds out of sync with its audio.
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else {
            return sampleBuffer
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: destination,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &output
        ) == noErr, let output else { return sampleBuffer }

        return output
    }

    /// Releases the pool. Called at stop so a finished recording does not hold a few 4K buffers
    /// for the rest of the session.
    func reset() {
        pool = nil
        poolFormat = 0
        poolDimensions = .zero
        outputFormat = nil
    }

    // MARK: - Pool

    /// A format `CIContext.render(_:to:bounds:colorSpace:)` accepts.
    ///
    /// The sensor's own bi-planar YCbCr is kept where possible, because it is what the HEVC
    /// encoder wants and converting to BGRA and back is two conversions bought to change
    /// nothing. Anything unrecognised becomes BGRA, which every path accepts — the writer will
    /// convert it on the way into the encoder.
    private func renderableFormat(_ format: OSType) -> OSType {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_32BGRA:
            return format
        default:
            return kCVPixelFormatType_32BGRA
        }
    }

    private func pool(for format: OSType, width: Int, height: Int) -> CVPixelBufferPool? {
        let dimensions = CGSize(width: width, height: height)
        if let pool, poolFormat == format, poolDimensions == dimensions {
            return pool
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // Without this the buffers are not IOSurface-backed, which turns the render and the
            // encode into CPU copies.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        // A handful, not one: the encoder holds a frame while the next is being rendered, and a
        // pool of one stalls the writer queue waiting for its own output to be released.
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4
        ]

        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess else { return nil }

        pool = created
        poolFormat = format
        poolDimensions = dimensions
        // The description describes the pool's buffers, so it is stale the moment the pool is.
        outputFormat = nil
        return created
    }

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        if let outputFormat { return outputFormat }
        var created: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &created
        ) == noErr else { return nil }
        outputFormat = created
        return created
    }

    /// A tiny procedural frame is sufficient to force Core Image/Metal kernel compilation.
    /// It deliberately exercises the real face graph, but not at camera resolution: shader
    /// compilation is resolution-independent, while shading a throwaway 4K warm-up would only
    /// move the hitch rather than remove it.
    private static func performWarmup(_ recipe: WarmupRecipe) {
        let dimension = 192
        let scalarDimension = CGFloat(dimension)
        let extent = CGRect(x: 0, y: 0, width: scalarDimension, height: scalarDimension)
        let source = (CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: scalarDimension / 2, y: scalarDimension / 2),
            "inputColor0": CIColor(red: 0.92, green: 0.34, blue: 0.18),
            "inputColor1": CIColor(red: 0.10, green: 0.42, blue: 0.88),
            "inputWidth": 12
        ])?.outputImage ?? CIImage(color: .gray)).cropped(to: extent)
        let region = CensorRegion(
            id: 0,
            center: CGPoint(x: 0.5, y: 0.5),
            radius: CGSize(width: 0.27, height: 0.34),
            roll: 0.12
        )
        let warped = FaceEffectRenderer.render(
            image: source,
            effect: recipe.faceEffect,
            regions: [region]
        )
        let rendered = CensorRenderer.render(
            image: warped,
            mode: recipe.mode,
            regions: [region]
        )

        // Simulator fixtures are BGRA, while devices normally deliver one of the two
        // bi-planar YUV ranges. Warm every destination family at a tiny size so the device's
        // first real frame does not discover an uncompiled colour-conversion pipeline.
        let formats: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        for format in formats {
            var destination: CVPixelBuffer?
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                dimension,
                dimension,
                format,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                &destination
            ) == kCVReturnSuccess, let destination else { continue }
            context.render(rendered, to: destination, bounds: extent, colorSpace: nil)
        }
    }
}

/// One task per selected recipe. An actor keeps selection-time preparation and record-time
/// waiting race-free without putting a lock around Core Image rendering.
private actor CensorVideoWarmupCoordinator {
    private var completed: Set<CensorVideoStage.WarmupRecipe> = []
    private var inFlight: [CensorVideoStage.WarmupRecipe: Task<Void, Never>] = [:]

    func prepare(
        _ recipe: CensorVideoStage.WarmupRecipe,
        work: @escaping @Sendable () -> Void
    ) async {
        if completed.contains(recipe) { return }
        if let task = inFlight[recipe] {
            await task.value
            return
        }

        let task = Task.detached(priority: .userInitiated) { work() }
        inFlight[recipe] = task
        await task.value
        inFlight[recipe] = nil
        completed.insert(recipe)
    }
}

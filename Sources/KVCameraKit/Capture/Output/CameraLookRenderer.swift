import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The whole recipe, in Core Image, for the two places a fragment shader cannot reach: a
/// captured still and the chips on the filter strip.
///
/// **Face warp → censor → tone → LUT → beauty → film.** That order is the
/// contract with `CameraPreview.metal`, and it is the fix for the worst class of bug this file
/// can have. Until now the shader censored first and the capture path censored *last*, each
/// with a comment claiming it matched the other — so a censor bar under Film Noir came out grey
/// in the viewfinder and black in the file, from one tap on one control.
///
/// One decode and one encode, which is the other half of the same fix. The capture path used to
/// be two functions called in sequence: the look renderer encoded a JPEG and the censor renderer
/// decoded that JPEG and encoded another. Two lossy generations to apply two effects to one
/// photograph, plus an HEIC turned into a JPEG twice over.
enum CameraLookRenderer {

    /// Built once. A `CIContext` carries compiled kernels and a command queue, and stills
    /// arrive one shutter press at a time — rebuilding it per photo was measurable.
    ///
    /// **No colour management**, and that is load-bearing rather than a default nobody changed:
    /// `workingColorSpace: NSNull()` makes the tone matrix and the LUT multiply the same
    /// gamma-encoded values the shader multiplies. Core Image's default is to convert to linear
    /// light first, which is more defensible photographically and would silently make every
    /// photo differ from the viewfinder it was composed in.
    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    /// The exact emulsion field also uploaded by `CameraPreviewRenderer`.
    nonisolated(unsafe) private static let grainTile: CIImage? = {
        let dimension = CameraFilmSimulation.grainTileDimension
        let bytes = Data(CameraFilmSimulation.grainTileBytes)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: dimension,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        return CIImage(cgImage: image)
    }()

    /// Encoded bytes for a captured still, with the look and the censor both applied.
    ///
    /// `regions` are the geometry the viewfinder was drawing, in normalised sensor-buffer space.
    /// Passing them in rather than re-detecting is worth a paragraph: `CensorRenderer.apply` used
    /// to run Vision over the full-resolution still, which costs hundreds of milliseconds on the
    /// shutter path and can disagree with what the user just watched being censored. The live
    /// tracker's regions are what was on screen, so they are what the file gets — and a second
    /// detection pass still runs, on a downscale, and is *unioned* in. Either source finding a
    /// face is enough; a face in the file that neither found is the only failure that matters and
    /// two chances at it is strictly better than one.
    ///
    /// Returns `nil` rather than the original on failure, deliberately: silently storing an
    /// *unfiltered* photo when the user picked a look is the same class of lie as a preview that
    /// disagrees with the file.
    static func apply(
        filter: CameraFilter,
        beauty: CameraBeauty,
        faceEffect: CameraFaceEffect = .off,
        censorMode: CameraCensorMode = .off,
        liveRegions: [CensorRegion] = [],
        to data: Data,
        sourceExposureCompensation: Float = 0,
        quality: CGFloat = 0.95
    ) -> (data: Data, fileExtension: String)? {
        let wantsLook = !filter.isNeutral || beauty.isEnabled
        guard wantsLook || faceEffect.isEnabled || censorMode.isEnabled else {
            return (data, CapturedPhotoDecoder.fileExtension(for: data))
        }
        guard let source = CIImage(data: data) else { return nil }

        // Rendered in **sensor space** — the decoded buffer as it lies, landscape whichever way
        // the phone was held, with its orientation still only an EXIF tag. Not because that is
        // convenient but because it is the space `CensorRegion` is defined in, and the whole
        // reason that type states its space in its first paragraph is that converting per
        // consumer is how a censor ends up 90° out. The turn is applied to the finished pixels,
        // below, which is also the last moment at which the EXIF tag still means anything.
        let orientation = CapturedPhotoDecoder.orientation(for: data)
        let rotationDegrees = CensorGeometry.rotationDegrees(for: orientation)

        let regions = (censorMode.isEnabled || faceEffect.isEnabled)
            ? censorRegions(live: liveRegions, in: source)
            : []

        // Nothing to do and nothing detected: hand the original bytes back rather than paying a
        // re-encode to change nothing. This is what keeps a censor-on photo of an empty room an
        // untouched HEIC.
        guard wantsLook || !regions.isEmpty else {
            return (data, CapturedPhotoDecoder.fileExtension(for: data))
        }

        let matchedSource = sourceExposureCompensation.magnitude > 0.001
            ? source.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: sourceExposureCompensation
            ])
            : source
        let rendered = render(
            matchedSource,
            filter: filter,
            beauty: beauty,
            faceEffect: faceEffect,
            censorMode: censorMode,
            regions: regions,
            rotationDegrees: rotationDegrees,
            grainSeed: 0.37
        ).cropped(to: source.extent)

        // Upright, and re-tagged as such. A look rendered into new pixels loses the orientation
        // metadata the camera wrote, so a portrait that is not turned here is saved sideways.
        let oriented = rendered.oriented(forExifOrientation: Int32(orientation.rawValue))
        let upright = oriented
            .transformed(by: CGAffineTransform(
                translationX: -oriented.extent.origin.x,
                y: -oriented.extent.origin.y
            ))
            .settingProperties([kCGImagePropertyOrientation as String: 1])

        return encode(upright, like: data, colorSpace: source.colorSpace, quality: quality)
    }

    /// The full-resolution photo and AVFoundation's preview representation can be tone-mapped
    /// differently even though they came from one shutter press. Match their scene brightness
    /// before the common look is applied, otherwise the same matrix/LUT correctly produces two
    /// differently bright results from two differently bright inputs.
    static func exposureCompensation(captured: Data, reference: Data) -> Float {
        guard let capturedImage = CIImage(data: captured),
              let referenceImage = CIImage(data: reference),
              let capturedLuma = logAverageLuminance(capturedImage),
              let referenceLuma = logAverageLuminance(referenceImage),
              capturedLuma > 0.001,
              referenceLuma > 0.001 else { return 0 }

        // Half a stop is enough to reconcile Apple's two output representations without
        // turning this into auto-enhance or fighting an intentional exposure choice.
        return min(max(log2(referenceLuma / capturedLuma), -0.5), 0.5)
    }

    /// One look per filter, from the same base frame, for the filter strip.
    ///
    /// The censor is deliberately absent: a chip is 62 points wide and exists to show what the
    /// *colour* of a preset does. A mosaic at that size is four grey blocks, and it would be
    /// identical on every chip.
    static func thumbnails(
        base: CGImage,
        filters: [CameraFilter],
        beauty: CameraBeauty = .off
    ) -> [CGImage] {
        let source = CIImage(cgImage: base)
        return filters.map { filter in
            guard !filter.isNeutral || beauty.isEnabled else { return base }
            // A fixed seed rather than one derived from the filter's position on the strip.
            // Position-derived seeds meant scrolling to a different tab changed a preset's grain,
            // and neither seed matched the still.
            let output = render(
                source,
                filter: filter,
                beauty: beauty,
                faceEffect: .off,
                censorMode: .off,
                regions: [],
                // The base frame is already upright — `ToneRenderer.thumbnailBase` turns it —
                // so the film stage has nothing left to turn.
                rotationDegrees: 0,
                grainSeed: 0.37
            )
            return context.createCGImage(output, from: source.extent) ?? base
        }
    }

    /// The stages, in the shader's order.
    ///
    /// `rotationDegrees` is the clockwise turn that would make `source` upright — `0` for an
    /// image that already is. It exists for the film stage and for nothing else: grain is sized
    /// against the **upright** height and the light leak is positioned in the **upright** frame,
    /// so a sideways buffer with a rotation of zero puts the leak on the wrong edge. Which is
    /// exactly what the shader was doing, and why the same preset leaked from the bottom of the
    /// viewfinder and from the right of the chip beside it.
    static func render(
        _ source: CIImage,
        filter: CameraFilter,
        beauty: CameraBeauty,
        faceEffect: CameraFaceEffect = .off,
        censorMode: CameraCensorMode = .off,
        regions: [CensorRegion] = [],
        rotationDegrees: CGFloat = 0,
        grainSeed: Float
    ) -> CIImage {
        let warped = FaceEffectRenderer.render(image: source, effect: faceEffect, regions: regions)
        let censored = CensorRenderer.renderDestructive(image: warped, mode: censorMode, regions: regions)

        let toned = filter.tone.isNeutral
            ? censored
            : censored.applyingFilter("CIColorMatrix", parameters: ToneRenderer.parameters(for: filter.tone.colorMatrix))
        let graded = filter.lut.map { apply($0, to: toned) } ?? toned

        let smoothed = beauty.isEnabled
            ? applyBeauty(
                beauty,
                sourceForMask: censored,
                to: graded,
                censorMask: CensorRenderer.destructiveCoverageMask(
                    mode: censorMode,
                    regions: regions,
                    extent: source.extent
                )
            )
            : graded

        let textured = applyFilm(
            filter.film,
            to: smoothed,
            extent: source.extent,
            rotationDegrees: rotationDegrees,
            seed: grainSeed
        )
        return CensorRenderer.renderBar(image: textured, mode: censorMode, regions: regions)
            .cropped(to: source.extent)
    }

    // MARK: - Stages

    private static func apply(_ lut: CameraLUT, to image: CIImage) -> CIImage {
        image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": lut.dimension,
            "inputCubeData": lut.coreImageData
        ])
    }

    /// Skin-gated smoothing, brightening, warmth and local contrast.
    ///
    /// The skin mask is read from the **censored** image rather than the original, so a mosaicked
    /// face does not register as skin to begin with, and `censorMask` then removes what is left.
    /// Belt and braces on purpose: this is the stage that could sample detail back into a censor.
    private static func applyBeauty(
        _ beauty: CameraBeauty,
        sourceForMask: CIImage,
        to image: CIImage,
        censorMask: CIImage?
    ) -> CIImage {
        var skinMask = apply(.skinMask, to: sourceForMask)
        if let censorMask {
            // Multiply by the inverse: `CIMultiplyCompositing` on an inverted coverage mask is
            // the cheapest way to say "skin, except where the censor is".
            let inverted = censorMask.applyingFilter("CIColorInvert")
            skinMask = skinMask.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: inverted
            ])
        }

        var output = image

        if beauty.smoothing > 0.001 {
            let smooth = image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.025 + beauty.smoothing * 0.075,
                "inputSharpness": 0.58 - beauty.smoothing * 0.28
            ])
            output = blend(smooth, over: output, mask: skinMask, strength: beauty.smoothing * 0.9)
        }

        if beauty.brightness > 0.001 || beauty.rosy > 0.001 {
            let lift = CGFloat(beauty.brightness * 0.12)
            let rosy = CGFloat(beauty.rosy)
            let adjusted = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(
                    x: lift + rosy * 0.08,
                    y: lift + rosy * 0.018,
                    z: lift + rosy * 0.032,
                    w: 0
                )
            ])
            output = blend(adjusted, over: output, mask: skinMask, strength: 1)
        }

        if beauty.definition > 0.001 {
            let defined = output.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: beauty.definition * 0.9
            ])
            output = blend(defined, over: output, mask: skinMask, strength: beauty.definition * 0.72)
        }

        return output
    }

    private static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage, strength: Float) -> CIImage {
        let weightedMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(strength), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(strength), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(strength), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        return foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: weightedMask
        ])
    }

    /// Grain and the light leak, from the constants both this and the shader read.
    ///
    /// Every number here comes from `CameraFilmSimulation`, and the two effects are built to
    /// match the shader stage for stage:
    ///
    /// **Grain** is a field of square cells sized against the image's height, so one preset is
    /// one film stock whether it is rendered onto a 384 px chip or a 12 MP still. It used to be
    /// one `CIRandomGenerator` texel per *output* pixel here and one hash per *source* pixel
    /// there, which is how the same number produced grain seven times coarser on the strip than
    /// in the viewfinder — and nearly invisible in the viewfinder, because a per-source-pixel
    /// pattern does not survive the upscale to the screen.
    ///
    /// **The light leak** is placed in the image's own frame with distances in units of its
    /// width, which is what `CIRadialGradient` already measures in, and the falloff is linear
    /// on both sides. The shader used to place it in *sensor* coordinates, so the same preset
    /// leaked from the bottom of the viewfinder and from the right of the chip.
    private static func applyFilm(
        _ film: CameraFilmSimulation,
        to image: CIImage,
        extent: CGRect,
        rotationDegrees: CGFloat,
        seed: Float
    ) -> CIImage {
        guard film.isEnabled else { return image }

        // The image's dimensions *as a person would see them*. On a quarter turn the axes swap,
        // and using the buffer's own height instead is what made grain change size when the
        // phone was rotated.
        let upright = CensorGeometry.uprightSize(sensorSize: extent.size, rotationDegrees: rotationDegrees)
        var output = image

        if film.grain > 0.001, let grainTile {
            let cell = CameraFilmSimulation.grainCellSize(uprightHeight: upright.height)
            let tileScale = cell / CGFloat(CameraFilmSimulation.grainTexelsPerCell)
            let offset = CameraFilmSimulation.grainTileOffset(seed: seed)
            let cells = grainTile
                .samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: tileScale, y: tileScale))
                .transformed(by: CGAffineTransform(
                    translationX: -offset.x * tileScale,
                    y: -offset.y * tileScale
                ))
                .applyingFilter("CIAffineTile")

            let amount = CameraFilmSimulation.grainAmplitude * CGFloat(film.grain)
            let grain = cells.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: amount * 0.98, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: amount * 0.94, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(
                    x: -amount * 0.5,
                    y: -amount * 0.5 * 0.98,
                    z: -amount * 0.5 * 0.94,
                    w: 0
                )
            ]).cropped(to: extent)

            // Film density is not white-noise sprinkled uniformly over the frame. Dye clouds
            // read in the midtones and recede at both ends, using the same smoothstep product
            // as the live shader.
            let luma = luminance(of: output)
            let shadowResponse = smoothstep(
                luma,
                from: CameraFilmSimulation.grainShadowStart,
                to: CameraFilmSimulation.grainShadowFull
            )
            let highlightResponse = inverted(smoothstep(
                luma,
                from: CameraFilmSimulation.grainHighlightStart,
                to: CameraFilmSimulation.grainHighlightEnd
            ))
            let density = shadowResponse.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: highlightResponse
            ])
            let shapedGrain = grain.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: density
            ])
            output = shapedGrain.applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: output
            ])
        }

        if film.lightLeak > 0.001 {
            // Turned into the buffer's own space. Only the centre needs it: a radial gradient is
            // symmetric, so there is no orientation left in it once the centre is right.
            let centre = CameraFilmSimulation.lightLeakCenterInSensorSpace(rotationDegrees: rotationDegrees)
            let colour = CameraFilmSimulation.lightLeakColor
            let leak = CIFilter(name: "CIRadialGradient", parameters: [
                // Core Image's y runs up and the constant is expressed y-down, matching the
                // shader's texture coordinates.
                "inputCenter": CIVector(
                    x: extent.minX + extent.width * centre.x,
                    y: extent.maxY - extent.height * centre.y
                ),
                // Both radii are fractions of the **upright width**, so the leak keeps its shape
                // and its size on a portrait and a landscape frame alike — and matches the
                // shader, which measures in the same units.
                "inputRadius0": upright.width * CameraFilmSimulation.lightLeakInnerRadius,
                "inputRadius1": upright.width * CameraFilmSimulation.lightLeakOuterRadius,
                "inputColor0": CIColor(
                    red: colour.red, green: colour.green, blue: colour.blue,
                    alpha: CameraFilmSimulation.lightLeakAlpha * CGFloat(film.lightLeak)
                ),
                "inputColor1": CIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 0)
            ])?.outputImage?.cropped(to: extent)
            if let leak {
                output = leak.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: output])
            }
        }
        return output
    }

    private static func luminance(of image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    /// Core Image has no built-in smoothstep filter. Normalise and clamp first, then evaluate
    /// `3t² - 2t³`, exactly the function Metal's `smoothstep` uses.
    private static func smoothstep(_ image: CIImage, from lower: CGFloat, to upper: CGFloat) -> CIImage {
        let scale = 1 / max(upper - lower, 0.0001)
        let normalised = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -lower * scale, y: -lower * scale, z: -lower * scale, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
        let polynomial = CIVector(x: 0, y: 0, z: 3, w: -2)
        return normalised.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": polynomial,
            "inputGreenCoefficients": polynomial,
            "inputBlueCoefficients": polynomial,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
        ])
    }

    private static func inverted(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ])
    }

    /// Log-average tracks perceived midtone brightness and is far less sensitive than a plain
    /// average to one lamp or window occupying a small part of the frame.
    private static func logAverageLuminance(_ image: CIImage) -> Float? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite,
              extent.minX.isFinite, extent.minY.isFinite else { return nil }
        let longest: CGFloat = 32
        let scale = min(longest / extent.width, longest / extent.height)
        let reduced = image
            .transformed(by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(Int(reduced.extent.width.rounded(.down)), 1)
        let height = max(Int(reduced.extent.height.rounded(.down)), 1)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(
            reduced,
            toBitmap: &pixels,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )

        var logarithmicSum: Float = 0
        var sampleCount: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0.5 {
            let luma = pixels[index] * 0.2126 + pixels[index + 1] * 0.7152 + pixels[index + 2] * 0.0722
            logarithmicSum += log(max(luma, 0.001))
            sampleCount += 1
        }
        guard sampleCount > 0 else { return nil }
        return exp(logarithmicSum / sampleCount)
    }

    // MARK: - Regions

    /// The live tracker's regions, plus a second detection pass, unioned.
    ///
    /// The second pass runs on a downscale — face detection does not need 12 megapixels, and at
    /// full resolution it was the slowest thing on the shutter path. Two sources rather than one
    /// because the two fail differently: the tracker can be a frame or two behind a fast turn of
    /// the head, and a single-image detector misses a face the tracker has been coasting through.
    /// A region either source reports is censored.
    private static func censorRegions(live: [CensorRegion], in encodedSource: CIImage) -> [CensorRegion] {
        var regions = live
        let detected = CensorRenderer.regions(in: downscaledForDetection(encodedSource))

        for region in detected where !regions.contains(where: { overlaps($0, region) }) {
            regions.append(region)
        }
        return regions
    }

    /// The longest edge handed to the still-image face detector.
    ///
    /// Vision's face rectangles work down to a face about 20 px across, so 1280 finds anything
    /// worth censoring in a photograph and costs a fraction of what the full frame did.
    private static let detectionMaxDimension: CGFloat = 1280

    private static func downscaledForDetection(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let scale = min(1, detectionMaxDimension / max(extent.width, extent.height))
        guard scale < 1 else { return image }
        // Properties are re-attached because the orientation tag is what tells the detector which
        // way up the buffer is, and a transform drops it.
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .settingProperties(image.properties)
    }

    /// Whether two regions describe the same face, so the union does not censor one face twice.
    ///
    /// Centres within the larger radius, which is the same relative test `CensorTracker` uses to
    /// match an observation to a track — an absolute threshold either merges two distant faces or
    /// fails to merge one near face reported slightly differently by two detectors.
    private static func overlaps(_ a: CensorRegion, _ b: CensorRegion) -> Bool {
        let dx = a.center.x - b.center.x
        let dy = a.center.y - b.center.y
        let scale = max(a.radius.width, b.radius.width, 0.001)
        return (dx * dx + dy * dy).squareRoot() / scale < 1
    }

    // MARK: - Encoding

    /// The rendered image, encoded in the same container the camera produced where possible.
    ///
    /// HEIF in, HEIF out. Filtering is a re-encode either way, but turning every filtered photo
    /// into a JPEG — which is what this used to do, twice — throws away both the container's
    /// efficiency and a visible amount of quality on skies and skin. JPEG remains the fallback
    /// for a device or a build whose encoder will not produce HEIF.
    ///
    /// The extension is reported back so nothing writes a JPEG to disk named `.heic`, which is a
    /// bug this camera has already had in the other direction.
    private static func encode(
        _ image: CIImage,
        like original: Data,
        colorSpace: CGColorSpace?,
        quality: CGFloat
    ) -> (data: Data, fileExtension: String)? {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]

        if CapturedPhotoDecoder.fileExtension(for: original) == "heic",
           let heif = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: space, options: options) {
            return (heif, "heic")
        }

        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: space, options: options) else {
            return nil
        }
        return (jpeg, "jpg")
    }
}

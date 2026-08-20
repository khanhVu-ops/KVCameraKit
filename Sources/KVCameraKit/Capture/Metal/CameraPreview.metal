#include <metal_stdlib>
using namespace metal;

// The viewfinder, drawn by us instead of by AVFoundation.
//
// **Two passes, not one**, and that is the load-bearing decision in this file.
//
// The look pass renders the whole recipe — censor, tone, LUT, beauty, film — into an offscreen
// texture the size of the *camera frame*, once per camera frame. The display pass is a textured
// quad that rotates, mirrors and aspect-fills that texture onto the drawable, and it is the only
// thing that runs at display rate.
//
// The single-pass version this replaces ran every stage per *drawable* pixel at 60 Hz against a
// 30 Hz camera. On a Pro screen that is 3 MP of shading, half of it spent re-deriving pixels the
// upscale invented, and the other half re-deriving an identical frame — for a source that is
// 1.5 MP. Beauty made it worse than a factor of four: it sampled the 3D LUT eight times *per
// pixel*, so turning on smoothing and a censor together dropped the viewfinder to a slideshow.
//
// Two fragment functions for the look pass rather than one, because the pixel format is not ours
// to choose. `CameraFrameTap` deliberately does not set `videoSettings`, so a device hands back
// bi-planar YCbCr (`420f`/`420v`) — the sensor's own format, 1.5 bytes per pixel — while the
// simulated source produces BGRA.

// MARK: - Geometry

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// A full-screen quad, transformed on the CPU side.
///
/// The transform carries rotation, aspect fill and front-camera mirroring together, so the
/// shader does not need to know which of those is happening — and there is one place where
/// they compose, rather than three that can disagree about orientation.
///
/// Shared by both passes: the look pass hands it the identity, because it draws into a texture
/// that is the same shape as the frame.
vertex VertexOut cameraPreviewVertex(
    uint vertexID [[vertex_id]],
    constant float4x4 &transform [[buffer(0)]]
) {
    // Triangle strip: bottom-left, bottom-right, top-left, top-right.
    const float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    // Texture coordinates have y down, clip space has y up, so the strip is paired with
    // flipped v values. This is the flip that would otherwise show up as an upside-down
    // viewfinder that someone "fixes" by rotating the transform 180°.
    const float2 texCoords[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = transform * float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Uniforms

/// Everything about the look that is not the tone matrix or the LUT.
///
/// One buffer rather than several, because every field is read by the same fragment invocation
/// and `setFragmentBytes` has a per-call cost that a camera pays thirty times a second.
struct LookUniform {
    /// Maps a *sensor* texture coordinate, centred on 0.5, into the **upright** image's own
    /// normalised space. Film texture is placed there and nowhere else — see `applyFilm`.
    float2x2 uprightRotation;
    /// Pixel dimensions of the upright image: the frame's, axes swapped on a quarter turn.
    float2 uprightSize;
    /// Pixel dimensions of the source texture, for the censor's isotropy and beauty's texel step.
    float2 imageSize;

    float beautySmoothing;
    float beautyBrightness;
    float beautyRosy;
    float beautyDefinition;

    float grainIntensity;
    float lightLeakIntensity;
    /// Advances per frame so grain shimmers like film rather than sitting still like dirt on
    /// the lens. Fixed for a still and for a thumbnail, where there is nothing to shimmer.
    float grainPhase;
    float unused;
};

/// The look, as one matrix.
///
/// Every adjustment the tone stage offers — exposure, white balance, saturation, contrast — is
/// affine in RGB, so all four arrive here already composed. That is what keeps the preview and
/// the captured still honest about each other: the same matrix is handed to Core Image for the
/// photo, so there is one definition of the look rather than a shader and a filter stack that
/// drift apart one adjustment at a time.
///
/// Applied to gamma-encoded values, deliberately: that is what the texture holds, and the
/// still path is told not to colour-manage for the same reason. Doing the matrix in linear
/// light would be more defensible photographically and would need *both* sides converted, or
/// the photo comes out different from the viewfinder.
static inline float3 applyTone(float3 rgb, float4x4 tone) {
    return saturate((tone * float4(rgb, 1.0)).rgb);
}

static inline float3 applyLUT(
    float3 rgb,
    texture3d<float, access::sample> lut
) {
    constexpr sampler trilinear(
        coord::normalized,
        mag_filter::linear,
        min_filter::linear,
        mip_filter::none,
        address::clamp_to_edge
    );
    float dim = float(lut.get_width());
    float3 coord = (saturate(rgb) * (dim - 1.0) + 0.5) / dim;
    return saturate(lut.sample(trilinear, coord).rgb);
}

// MARK: - Censor

/// One face, as the CPU packed it. Mirrors `CameraPreviewRenderer.CensorEllipseUniform` field
/// for field — a layout disagreement here is not a compile error, it is a censor drawn in a
/// corner of the frame.
struct CensorEllipse {
    /// Normalised texture coordinates, origin top-left, y down. `texCoord` *is* this space,
    /// which is the entire reason `CensorRegion` is defined in sensor-buffer space.
    float2 center;
    /// Semi-axes, both normalised against the image **width**. See `CensorRegion.radius`:
    /// one divisor keeps the space isotropic so that `roll` stays a rigid rotation.
    float2 radius;
    /// sin and cos of the roll, computed once on the CPU rather than per pixel.
    float2 rollSinCos;
    /// 0 off, 1 mosaic, 2 blur, 3 bar. A float rather than an int so the struct needs no
    /// padding rules of its own.
    float mode;
    float unused;
};

struct CensorHeader {
    /// Pixel dimensions of the source texture. Needed because `texCoord` is normalised per
    /// axis while a radius is normalised against the width only — without the real aspect
    /// ratio the ellipse comes out sheared and the roll with it.
    float2 imageSize;
    int count;
    int unused;
};

/// How many cells across the face, for the mosaic.
///
/// A *count*, not a size, and that is the fix for the ugliest part of the first
/// implementation: it used `CIPixellate` with a cell derived from the frame's dimensions, so a
/// distant face landed inside two cells and became a grey smudge while a close one kept
/// recognisable features. A fixed count means the look is the same at every distance, which is
/// what the censorship style being imitated actually does.
constant float2 kMosaicCells = float2(9.0, 11.0);

/// Half-extents of the bar, in the ellipse's own frame.
///
/// Local y runs -1 at the top of the padded region to +1 at the bottom, and the padding is
/// biased upward to cover hair — so the eyes sit above centre rather than at it. Slightly wider
/// than the face because a censor bar that stops exactly at the cheeks reads as a mistake.
constant float2 kBarHalfExtent = float2(1.02, 0.275);
constant float kBarCenterY = -0.175;

/// Where the ellipse feather begins, as a fraction of the semi-axis.
constant float kCensorFeatherStart = 0.86;

/// A point in the ellipse's own frame, where `length() < 1` is inside.
static inline float2 censorLocal(float2 uv, CensorEllipse e, float2 imageSize) {
    // Into pixels first: the two axes are normalised by different divisors, so a rotation
    // applied to normalised coordinates is a shear.
    float2 offset = (uv - e.center) * imageSize;
    float s = e.rollSinCos.x;
    float c = e.rollSinCos.y;
    // Rotated by -roll, taking the buffer's axes into the ellipse's.
    float2 local = float2(offset.x * c + offset.y * s, -offset.x * s + offset.y * c);
    return local / max(e.radius * imageSize.x, 1e-5);
}

/// The inverse of `censorLocal` — a point in the ellipse's frame, back to a texture coordinate.
static inline float2 censorUV(float2 local, CensorEllipse e, float2 imageSize) {
    float2 scaled = local * (e.radius * imageSize.x);
    float s = e.rollSinCos.x;
    float c = e.rollSinCos.y;
    float2 offset = float2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
    return e.center + offset / imageSize;
}

/// Samples the source on a grid inside the face, in the face's own frame.
///
/// A box blur rather than a Gaussian, and the taps are placed in *local* units so the blur
/// scales with the face automatically. That is the other half of the first implementation's
/// blur bug: a radius derived from the frame's dimensions left a close-up face perfectly
/// recognisable and smeared a distant one into the background.
///
/// 25 taps is a lot per pixel and costs nothing here, because these are only the pixels inside
/// a face — a few percent of the frame.
template <typename Source>
static float3 censorBlur(Source source, float2 local, CensorEllipse e, float2 imageSize) {
    float3 sum = float3(0.0);
    for (int j = -2; j <= 2; ++j) {
        for (int i = -2; i <= 2; ++i) {
            float2 tap = local + float2(float(i), float(j)) * 0.23;
            sum += source.rgb(censorUV(tap, e, imageSize));
        }
    }
    return sum / 25.0;
}

/// The mean of one mosaic cell.
///
/// A cell has to be an *average*, not a sample. Sampling one texel per cell is a pixel or two
/// less code and it aliases: fine detail in the picture — a striped shirt, hair, text — survives
/// as detail made of blocks, because a single texel carries whatever happened to be at that
/// point. For a censor that is not only ugly, it leaks: the average of a region discards the
/// information inside it and a point sample does not.
///
/// Nine taps on a grid inside the cell. The Core Image path reaches the same place differently,
/// by blurring a third of a cell before `CIPixellate` samples it — it has a second pass to do
/// that in and this does not.
template <typename Source>
static float3 censorMosaic(Source source, float2 local, CensorEllipse e, float2 imageSize) {
    float2 cellSize = 2.0 / kMosaicCells;
    float2 cellCentre = (floor(local / cellSize) + 0.5) * cellSize;

    float3 sum = float3(0.0);
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            float2 tap = cellCentre + float2(float(i), float(j)) * cellSize / 3.0;
            sum += source.rgb(censorUV(tap, e, imageSize));
        }
    }
    return sum / 9.0;
}

/// What the censor did to one pixel: the replacement colour, and how much of it applies.
struct CensorResult {
    float3 colour;
    /// `0` where the pixel is untouched, `1` at the centre of a region. Beauty reads this
    /// instead of asking a second time whether the pixel is covered — the old code ran the
    /// whole region loop twice per pixel to answer one question.
    float coverage;
};

/// The destructive half of the censor — mosaic and blur — applied to the **raw** frame, before
/// tone and the LUT.
///
/// Before, and that is not arbitrary. These two are spatial averages, so they have to consume
/// the picture's own pixels rather than graded ones, and running them first means the censored
/// patch is then graded along with everything around it: a mosaic inside a Film Noir frame
/// comes out monochrome like the rest of the picture instead of sitting in it as a colour
/// rectangle. For an affine tone the two orders are identical anyway — the LUT is what makes
/// the difference visible, and this is the order the still path uses.
///
/// The bar is deliberately *not* here. See `applyCensorBar`.
template <typename Source>
static CensorResult applyCensor(
    Source source,
    float2 uv,
    float3 base,
    constant CensorHeader &header,
    constant CensorEllipse *regions
) {
    CensorResult result { base, 0.0 };

    for (int index = 0; index < header.count; ++index) {
        CensorEllipse region = regions[index];
        // The bar is an overlay applied after grading; mosaic (1) and blur (2) are the two
        // that belong here.
        if (region.mode < 0.5 || region.mode > 2.5) { continue; }

        float2 local = censorLocal(uv, region, header.imageSize);
        float distance = length(local);
        if (distance >= 1.0) { continue; }

        // Feathered over the outer edge. One `smoothstep` on the ellipse distance, which is
        // what replaces the first implementation's hard rectangular mask — that produced a
        // visibly aliased box edge, and blurring a mask image to hide it costs a whole extra
        // full-frame filter.
        float alpha = 1.0 - smoothstep(kCensorFeatherStart, 1.0, distance);

        float3 effect = region.mode < 1.5
            ? censorMosaic(source, local, region, header.imageSize)
            : censorBlur(source, local, region, header.imageSize);

        result.colour = mix(result.colour, effect, alpha);
        result.coverage = max(result.coverage, alpha);
    }

    return result;
}

/// The bar, painted **last**, over the finished picture.
///
/// Last because a censor bar is an object placed on top of a photograph, not a region of it.
/// Run before the LUT — which is where it used to be — a strong preset tints it, so Film Noir
/// produced a dark grey bar in the viewfinder and the file got a black one from the Core Image
/// path, which applied it afterwards. Same stage, both sides, and the bar is black in both.
///
/// Hard-edged on purpose: the whole look of a censor bar is that it is obviously applied, so
/// feathering it would be wrong.
static float3 applyCensorBar(
    float3 colour,
    float2 uv,
    constant CensorHeader &header,
    constant CensorEllipse *regions
) {
    for (int index = 0; index < header.count; ++index) {
        CensorEllipse region = regions[index];
        if (region.mode < 2.5) { continue; }

        float2 local = censorLocal(uv, region, header.imageSize);
        float2 fromBar = abs(local - float2(0.0, kBarCenterY));
        if (all(fromBar <= kBarHalfExtent)) {
            return float3(0.0);
        }
    }
    return colour;
}

// MARK: - Beauty

static inline float smoothBand(float value, float lower, float upper, float feather) {
    return smoothstep(lower - feather, lower + feather, value)
        * (1.0 - smoothstep(upper - feather, upper + feather, value));
}

static inline float skinWeight(float3 rgb) {
    float luma = dot(rgb, float3(0.299, 0.587, 0.114));
    float cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b + 0.5;
    float cr = 0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b + 0.5;
    float chroma = smoothBand(cb, 0.25, 0.43, 0.055) * smoothBand(cr, 0.48, 0.72, 0.06);
    float luminance = smoothBand(luma, 0.08, 0.98, 0.08);
    float channelOrder = smoothstep(0.0, 0.08, rgb.r - rgb.b);
    return saturate(chroma * luminance * channelOrder);
}

/// Skin-gated smoothing, brightening, warmth and local contrast.
///
/// The taps are taken from the **raw** frame and graded *once*, rather than graded individually
/// and then averaged. For the tone matrix the two are identical — an affine map commutes with a
/// weighted mean — and for the LUT the difference is a fraction of a code value on a signal
/// this stage is deliberately low-passing. What it buys is the whole reason this pass is now
/// affordable: eight 3D-texture samples per skin pixel become one.
///
/// `coverage` comes from the censor rather than from a second pass over the regions. Smoothing
/// inside a censored patch would be sampling detail back into the one place whose purpose is
/// not to have any.
template <typename Source>
static float3 applyBeauty(
    Source source,
    float2 uv,
    float3 raw,
    float3 graded,
    float censorCoverage,
    float4x4 tone,
    texture3d<float, access::sample> lut,
    constant LookUniform &look
) {
    float beautyAmount = max(
        max(look.beautySmoothing, look.beautyBrightness),
        max(look.beautyRosy, look.beautyDefinition)
    );
    if (beautyAmount <= 0.001 || censorCoverage > 0.001) { return graded; }

    float skin = skinWeight(saturate(raw));
    if (skin <= 0.001) { return graded; }

    float2 texel = 1.0 / max(look.imageSize, float2(1.0));
    const float2 offsets[8] = {
        float2(-2.0, 0.0), float2(-1.0, -1.0), float2(0.0, -2.0), float2(1.0, -1.0),
        float2(2.0, 0.0), float2(1.0, 1.0), float2(0.0, 2.0), float2(-1.0, 1.0)
    };

    float centreLuma = dot(raw, float3(0.2126, 0.7152, 0.0722));
    float3 total = raw * 1.7;
    float totalWeight = 1.7;

    for (int index = 0; index < 8; ++index) {
        float2 sampleUV = uv + offsets[index] * texel * (1.0 + look.beautySmoothing * 4.0);
        float3 sampleColour = source.rgb(sampleUV);
        float sampleLuma = dot(sampleColour, float3(0.2126, 0.7152, 0.0722));
        // Range weighting keeps this a bilateral filter rather than a blur: a tap across an
        // edge — the line of a jaw, the rim of a nostril — contributes almost nothing, which
        // is what stops smoothing from turning a face into a mask.
        float rangeWeight = exp(-abs(sampleLuma - centreLuma) * 24.0);
        float spatialWeight = (index % 2 == 0) ? 0.72 : 0.9;
        float weight = rangeWeight * spatialWeight;
        total += sampleColour * weight;
        totalWeight += weight;
    }

    float3 smooth = applyLUT(applyTone(total / max(totalWeight, 0.001), tone), lut);
    float3 preservedTexture = smooth + (graded - smooth) * 0.08;
    float3 result = mix(graded, preservedTexture, skin * look.beautySmoothing * 0.9);

    result += skin * look.beautyBrightness * float3(0.12);
    result += skin * look.beautyRosy * float3(0.08, 0.018, 0.032);

    // Local contrast from the detail the smoothing pass removed. Kept skin-gated so hair,
    // text and the background are not sharpened by a face adjustment.
    result += skin * look.beautyDefinition * (graded - smooth) * 0.52;
    return saturate(result);
}

// MARK: - Film

static inline float hashNoise(float2 point) {
    return fract(sin(dot(point, float2(12.9898, 78.233))) * 43758.5453);
}

static inline float filmNoise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = hashNoise(i);
    float b = hashNoise(i + float2(1.0, 0.0));
    float c = hashNoise(i + float2(0.0, 1.0));
    float d = hashNoise(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float organicFilmGrain(float2 p) {
    float n1 = filmNoise2D(p);
    float n2 = filmNoise2D(p * 2.17 + float2(13.7, 31.9));
    return (n1 * 0.65 + n2 * 0.35) - 0.5;
}

/// Grain cells across the **height of the upright image**.
constant float kGrainCellsAcrossHeight = 320.0;

/// Grain and the light leak, placed in the **upright** image rather than in the sensor buffer.
static float3 applyFilm(float3 rgb, float2 uv, constant LookUniform &look) {
    if (look.grainIntensity <= 0.001 && look.lightLeakIntensity <= 0.001) { return rgb; }

    float2 upright = look.uprightRotation * (uv - 0.5) + 0.5;
    float2 size = max(look.uprightSize, float2(1.0));
    float aspect = size.y / size.x;

    float3 result = rgb;

    if (look.grainIntensity > 0.001) {
        float2 cells = float2(kGrainCellsAcrossHeight / aspect, kGrainCellsAcrossHeight);
        float2 cell = upright * cells + float2(look.grainPhase * 1.618, look.grainPhase * 0.618);

        // Multi-octave organic grain (smooth dye clouds instead of sharp white dots)
        float grainVal = organicFilmGrain(cell);

        // Real dye-cloud density curve:
        // Grain is strongest in midtones (0.15 - 0.65), rolls off in deep shadows (< 0.05) and specular highlights (> 0.85)
        float luma = dot(result, float3(0.2126, 0.7152, 0.0722));
        float grainMask = smoothstep(0.03, 0.22, luma) * (1.0 - smoothstep(0.65, 0.90, luma));

        // Soft organic dye cloud modulation with analog warm tint
        float grain = grainVal * look.grainIntensity * 0.075 * grainMask;
        result = saturate(result + grain * float3(1.0, 0.98, 0.94));
    }

    if (look.lightLeakIntensity > 0.001) {
        const float2 centre = float2(1.03, 0.22);
        float distance = length((upright - centre) * float2(1.0, aspect));
        float leak = 1.0 - saturate((distance - 0.05) / 0.67);
        result = 1.0 - (1.0 - result)
            * (1.0 - float3(1.0, 0.42, 0.12) * leak * look.lightLeakIntensity * 0.50);
    }

    return saturate(result);
}

// MARK: - The look, composed

/// Censor (mosaic/blur) → tone → LUT → beauty → film → censor bar.
///
/// This order is the contract with `CameraLookRenderer`, which applies exactly these stages to
/// a captured still and to every chip on the filter strip. The two implementations exist
/// because one is a fragment shader and the other is Core Image; the *order* is not allowed to
/// be a second opinion, and it used to be: the shader censored first, the still path censored
/// last, and each carried a comment claiming it matched the other.
template <typename Source>
static float3 applyLook(
    Source source,
    float2 uv,
    float4x4 tone,
    texture3d<float, access::sample> lut,
    constant LookUniform &look,
    constant CensorHeader &censor,
    constant CensorEllipse *regions
) {
    float3 raw = source.rgb(uv);
    CensorResult censored = applyCensor(source, uv, raw, censor, regions);
    float3 graded = applyLUT(applyTone(censored.colour, tone), lut);
    float3 smoothed = applyBeauty(source, uv, raw, graded, censored.coverage, tone, lut, look);
    float3 textured = applyFilm(smoothed, uv, look);
    return applyCensorBar(textured, uv, censor, regions);
}

// MARK: - Sources

/// The two ways to read a pixel, behind one interface.
///
/// A template rather than two copies of the look, because the censor is the part with the
/// geometry in it: two copies is two places for the mosaic grid or the bar's position to be
/// adjusted, and the one that gets missed is whichever format the reviewer's device does not
/// produce. `CameraFrameTap` deliberately takes the sensor's native format, so a device is
/// YCbCr and the simulator is BGRA — the two are never exercised on the same machine.
struct BGRASource {
    texture2d<float> tex;

    float3 rgb(float2 uv) const {
        constexpr sampler bilinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        return tex.sample(bilinear, uv).rgb;
    }
};

struct YCbCrSource {
    texture2d<float> luma;
    texture2d<float> chroma;
    float3x3 conversion;
    float3 offset;

    float3 rgb(float2 uv) const {
        constexpr sampler bilinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        float3 ycbcr = float3(luma.sample(bilinear, uv).r, chroma.sample(bilinear, uv).rg);
        return conversion * (ycbcr - offset);
    }
};

// MARK: - Pass one: the look

fragment float4 cameraLookFragmentBGRA(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    texture3d<float> lut [[texture(1)]],
    constant float4x4 &tone [[buffer(0)]],
    constant LookUniform &look [[buffer(1)]],
    constant CensorHeader &censor [[buffer(2)]],
    constant CensorEllipse *regions [[buffer(3)]]
) {
    BGRASource reader { source };
    return float4(applyLook(reader, in.texCoord, tone, lut, look, censor, regions), 1.0);
}

/// YCbCr → RGB, then the look.
///
/// The matrix has to match the buffer: `420f` is full range (0–255) and `420v` is video
/// range (16–235), and using the wrong one produces an image that looks *almost* right —
/// slightly washed out or slightly crushed — which is the kind of thing that ships. The
/// caller picks the conversion, and the offset it passes says which range this is.
///
/// The colour conversion comes first so every later stage operates on RGB in both paths — the
/// same numbers the still gets. A matrix applied to YCbCr instead would be a different filter
/// on a device than on anything delivering BGRA.
fragment float4 cameraLookFragmentYCbCr(
    VertexOut in [[stage_in]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]],
    texture3d<float> lut [[texture(2)]],
    constant float3x3 &conversion [[buffer(0)]],
    constant float3 &offset [[buffer(1)]],
    constant float4x4 &tone [[buffer(2)]],
    constant LookUniform &look [[buffer(3)]],
    constant CensorHeader &censor [[buffer(4)]],
    constant CensorEllipse *regions [[buffer(5)]]
) {
    YCbCrSource reader { luma, chroma, conversion, offset };
    return float4(applyLook(reader, in.texCoord, tone, lut, look, censor, regions), 1.0);
}

// MARK: - Pass two: the screen

/// The finished frame, rotated, mirrored and aspect-filled onto the drawable.
///
/// Nothing but a sample. Everything that costs anything happened in the look pass, at the
/// frame's own resolution and at the frame's own rate; this runs whenever the display asks and
/// is the same price whether the user has one filter on or all of them.
fragment float4 cameraDisplayFragment(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler bilinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return float4(source.sample(bilinear, in.texCoord).rgb, 1.0);
}

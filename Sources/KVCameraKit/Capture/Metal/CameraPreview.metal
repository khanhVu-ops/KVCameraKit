#include <metal_stdlib>
using namespace metal;

// The viewfinder, drawn by us instead of by AVFoundation.
//
// Two fragment functions rather than one, because the pixel format is not ours to choose.
// `CameraFrameTap` deliberately does not set `videoSettings`, so a device hands back
// bi-planar YCbCr (`420f`/`420v`) — the sensor's own format, 1.5 bytes per pixel — while the
// simulated source produces BGRA. Requesting BGRA from AVFoundation instead would be a
// conversion of every frame bought before knowing whether anything needs it, and would also
// mean the simulator was exercising a path the device never takes.

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// A full-screen quad, transformed on the CPU side.
///
/// The transform carries rotation, aspect fill and front-camera mirroring together, so the
/// shader does not need to know which of those is happening — and there is one place where
/// they compose, rather than three that can disagree about orientation.
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

/// The censored colour at `uv`, or the source colour where no region covers it.
///
/// Applied **before** the tone matrix, matching the order the still path uses — see
/// `CensorRenderer`. For the mosaic and the blur the order does not matter at all: a tone is an
/// affine matrix, so filtering and then toning gives the same pixels as toning and then
/// filtering. It only shows on the bar, which comes out tinted by a strong filter rather than
/// pure black — in the viewfinder and in the file identically, which is the property worth
/// having.
template <typename Source>
static float3 applyCensor(
    Source source,
    float2 uv,
    float3 base,
    constant CensorHeader &header,
    constant CensorEllipse *regions
) {
    float3 colour = base;

    for (int index = 0; index < header.count; ++index) {
        CensorEllipse region = regions[index];
        if (region.mode < 0.5) { continue; }

        float2 local = censorLocal(uv, region, header.imageSize);

        if (region.mode > 2.5) {
            // Bar. A rectangle in the face's frame, hard-edged on purpose: the whole look of a
            // censor bar is that it is obviously applied, so feathering it would be wrong.
            float2 fromBar = abs(local - float2(0.0, kBarCenterY));
            if (all(fromBar <= kBarHalfExtent)) {
                colour = float3(0.0);
            }
            continue;
        }

        float distance = length(local);
        if (distance >= 1.0) { continue; }

        // Feathered over the outer edge. One `smoothstep` on the ellipse distance, which is
        // what replaces the first implementation's hard rectangular mask — that produced a
        // visibly aliased box edge, and blurring a mask image to hide it costs a whole extra
        // full-frame filter.
        float alpha = 1.0 - smoothstep(0.86, 1.0, distance);

        float3 effect = region.mode < 1.5
            ? censorMosaic(source, local, region, header.imageSize)
            : censorBlur(source, local, region, header.imageSize);

        colour = mix(colour, effect, alpha);
    }

    return colour;
}

/// The two ways to read a pixel, behind one interface.
///
/// A template rather than two copies of `applyCensor`, because the censor is the part with the
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


fragment float4 cameraPreviewFragmentBGRA(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant float4x4 &tone [[buffer(0)]],
    constant CensorHeader &censor [[buffer(1)]],
    constant CensorEllipse *regions [[buffer(2)]]
) {
    BGRASource reader { source };
    float3 rgb = applyCensor(reader, in.texCoord, reader.rgb(in.texCoord), censor, regions);
    return float4(applyTone(rgb, tone), 1.0);
}

/// Full-range BT.709 YCbCr → RGB.
///
/// The matrix has to match the buffer: `420f` is full range (0–255) and `420v` is video
/// range (16–235), and using the wrong one produces an image that looks *almost* right —
/// slightly washed out or slightly crushed — which is the kind of thing that ships. The
/// caller picks the fragment function, and the offset it passes says which range this is.
fragment float4 cameraPreviewFragmentYCbCr(
    VertexOut in [[stage_in]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]],
    constant float3x3 &conversion [[buffer(0)]],
    constant float3 &offset [[buffer(1)]],
    constant float4x4 &tone [[buffer(2)]],
    constant CensorHeader &censor [[buffer(3)]],
    constant CensorEllipse *regions [[buffer(4)]]
) {
    YCbCrSource reader { luma, chroma, conversion, offset };
    // Tone comes *after* the colour conversion, so it operates on RGB in both paths — the
    // same numbers the still gets. A matrix applied to YCbCr instead would be a different
    // filter on a device than on anything delivering BGRA. The censor sits between the two for
    // the same reason: it works in RGB, so one implementation covers both formats.
    float3 rgb = applyCensor(reader, in.texCoord, reader.rgb(in.texCoord), censor, regions);
    return float4(applyTone(rgb, tone), 1.0);
}

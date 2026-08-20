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

fragment float4 cameraPreviewFragmentBGRA(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant float4x4 &tone [[buffer(0)]]
) {
    constexpr sampler bilinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return float4(applyTone(source.sample(bilinear, in.texCoord).rgb, tone), 1.0);
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
    constant float4x4 &tone [[buffer(2)]]
) {
    constexpr sampler bilinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float3 ycbcr = float3(
        luma.sample(bilinear, in.texCoord).r,
        chroma.sample(bilinear, in.texCoord).rg
    );
    // Tone comes *after* the colour conversion, so it operates on RGB in both paths — the
    // same numbers the still gets. A matrix applied to YCbCr instead would be a different
    // filter on a device than on anything delivering BGRA.
    return float4(applyTone(conversion * (ycbcr - offset), tone), 1.0);
}

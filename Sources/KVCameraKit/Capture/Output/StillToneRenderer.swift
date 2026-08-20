import CoreImage
import Foundation
import simd

/// Bakes a look into a captured still, using the same matrix the viewfinder drew with.
///
/// The interesting part is not the filter, it is the two ways this could have been written and
/// only one of them stays honest. Written as a stack of Core Image filters — `CIColorControls`
/// for saturation and contrast, `CITemperatureAndTint` for warmth, `CIExposureAdjust` for
/// exposure — it would look right today and drift from the shader the first time either side
/// is touched, and the symptom is a photo that does not match the viewfinder it was composed
/// in. So the look is *one matrix*, built in `CameraTone`, and this hands that matrix to
/// `CIColorMatrix` unchanged.
///
/// Two details make the parity real rather than nominal:
///
/// **No colour management.** The context works with `workingColorSpace: NSNull()`, so the
/// matrix multiplies the same gamma-encoded values the shader multiplies. Core Image's default
/// is to convert to linear light first, which is more defensible photographically and would
/// silently make every photo differ from its preview.
///
/// **JPEG out, whatever came in.** Filtering is a re-encode, and a filtered HEIC would need
/// the container rewritten; the extension is reported back so nothing writes a JPEG to disk
/// named `.heic` — the mirror of a bug this camera already had in the other direction.
enum StillToneRenderer {

    /// Built once. A `CIContext` carries compiled kernels and a command queue, and stills
    /// arrive one shutter press at a time — rebuilding it per photo was measurable.
    ///
    /// `nonisolated(unsafe)` because `CIContext` is documented as safe to use from multiple
    /// threads, which is the whole reason one shared instance is correct here.
    nonisolated(unsafe) private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    /// The filtered image, or `nil` if the bytes could not be read.
    ///
    /// Returns `nil` rather than the original on failure, deliberately: silently storing an
    /// *unfiltered* photo when the user picked a look is the same class of lie as a preview
    /// that disagrees with the file, and the caller can decide what to do about it.
    static func apply(_ tone: CameraTone, to data: Data, quality: CGFloat = 0.9) -> (data: Data, fileExtension: String)? {
        guard !tone.isNeutral else { return (data, CapturedPhotoDecoder.fileExtension(for: data)) }
        guard let source = CIImage(data: data) else { return nil }

        let matrix = tone.colorMatrix
        let filtered = source.applyingFilter("CIColorMatrix", parameters: Self.parameters(for: matrix))

        // The extent, not the whole plane: a filter output is conceptually infinite, and
        // encoding without saying where to stop produces nothing.
        guard let encoded = context.jpegRepresentation(
            of: filtered.cropped(to: source.extent),
            colorSpace: source.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { return nil }

        return (encoded, "jpg")
    }

    /// `CIColorMatrix` takes one vector per output channel plus a bias, which is exactly a 4×4
    /// affine transform read out by rows.
    ///
    /// The alpha coefficient of each colour vector is zero and the bias carries the matrix's
    /// fourth column instead. Leaving the bias in the vectors would multiply it by the pixel's
    /// alpha — invisible on an opaque camera frame, and wrong the first time anything with
    /// transparency goes through here.
    static func parameters(for matrix: simd_float4x4) -> [String: Any] {
        func row(_ index: Int) -> CIVector {
            CIVector(
                x: CGFloat(matrix[0][index]),
                y: CGFloat(matrix[1][index]),
                z: CGFloat(matrix[2][index]),
                w: 0
            )
        }
        return [
            "inputRVector": row(0),
            "inputGVector": row(1),
            "inputBVector": row(2),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(
                x: CGFloat(matrix[3][0]),
                y: CGFloat(matrix[3][1]),
                z: CGFloat(matrix[3][2]),
                w: 0
            )
        ]
    }
}

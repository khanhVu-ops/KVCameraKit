import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Turning what `AVCapturePhoto` hands back into bytes worth storing.
///
/// Static and free of any session, because both facts below are about *bytes* rather than
/// about a camera, and both were wrong once in a way a device test would not have caught
/// any faster than an assertion over a header.
enum CapturedPhotoDecoder {

    /// Container sniffed from the bytes.
    ///
    /// Capturing HEVC yields an HEIC file. Trusting the codec request instead of the
    /// result is how a HEIC ended up on disk named `.jpg`.
    static func fileExtension(for data: Data) -> String {
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
            return "jpg"
        }
        if data.count >= 12 {
            let boxType = data.subdata(in: data.startIndex.advanced(by: 4)..<data.startIndex.advanced(by: 8))
            if String(data: boxType, encoding: .ascii) == "ftyp" {
                return "heic"
            }
        }
        return "jpg"
    }

    static func orientation(for data: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .up }

        let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    /// Bakes the sensor orientation into pixels.
    ///
    /// `UIImage.jpegData` on an image whose orientation is not `.up` is not reliably
    /// upright, so the frame goes through a renderer once.
    ///
    /// The format is explicit, and that is the whole point of it being here. A default
    /// `UIGraphicsImageRenderer` renders at the *screen* scale, so on a 3x iPhone this took
    /// the ~1 MP preview frame AVFoundation had just handed back and resampled it to ~9 MP
    /// before encoding — nine times the pixels to interpolate and JPEG, on the one code path
    /// between the shutter closing and the first frame of feedback. Nothing looked wrong,
    /// because upsampling never does; it just cost the animation the milliseconds it exists
    /// to hide. `scale = 1` keeps one output pixel per source pixel.
    ///
    /// `opaque = true` because a camera frame has no alpha: it drops the renderer to a
    /// 3-byte-per-pixel buffer and skips blending the draw against transparency.
    static func uprightJPEG(from cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Data? {
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation(from: orientation))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let baked = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return baked.jpegData(compressionQuality: 0.9)
    }

    static func imageOrientation(from orientation: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch orientation {
        case .up:             return .up
        case .upMirrored:     return .upMirrored
        case .down:           return .down
        case .downMirrored:   return .downMirrored
        case .left:           return .left
        case .leftMirrored:   return .leftMirrored
        case .right:          return .right
        case .rightMirrored:  return .rightMirrored
        @unknown default:     return .up
        }
    }
}

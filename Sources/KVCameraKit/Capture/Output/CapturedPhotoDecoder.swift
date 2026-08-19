import CoreGraphics
import Foundation
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

    /// Bakes the sensor orientation into pixels.
    ///
    /// `UIImage.jpegData` on an image whose orientation is not `.up` is not reliably
    /// upright, so the frame goes through a renderer once. It is a ~1 MP image on a
    /// background queue, which is cheaper than one frame of the flight animation.
    static func uprightJPEG(from cgImage: CGImage, orientation: CGImagePropertyOrientation) -> Data? {
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: imageOrientation(from: orientation))
        let renderer = UIGraphicsImageRenderer(size: image.size)
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

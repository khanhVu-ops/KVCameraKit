import CoreGraphics
import Foundation
import ImageIO
import simd

public extension CameraLUT {

    /// Parses an Adobe/Resolve `.cube` 3D LUT.
    ///
    /// `.cube` files list blue fastest while Metal and Core Image store red fastest. The
    /// parser performs that reorder once and also resamples non-standard `DOMAIN_MIN/MAX`
    /// files into the normalized 0...1 domain expected by both renderers.
    static func cube(id: String, data: Data) throws -> CameraLUT {
        guard let text = String(data: data, encoding: .utf8) else { throw CameraLUTError.invalidText }

        var dimension: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var entries: [SIMD3<Float>] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let keyword = fields.first else { continue }

            switch keyword.uppercased() {
            case "TITLE", "LUT_1D_SIZE":
                continue
            case "LUT_3D_SIZE":
                guard fields.count == 2, let parsed = Int(fields[1]) else { throw CameraLUTError.invalidText }
                guard (2...128).contains(parsed) else { throw CameraLUTError.unsupportedDimension(parsed) }
                dimension = parsed
                entries.reserveCapacity(parsed * parsed * parsed)
            case "DOMAIN_MIN":
                domainMin = try vector(from: fields)
            case "DOMAIN_MAX":
                domainMax = try vector(from: fields)
            default:
                guard fields.count >= 3,
                      let red = Float(fields[0]), let green = Float(fields[1]), let blue = Float(fields[2])
                else { throw CameraLUTError.invalidText }
                entries.append(SIMD3<Float>(red, green, blue))
            }
        }

        guard let dimension else { throw CameraLUTError.missingDimension }
        let expected = dimension * dimension * dimension
        guard entries.count == expected else {
            throw CameraLUTError.invalidEntryCount(expected: expected, actual: entries.count)
        }

        var reordered = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: expected)
        for red in 0..<dimension {
            for green in 0..<dimension {
                for blue in 0..<dimension {
                    let fileIndex = blue + green * dimension + red * dimension * dimension
                    let storageIndex = red + green * dimension + blue * dimension * dimension
                    reordered[storageIndex] = SIMD4<Float>(entries[fileIndex], 1)
                }
            }
        }

        let source = CameraLUT(id: id, dimension: dimension, values: reordered)
        guard domainMin != SIMD3<Float>(repeating: 0) || domainMax != SIMD3<Float>(repeating: 1) else {
            return source
        }

        let span = domainMax - domainMin
        guard span.x > 0, span.y > 0, span.z > 0 else { throw CameraLUTError.invalidText }
        return CameraLUT.generated(id: id, dimension: dimension) { normalized in
            source.sample((normalized - domainMin) / span)
        }
    }

    /// Decodes a square Hald CLUT PNG, including the common 512 x 512 (level 8) format.
    ///
    /// A Hald image with side `level^3` contains a cube with side `level^2`. Pixels are a
    /// flattened red-fastest cube, which is already the storage order used by this package.
    static func haldCLUT(id: String, pngData: Data) throws -> CameraLUT {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CameraLUTError.invalidImage }

        let width = image.width
        let height = image.height
        guard width == height, width > 0 else {
            throw CameraLUTError.invalidHaldDimensions(width: width, height: height)
        }

        let level = Int(round(pow(Double(width), 1.0 / 3.0)))
        guard level * level * level == width else {
            throw CameraLUTError.invalidHaldDimensions(width: width, height: height)
        }

        let dimension = level * level
        guard (2...128).contains(dimension) else { throw CameraLUTError.unsupportedDimension(dimension) }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw CameraLUTError.invalidImage }

        // `CGImage` rows are copied in encoded order into the bitmap; no UIKit orientation is
        // involved because a Hald CLUT is data, not a display image.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let count = dimension * dimension * dimension
        var values: [SIMD4<Float>] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * bytesPerPixel
            values.append(SIMD4<Float>(
                Float(pixels[offset]) / 255,
                Float(pixels[offset + 1]) / 255,
                Float(pixels[offset + 2]) / 255,
                1
            ))
        }
        return CameraLUT(id: id, dimension: dimension, values: values)
    }

    private static func vector(from fields: [String]) throws -> SIMD3<Float> {
        guard fields.count == 4,
              let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3])
        else { throw CameraLUTError.invalidText }
        return SIMD3<Float>(x, y, z)
    }
}

import Foundation
import simd

/// A normalized RGB 3D lookup table.
///
/// Values are stored red-fastest (`r + g*size + b*size*size`), matching both Metal 3D textures
/// and Core Image's `CIColorCube`. Loaders normalize `.cube` domains and Hald layouts into
/// this one representation, so neither renderer has to know which file format supplied it.
public struct CameraLUT: Equatable, Sendable, Identifiable {
    public let id: String
    public let dimension: Int
    let values: [SIMD4<Float>]

    init(id: String, dimension: Int, values: [SIMD4<Float>]) {
        precondition(dimension >= 2)
        precondition(values.count == dimension * dimension * dimension)
        self.id = id
        self.dimension = dimension
        self.values = values
    }

    static func generated(
        id: String,
        dimension: Int = 24,
        transform: (SIMD3<Float>) -> SIMD3<Float>
    ) -> CameraLUT {
        var values: [SIMD4<Float>] = []
        values.reserveCapacity(dimension * dimension * dimension)
        let divisor = Float(dimension - 1)

        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let input = SIMD3<Float>(Float(red) / divisor, Float(green) / divisor, Float(blue) / divisor)
                    let output = simd_clamp(transform(input), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                    values.append(SIMD4<Float>(output, 1))
                }
            }
        }
        return CameraLUT(id: id, dimension: dimension, values: values)
    }

    /// Trilinear CPU sampling, used by tests and by domain normalization in the `.cube` loader.
    func sample(_ input: SIMD3<Float>) -> SIMD3<Float> {
        let coordinate = simd_clamp(input, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            * Float(dimension - 1)
        let lower = SIMD3<Int>(Int(floor(coordinate.x)), Int(floor(coordinate.y)), Int(floor(coordinate.z)))
        let upper = SIMD3<Int>(
            min(lower.x + 1, dimension - 1),
            min(lower.y + 1, dimension - 1),
            min(lower.z + 1, dimension - 1)
        )
        let fraction = coordinate - SIMD3<Float>(Float(lower.x), Float(lower.y), Float(lower.z))

        func colour(_ red: Int, _ green: Int, _ blue: Int) -> SIMD3<Float> {
            let value = values[red + green * dimension + blue * dimension * dimension]
            return SIMD3<Float>(value.x, value.y, value.z)
        }

        let c00 = simd_mix(colour(lower.x, lower.y, lower.z), colour(upper.x, lower.y, lower.z), SIMD3<Float>(repeating: fraction.x))
        let c10 = simd_mix(colour(lower.x, upper.y, lower.z), colour(upper.x, upper.y, lower.z), SIMD3<Float>(repeating: fraction.x))
        let c01 = simd_mix(colour(lower.x, lower.y, upper.z), colour(upper.x, lower.y, upper.z), SIMD3<Float>(repeating: fraction.x))
        let c11 = simd_mix(colour(lower.x, upper.y, upper.z), colour(upper.x, upper.y, upper.z), SIMD3<Float>(repeating: fraction.x))
        let c0 = simd_mix(c00, c10, SIMD3<Float>(repeating: fraction.y))
        let c1 = simd_mix(c01, c11, SIMD3<Float>(repeating: fraction.y))
        return simd_mix(c0, c1, SIMD3<Float>(repeating: fraction.z))
    }

    var coreImageData: Data {
        values.withUnsafeBytes { Data($0) }
    }

    static let identity = CameraLUT.generated(id: "identity", dimension: 2) { $0 }

    /// A colour cube whose RGB channels all contain the skin probability.
    static let skinMask = CameraLUT.generated(id: "skin-mask", dimension: 24) { colour in
        let weight = CameraBeauty.skinWeight(colour)
        return SIMD3<Float>(repeating: weight)
    }
}

/// Failures reported while normalizing an external LUT.
public enum CameraLUTError: Error, Equatable, Sendable {
    case invalidText
    case missingDimension
    case unsupportedDimension(Int)
    case invalidEntryCount(expected: Int, actual: Int)
    case invalidImage
    case invalidHaldDimensions(width: Int, height: Int)
}

import Metal

/// Turns the normalized LUT representation into a GPU 3D texture and keeps selected presets
/// warm. A filter change may happen while the viewfinder is live, so compilation or parsing
/// does not belong on the per-frame draw path.
final class CameraLUTTextureLoader {
    private let device: MTLDevice
    private var cache: [String: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(for lut: CameraLUT?) -> MTLTexture? {
        let lut = lut ?? .identity
        let key = "\(lut.id)#\(lut.dimension)"
        if let cached = cache[key] { return cached }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = lut.dimension
        descriptor.height = lut.dimension
        descriptor.depth = lut.dimension
        descriptor.mipmapLevelCount = 1
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let halfValues = lut.values.map {
            SIMD4<Float16>(Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w))
        }
        halfValues.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            let bytesPerPixel = MemoryLayout<SIMD4<Float16>>.stride
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, lut.dimension, lut.dimension, lut.dimension),
                mipmapLevel: 0,
                slice: 0,
                withBytes: address,
                bytesPerRow: lut.dimension * bytesPerPixel,
                bytesPerImage: lut.dimension * lut.dimension * bytesPerPixel
            )
        }

        texture.label = "KVCameraKit LUT: \(lut.id)"
        cache[key] = texture
        return texture
    }
}

import AVFoundation

/// Which physical camera to open, front or back.
enum CameraPosition: Sendable {
    case back
    case front

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .back: return .back
        case .front: return .front
        }
    }

    var flipped: CameraPosition {
        self == .back ? .front : .back
    }
}

/// Picks the camera to open.
enum CameraDeviceDiscovery {

    /// Preference order for the back camera: the widest *virtual* device wins, because
    /// only a virtual device exposes constituent lenses — and those are what the `0,5×`
    /// chip and every other optical rung are derived from.
    static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedBackDevice: AVCaptureDevice?
    nonisolated(unsafe) private static var cachedFrontDevice: AVCaptureDevice?

    static func device(for position: CameraPosition) -> AVCaptureDevice? {
        lock.lock()
        defer { lock.unlock() }

        switch position {
        case .back:
            if let cached = cachedBackDevice { return cached }
            let device = discoverDevice(for: .back)
            cachedBackDevice = device
            return device
        case .front:
            if let cached = cachedFrontDevice { return cached }
            let device = discoverDevice(for: .front)
            cachedFrontDevice = device
            return device
        }
    }

    private static func discoverDevice(for position: CameraPosition) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredDeviceTypes,
            mediaType: .video,
            position: position.avPosition
        )

        // `discovery.devices.first` is not the first entry of `deviceTypes`: AVFoundation
        // makes no promise that the result is ordered by the types requested. On an
        // iPhone 16 it handed back the plain wide angle, which has no constituent
        // lenses — so `0,5×` vanished from the pill and the list fell back to digital
        // rungs. Walking the preference list explicitly is the only ordering there is.
        for type in preferredDeviceTypes {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position.avPosition)
    }

    /// Whether the app may use the camera, asking once if nobody has been asked yet.
    static func requestAuthorization() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return status == .authorized
        #endif
    }
}

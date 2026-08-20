import CoreMotion
import Foundation

/// Observes device orientation and roll/pitch using CoreMotion to provide horizon level guidance.
public final class CameraMotionObserver: @unchecked Sendable {

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let lock = NSLock()
    private var isStarted = false
    private var lastWasLevel = false

    /// Callback reporting (rollDegrees: Double, isLevel: Bool)
    public var onMotionUpdate: (@Sendable (Double, Bool) -> Void)?

    public init() {
        motionQueue.name = "com.iosvault.camera.motionQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
    }

    public func start() {
        lock.lock()
        guard !isStarted, motionManager.isDeviceMotionAvailable else {
            lock.unlock()
            return
        }
        isStarted = true
        lastWasLevel = false
        lock.unlock()

        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handleMotion(motion)
        }
    }

    public func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        lock.unlock()

        motionManager.stopDeviceMotionUpdates()
    }

    private func handleMotion(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        // Calculate angle of inclination relative to horizon (in degrees)
        let rollRadians = atan2(-gravity.x, gravity.y)
        var rollDegrees = rollRadians * 180.0 / .pi

        // Normalize to -90...90 range around closest 90-degree step
        if rollDegrees > 45 {
            rollDegrees -= 90
        } else if rollDegrees < -45 {
            rollDegrees += 90
        }

        // Angle tolerance for level state: within ±0.75 degrees
        let isLevel = abs(rollDegrees) <= 0.75

        lock.lock()
        let transitionedToLevel = isLevel && !lastWasLevel
        lastWasLevel = isLevel
        let callback = onMotionUpdate
        lock.unlock()

        if transitionedToLevel {
            Task { @MainActor in
                CameraHaptic.selection.play()
            }
        }

        callback?(rollDegrees, isLevel)
    }
}

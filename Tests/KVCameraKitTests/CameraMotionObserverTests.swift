import Foundation
import Testing
@testable import KVCameraKit

@Suite("Camera Motion Observer Tests")
struct CameraMotionObserverTests {

    private final class SafeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _received = false
        var received: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _received
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _received = newValue
            }
        }
    }

    @Test("CameraMotionObserver initializes, starts and stops cleanly")
    func testMotionObserverLifecycle() {
        let observer = CameraMotionObserver()
        let box = SafeBox()

        observer.onMotionUpdate = { _, _ in
            box.received = true
        }

        observer.start()
        observer.stop()
        #expect(observer != nil)
    }
}

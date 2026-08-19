import AVFoundation

/// The four notifications that say the session stopped behaving, turned into closures.
///
/// Deliberately no policy: it does not decide whether to restart, and it does not know
/// whether the session was ever started. That gate lives with the session, because
/// "availability" is only meaningful for a session someone asked to run — reporting it
/// from `isRunning` alone painted "Camera is unavailable" over a session that had simply
/// never been started, which is every simulator run.
final class CameraSessionObserver: NSObject, @unchecked Sendable {

    /// A phone call, another app taking the camera, Split View.
    private let onInterrupted: @Sendable () -> Void
    private let onInterruptionEnded: @Sendable () -> Void
    /// `error` is passed on because only some are recoverable — see the service.
    private let onRuntimeError: @Sendable (AVError?) -> Void
    /// The scene changed enough that a one-shot focus should hand back to continuous.
    private let onSubjectAreaChange: @Sendable () -> Void

    init(
        onInterrupted: @escaping @Sendable () -> Void,
        onInterruptionEnded: @escaping @Sendable () -> Void,
        onRuntimeError: @escaping @Sendable (AVError?) -> Void,
        onSubjectAreaChange: @escaping @Sendable () -> Void
    ) {
        self.onInterrupted = onInterrupted
        self.onInterruptionEnded = onInterruptionEnded
        self.onRuntimeError = onRuntimeError
        self.onSubjectAreaChange = onSubjectAreaChange
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func observe(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
        // Not scoped to a device: the active device changes on every camera switch, and a
        // subscription pinned to the old one goes quiet without saying so.
        center.addObserver(
            self,
            selector: #selector(subjectAreaDidChange(_:)),
            name: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil
        )
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        onInterrupted()
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        onInterruptionEnded()
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        onRuntimeError(notification.userInfo?[AVCaptureSessionErrorKey] as? AVError)
    }

    @objc private func subjectAreaDidChange(_ notification: Notification) {
        onSubjectAreaChange()
    }
}

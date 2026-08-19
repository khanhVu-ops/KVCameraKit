import AVFoundation

/// The microphone, attached only while the user is in video mode.
///
/// Its own type because the reason it exists is a *policy* — never hold the mic for a
/// screen that may only take a photo — and that policy was previously spread across
/// `setupSession`, `setAudioEnabled` and two `…Locked` helpers whose contract was a
/// comment.
///
/// Every method must run on the session queue. It is not enforced by an actor because the
/// caller already serialises everything through that queue, and a second isolation domain
/// over the same `AVCaptureSession` would only add hops.
final class CameraAudioSession: @unchecked Sendable {

    private var input: AVCaptureDeviceInput?

    var isAttached: Bool { input != nil }

    /// Session queue only.
    ///
    /// Adding the microphone at setup put the orange in-use indicator on screen and
    /// switched the audio session to `.playAndRecord`, which stops whatever the user was
    /// listening to — both on a screen that may only ever take a photo.
    func attach(to session: AVCaptureSession) {
        guard input == nil else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try? audioSession.setActive(true)

        guard let device = AVCaptureDevice.default(for: .audio),
              let deviceInput = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if session.canAddInput(deviceInput) {
            session.addInput(deviceInput)
            input = deviceInput
        }
        session.commitConfiguration()
    }

    /// Session queue only.
    ///
    /// `.notifyOthersOnDeactivation` is what lets whatever the user was listening to
    /// resume. Leaving the session active held the audio route for as long as the app
    /// was open.
    func detach(from session: AVCaptureSession) {
        if let input = input {
            session.beginConfiguration()
            session.removeInput(input)
            session.commitConfiguration()
            self.input = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

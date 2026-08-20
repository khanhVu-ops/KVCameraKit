import AVFoundation
import CoreGraphics

/// The Camera Control button — the capacitive one below the side button on an iPhone 16 and
/// later.
///
/// Its own type because it is a whole second input surface with its own state: three
/// controls, a picker whose highlighted index has to keep agreeing with the on-screen pill,
/// and a delegate that reports when the system HUD takes the screen. None of that is
/// needed to take a photo, and on a device without the button none of it runs at all.
final class CameraHardwareControls: NSObject, @unchecked Sendable {

    /// Kept so the HUD's highlighted lens can follow a pinch or a tap on the pill. Without
    /// it the button would keep saying `1×` after the screen had moved on.
    private var lensPicker: AVCaptureIndexPicker?
    private var lensLevels: [CGFloat] = []
    private var installedDevice: AVCaptureDevice?
    private var installedLabels: CameraControlLabels?

    /// A lens was picked on the button: the index, and the factor it maps to. Applying it is
    /// the service's job — this type does not hold the device.
    private let onLensPicked: @Sendable (Int, CGFloat) -> Void
    private let onChange: @Sendable (CameraHardwareControlChange) -> Void

    init(
        onLensPicked: @escaping @Sendable (Int, CGFloat) -> Void,
        onChange: @escaping @Sendable (CameraHardwareControlChange) -> Void
    ) {
        self.onLensPicked = onLensPicked
        self.onChange = onChange
        super.init()
    }

    /// Session queue only.
    ///
    /// Three of the four slots AVFoundation allows, chosen because they are the settings
    /// this screen actually has: zoom, exposure compensation and the self-timer. Each one
    /// reports back through `onChange` instead of writing to the device behind the
    /// ViewModel's back, so the pill, the reticle and the timer badge stay truthful while
    /// the button is being used.
    func install(
        on session: AVCaptureSession,
        device: AVCaptureDevice,
        levels: [CGFloat],
        labels: CameraControlLabels,
        queue: DispatchQueue
    ) {
        guard session.supportsControls else { return }

        // Short-circuit if the configuration hasn't changed. Rebuilding controls on a running
        // session triggers an expensive capture pipeline rebuild that stalls sessionQueue.
        if installedDevice == device && lensLevels == levels && installedLabels == labels {
            syncSelectedLens(for: device)
            return
        }

        session.beginConfiguration()
        installLocked(on: session, device: device, levels: levels, labels: labels, queue: queue)
        session.commitConfiguration()
    }

    /// Session queue only. Must run inside an already open `session.beginConfiguration()` block.
    func installLocked(
        on session: AVCaptureSession,
        device: AVCaptureDevice,
        levels: [CGFloat],
        labels: CameraControlLabels,
        queue: DispatchQueue
    ) {
        guard session.supportsControls else { return }

        session.setControlsDelegate(self, queue: queue)
        for control in session.controls {
            session.removeControl(control)
        }

        lensLevels = levels
        installedDevice = device
        installedLabels = labels
        lensPicker = nil
        addLensPicker(to: session, device: device, labels: labels, queue: queue)
        addExposureSlider(to: session, device: device, labels: labels, queue: queue)
        addTimerPicker(to: session, labels: labels, queue: queue)
    }

    /// A picker over the lenses, not a continuous slider. The system's own Camera puts a
    /// discrete `1× / 2×` list on this button, the on-screen pill is already that list,
    /// and one control per value avoids a slider and a picker disagreeing about zoom.
    /// Continuous zoom stays where it belongs: pinch, and dragging the pill.
    private func addLensPicker(
        to session: AVCaptureSession,
        device: AVCaptureDevice,
        labels: CameraControlLabels,
        queue: DispatchQueue
    ) {
        guard lensLevels.count > 1, labels.lensOptions.count == lensLevels.count else { return }

        let picker = AVCaptureIndexPicker(
            labels.zoom,
            symbolName: "arrow.up.left.and.arrow.down.right",
            localizedIndexTitles: labels.lensOptions
        )
        picker.selectedIndex = Self.nearestLensIndex(in: lensLevels, for: device) ?? 0
        picker.setActionQueue(queue) { [weak self] index in
            guard let self = self, self.lensLevels.indices.contains(index) else { return }
            self.onLensPicked(index, self.lensLevels[index])
        }
        if session.canAddControl(picker) {
            session.addControl(picker)
            lensPicker = picker
        }
    }

    private func addExposureSlider(
        to session: AVCaptureSession,
        device: AVCaptureDevice,
        labels: CameraControlLabels,
        queue: DispatchQueue
    ) {
        let minBias = device.minExposureTargetBias
        let maxBias = device.maxExposureTargetBias
        guard minBias < maxBias else { return }

        let exposure = AVCaptureSlider(labels.exposure, symbolName: "sun.max", in: minBias...maxBias)
        exposure.value = device.exposureTargetBias
        exposure.setActionQueue(queue) { [weak self] value in
            self?.onChange(.exposureBias(value))
        }
        if session.canAddControl(exposure) {
            session.addControl(exposure)
        }
    }

    private func addTimerPicker(
        to session: AVCaptureSession,
        labels: CameraControlLabels,
        queue: DispatchQueue
    ) {
        guard !labels.timerOptions.isEmpty else { return }

        let timer = AVCaptureIndexPicker(
            labels.timer,
            symbolName: "timer",
            localizedIndexTitles: labels.timerOptions
        )
        timer.setActionQueue(queue) { [weak self] index in
            self?.onChange(.timerOptionIndex(index))
        }
        if session.canAddControl(timer) {
            session.addControl(timer)
        }
    }

    /// Keeps the HUD's highlighted lens in step with whatever moved the zoom — a pinch, a
    /// tap on the pill, or a camera switch.
    func syncSelectedLens(for device: AVCaptureDevice) {
        guard let picker = lensPicker,
              let index = Self.nearestLensIndex(in: lensLevels, for: device),
              picker.selectedIndex != index else { return }
        picker.selectedIndex = index
    }

    private static func nearestLensIndex(in levels: [CGFloat], for device: AVCaptureDevice) -> Int? {
        guard let factor = CameraZoomLadder.currentUIFactor(of: device) else { return nil }
        return CameraZoomLadder.nearestIndex(in: levels, forUIFactor: factor)
    }
}

extension CameraHardwareControls: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        onChange(.hudFullscreen(true))
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        onChange(.hudFullscreen(false))
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        onChange(.hudFullscreen(false))
    }
}

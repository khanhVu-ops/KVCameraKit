import AVFoundation
import CoreGraphics

/// Focus, exposure, torch and zoom, as operations on the device itself.
///
/// An extension rather than a `CameraFocusController` class, because none of these hold
/// state: each is one `lockForConfiguration` and a few property writes on a device the
/// caller already has. A class would own nothing and exist only to be injected.
extension AVCaptureDevice {

    /// One place that pairs `lockForConfiguration` with its unlock.
    ///
    /// Seven call sites each had their own `do { try lock } catch {}`, and each one was
    /// a chance to return early while still holding the lock.
    func configured(_ body: (AVCaptureDevice) -> Void) {
        do {
            try lockForConfiguration()
            defer { unlockForConfiguration() }
            body(self)
        } catch {}
    }

    /// One-shot focus and exposure at a point.
    ///
    /// `.autoFocus` is one shot and then holds, so the lock is simply the absence of
    /// anything that re-triggers it. Watching the subject area is what hands control back
    /// for an ordinary tap — the version before this never did, and one tap left focus
    /// locked for the rest of the session.
    func applyOneShotFocus(at pointOfInterest: CGPoint, locked: Bool) {
        configured { device in
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = pointOfInterest
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = pointOfInterest
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = !locked
        }
    }

    /// Back to continuous focus and exposure at the centre.
    func applyContinuousFocusAndExposure() {
        configured { device in
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = centre
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = centre
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(0)
            device.isSubjectAreaChangeMonitoringEnabled = false
        }
    }

    func applyExposureBias(_ bias: Float) {
        configured { device in
            let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
            device.setExposureTargetBias(clamped)
        }
    }

    /// `false` when the device has no torch, or it is momentarily unavailable — so the
    /// caller can leave its own flag alone rather than claiming a light that is not on.
    @discardableResult
    func applyTorch(on: Bool) -> Bool {
        guard hasTorch, isTorchAvailable else { return false }
        configured { device in
            device.torchMode = on ? .on : .off
        }
        return true
    }

    /// Zoom, in the units the user sees. Clamping happens in `CameraZoomLadder`.
    func applyZoom(uiFactor: CGFloat, animated: Bool) {
        configured { device in
            let clamped = CameraZoomLadder.deviceFactor(forUIFactor: uiFactor, on: device)
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 18.0)
            } else {
                device.videoZoomFactor = clamped
            }
        }
    }
}

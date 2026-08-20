import Foundation

/// Which of the two viewfinders draws the screen.
///
/// A flag, and the default is the old one — deliberately. A viewfinder is the single thing in
/// a camera that must never get worse: a preview that drops frames, shifts colour, changes
/// the framing or lags the shutter is not something the user can work around. So the Metal
/// path ships switched off, gets turned on where it can be watched, and reverts in one line
/// rather than in a hotfix.
///
/// The reason it exists at all is not speed. `AVCaptureVideoPreviewLayer` renders the session
/// straight into a `CALayer`, and nothing can be put in front of it — no LUT, no tone curve,
/// no beauty pass. Live filters are impossible until the app draws its own frames, so owning
/// the preview is the precondition for that work rather than an optimisation of this screen.
public enum CameraPreviewEngine: String, CaseIterable, Equatable, Sendable {

    /// `AVCaptureVideoPreviewLayer`. AVFoundation owns the pixels, the rotation and the
    /// aspect fill. Cheapest, most reliable, and a dead end for filtering.
    case system

    /// `MTKView` fed from `FrameSource`. The app owns every pixel, which is what makes a
    /// filter a fragment shader instead of an impossibility.
    ///
    /// Costs a real `AVCaptureVideoDataOutput` on the session — which on some devices lowers
    /// the maximum photo dimensions or disables zero-shutter-lag. That trade is exactly what
    /// running it behind a flag is for: it can be measured against the other engine on the
    /// same device, on the same screen, minutes apart.
    case metal

    /// Whether this engine needs the frame stream. Asked as a question about the engine for
    /// the same reason `CameraMode.needsFrames` is: the output attaches on subscription, and
    /// an engine that forgot to say it needed frames would render one black rectangle.
    var needsFrames: Bool {
        switch self {
        case .system: return false
        case .metal:  return true
        }
    }
}

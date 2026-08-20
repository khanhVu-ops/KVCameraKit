import Foundation

/// Which machinery writes a video file.
///
/// The same discipline as `CameraPreviewEngine`, for a stronger reason. A viewfinder that
/// regresses is visible immediately; a recorder that regresses is discovered *after* the
/// moment is gone. Nothing about a lost recording is recoverable, so the working path stays
/// the default and the new one earns promotion by being watched.
public enum CameraRecordingEngine: String, CaseIterable, Equatable, Sendable {

    /// `AVCaptureMovieFileOutput`. AVFoundation owns the encode, the container and the
    /// timing, and hands back a finished file. Extremely reliable, and a dead end: there is
    /// no point at which the app sees the bytes, so it can neither filter what is recorded
    /// nor encrypt it as it is produced.
    case movieFile

    /// `AVAssetWriter` fed from `FrameSource` and an audio tap. The app appends every sample
    /// itself, which is what makes recorded frames filterable and lets the bytes be
    /// encrypted on the way to disk rather than written in the clear and re-read.
    case assetWriter

    /// Whether this engine records from the shared sample-buffer taps rather than its own
    /// output.
    ///
    /// It also decides which outputs go on the session at all. The two are deliberately
    /// **mutually exclusive**: `AVCaptureMovieFileOutput` and `AVCaptureVideoDataOutput`
    /// coexisting on one session is a constraint that varies by device and configuration, and
    /// the failure mode is `canAddOutput` quietly returning `false` — a frame tap that never
    /// attaches, so a Metal preview shows black and a scanner never finds a page, with
    /// nothing logged. Attaching only what the chosen engine needs removes the question.
    var usesSampleBuffers: Bool {
        switch self {
        case .movieFile:   return false
        case .assetWriter: return true
        }
    }
}

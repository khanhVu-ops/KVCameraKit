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

    /// The same writer, in fragmented mode, with the segments handed to the host as they are
    /// produced instead of written to a file.
    ///
    /// This is what `.assetWriter` was for. Nothing unencrypted reaches the disk, and peak
    /// memory is one segment rather than the clip — twice over, which is what
    /// "read the finished file and seal it" costs: a plaintext file, a copy of it in memory,
    /// and the ciphertext beside that. For a five-minute 4K recording those are gigabytes,
    /// and the plaintext one is on disk inside an app whose whole promise is that it is not.
    ///
    /// The output is a **fragmented MP4** rather than a QuickTime movie, which is not a
    /// detail: a `.mov` is finalised by rewriting its header at the end, so it cannot be
    /// produced as an append-only stream at all. An fMP4 is an initialization segment
    /// followed by self-contained media segments, so concatenating what arrives *is* the
    /// file — and a host that stores the segments in order has a playable recording without
    /// ever seeking backwards.
    case streamingAssetWriter

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
        case .movieFile:                            return false
        case .assetWriter, .streamingAssetWriter:   return true
        }
    }

    /// Whether the bytes go to the host rather than to a file.
    ///
    /// The screen asks this before a recording starts, because the destination has to be
    /// opened first — and if the host cannot open one, the recording is refused rather than
    /// quietly written somewhere else.
    var streamsToHost: Bool {
        switch self {
        case .movieFile, .assetWriter:  return false
        case .streamingAssetWriter:     return true
        }
    }
}

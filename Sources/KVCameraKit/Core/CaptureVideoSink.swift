import Foundation

/// What is known about a recording only once it has ended.
///
/// It arrives at the *end* deliberately, and that is the whole difference between this and
/// `CaptureArtifact`: a duration, a byte count and a poster frame cannot be stated before
/// the last sample, so a streaming host has to be able to open a destination without them
/// and be told afterwards. Nothing here is the bytes — those have already gone.
public struct CaptureVideoSummary: Sendable {
    /// `mp4`, because a streamed recording is a fragmented MP4 rather than a QuickTime
    /// movie. Reported rather than assumed, for the same reason a photo's extension is
    /// sniffed: a container named wrongly is a file some players refuse.
    public let fileExtension: String
    /// Everything handed to the sink, summed. The host cannot count it as reliably —
    /// ciphertext is longer than plaintext, and what the user is told is the size of what
    /// they recorded.
    public let byteCount: Int
    public let duration: TimeInterval?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// A poster frame, JPEG, taken shortly after recording starts.
    ///
    /// Captured on the way in because by the time recording stops there is no plaintext file
    /// left to read one from — the bytes went straight to the host and, in this app's case,
    /// are encrypted. The recorder avoids the literal first frame so exposure, focus and the
    /// user's shutter gesture have time to settle.
    public let posterData: Data?

    public init(
        fileExtension: String,
        byteCount: Int,
        duration: TimeInterval?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        posterData: Data?
    ) {
        self.fileExtension = fileExtension
        self.byteCount = byteCount
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.posterData = posterData
    }
}

/// Somewhere to put video bytes *while* the camera is still producing them.
///
/// `CameraArtifactHandler.store` takes a finished `CaptureArtifact`, which for video means
/// the whole clip in memory — and, before that, a whole plaintext file on disk for it to be
/// read from. For a host that encrypts what it stores, both are the thing it exists to
/// prevent: a five-minute 4K clip is a gigabyte of plaintext written to disk, read back,
/// and held twice over while it is sealed.
///
/// This is the other shape: the camera hands over one segment at a time as the encoder
/// produces it, and the host does whatever storing means to it — encrypt, append, commit.
/// Peak memory is one segment. Nothing unencrypted is ever written.
///
/// Calls are serialised and ordered: `write` is never re-entered, segments arrive in the
/// order they must be concatenated, and exactly one of `finish` or `cancel` ends the
/// sequence.
public protocol CaptureVideoSink: Sendable {
    /// One segment of the file. The **first** is the initialization segment — the header
    /// without which none of the others can be decoded — so a sink that loses or reorders
    /// segments produces a file nothing can open.
    func write(_ chunk: Data) async throws

    /// No more segments are coming; commit what was written.
    func finish(_ summary: CaptureVideoSummary) async throws -> CaptureReceipt

    /// Something failed, here or upstream. Whatever was written must not be kept: a
    /// truncated recording missing its final segments is a file that looks stored and does
    /// not play.
    func cancel() async
}

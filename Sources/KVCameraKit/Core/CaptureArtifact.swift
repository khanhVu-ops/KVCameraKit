import Foundation

/// One thing that came off the sensor, ready for whoever owns storage.
///
/// Deliberately a list at the handler boundary rather than a single value: a scanned
/// document is n pages and a burst is n frames, both from one shutter press. Designing
/// that in now costs nothing and saves breaking the protocol later.
public struct CaptureArtifact: Sendable {
    public enum Kind: Sendable {
        case photo
        case video
        /// A scanned page: perspective-corrected and tone-adjusted, but still an image.
        ///
        /// A separate kind rather than `.photo` because the host files it differently — a
        /// receipt belongs with documents, not in the camera roll — and because the
        /// distinction is the package's to report: only the scanner knows a crop was
        /// applied. What the host does with that is the host's business, which is the
        /// whole shape of this boundary.
        case document
    }

    public let kind: Kind
    public let data: Data
    /// Sniffed from the bytes, not assumed — capturing HEVC yields an HEIC container.
    public let fileExtension: String
    /// The small representation AVFoundation delivered alongside the full frame, when
    /// there was one. The host may use it instead of decoding the full frame again.
    public let previewData: Data?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let duration: TimeInterval?

    public init(
        kind: Kind,
        data: Data,
        fileExtension: String,
        previewData: Data? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        duration: TimeInterval? = nil
    ) {
        self.kind = kind
        self.data = data
        self.fileExtension = fileExtension
        self.previewData = previewData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }
}

/// What the host says once it has stored the artifacts.
public struct CaptureReceipt: Sendable {
    /// Thumbnail for the corner button. The host produces it, because only the host knows
    /// what it actually stored.
    public let thumbnailData: Data?

    public init(thumbnailData: Data?) {
        self.thumbnailData = thumbnailData
    }
}

/// The one thing this package needs from its host: somewhere to put the bytes.
///
/// Everything the camera used to know about — AES-GCM, vault items, master keys, a
/// thumbnail cache — lives behind these two calls. That is the whole point of the
/// package boundary: the camera captures, the host decides what capture *means*.
public protocol CameraArtifactHandler: Sendable {
    /// Cheap, and called *first*: a display thumbnail for the corner button.
    ///
    /// Two members rather than one because the order matters. The capture animation lands
    /// on the corner in about half a second, and the encrypted write takes longer than
    /// that — so the thumbnail has to be available before the write finishes, or the card
    /// cross-fades onto nothing and the real image pops in afterwards.
    func displayThumbnail(for artifacts: [CaptureArtifact]) async -> Data?

    /// Called off the main actor. Free to be slow: the capture animation does not wait
    /// for it, and `CameraState.isSealing` reports that it is still running.
    func store(_ artifacts: [CaptureArtifact]) async throws -> CaptureReceipt

    /// The newest thumbnail already in the host's library, for the corner button on
    /// appearance. `nil` when there is nothing yet.
    func latestThumbnail() async -> Data?

    /// A destination for video bytes as they are produced, or `nil` if this host would
    /// rather be handed a finished `CaptureArtifact`.
    ///
    /// Optional on purpose. `store` is the simple contract and stays the default, because a
    /// host that just drops a clip into the camera roll gains nothing from streaming and
    /// would have to implement it to compile. A host that *encrypts* gains the entire point
    /// of it: see `CaptureVideoSink`.
    ///
    /// Called once per recording, before the first frame. Throwing here refuses the
    /// recording outright — which is the right answer when the destination cannot be opened,
    /// and much better than the alternative it replaces: falling back to a plaintext file
    /// because the vault happened to be locked.
    func makeVideoSink() async throws -> (any CaptureVideoSink)?
}

public extension CameraArtifactHandler {
    /// No streaming destination. The recorder writes a file and `store` is handed the
    /// finished artifact, exactly as before this existed.
    func makeVideoSink() async throws -> (any CaptureVideoSink)? { nil }
}

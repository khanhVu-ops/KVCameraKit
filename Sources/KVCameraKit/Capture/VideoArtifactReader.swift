import AVFoundation
import UIKit

/// Turns a finished recording into an artifact.
///
/// Duration, dimensions and a poster frame are camera knowledge, not storage knowledge,
/// so they are read here rather than pushed onto the host. The host gets bytes plus the
/// facts about them.
enum VideoArtifactReader {

    /// Reads the recording and removes it, on every path.
    ///
    /// The plaintext file must not survive this call: an earlier version deleted it only
    /// after a successful import, so every failure left an unencrypted clip on disk —
    /// inside an app whose entire promise is that it does not.
    ///
    /// `.mappedIfSafe` keeps the clip out of dirty memory. This is still not enough for a
    /// long 4K recording, because the *ciphertext* the host produces is a second full
    /// copy; streaming encryption is the real fix and is not this function's job.
    static func consume(at url: URL) async throws -> CaptureArtifact {
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let metadata = await Self.metadata(at: url)

        return CaptureArtifact(
            kind: .video,
            data: data,
            fileExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension,
            previewData: metadata.poster,
            pixelWidth: metadata.width,
            pixelHeight: metadata.height,
            duration: metadata.duration
        )
    }

    private static func metadata(
        at url: URL
    ) async -> (poster: Data?, duration: TimeInterval?, width: Int?, height: Int?) {
        let asset = AVURLAsset(url: url)

        let duration = try? await asset.load(.duration).seconds
        var width: Int?
        var height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            // The natural size is pre-rotation; a portrait recording reports landscape
            // until the transform is applied.
            let oriented = size.applying(transform)
            width = Int(abs(oriented.width))
            height = Int(abs(oriented.height))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        var poster: Data?
        let preferredTime = VideoPosterSelection.preferredTime(for: duration)
        let candidateTimes = preferredTime == .zero ? [.zero] : [preferredTime, .zero]
        for time in candidateTimes {
            if let image = try? await generator.image(at: time).image {
                poster = UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
                break
            }
        }

        return (poster, duration.flatMap { $0.isFinite ? $0 : nil }, width, height)
    }
}

/// Chooses a representative early frame without freezing the actual opening frame into every
/// library thumbnail. Kept pure so short-clip clamping is testable without an AVAsset.
enum VideoPosterSelection {
    static let settledOffset: TimeInterval = 0.5

    static func preferredTime(for duration: TimeInterval?) -> CMTime {
        let seconds: TimeInterval
        if let duration, duration.isFinite, duration > 0 {
            seconds = min(settledOffset, duration / 2)
        } else {
            seconds = settledOffset
        }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }
}

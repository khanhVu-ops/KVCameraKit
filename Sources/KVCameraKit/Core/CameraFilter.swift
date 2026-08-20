import Foundation

/// A named look the user can pick.
///
/// A `CameraTone` with a name, and deliberately nothing more yet. The next two steps —
/// lookup tables and skin smoothing — arrive as extra members here rather than as a second
/// concept beside it, so the picker, the state and the capture path do not have to learn
/// about them twice.
///
/// Filters are **photo mode only**, and that is a correctness rule rather than a limitation:
/// a recording made on the movie-file engine never passes through this app's hands, so a
/// filtered viewfinder there would promise something the file cannot carry. See
/// `CameraMode.supportsFilters`.
public struct CameraFilter: Identifiable, Equatable, Sendable {

    /// Stable, and not the display name: it is what a host would persist, and a name is
    /// translated.
    public let id: String
    /// Resolved from the package's own tables — a literal, so `check-l10n.sh` can see it.
    public let title: LocalizedStringResource
    public let tone: CameraTone

    public init(id: String, title: LocalizedStringResource, tone: CameraTone) {
        self.id = id
        self.title = title
        self.tone = tone
    }

    /// No adjustment at all. Its tone is neutral, which is what lets the whole filter stage be
    /// skipped rather than multiplied by an identity matrix on every pixel of every frame.
    public static let original = CameraFilter(
        id: "original",
        title: .cameraKit("Original"),
        tone: .neutral
    )

    /// More colour and a little more contrast — the "make it pop" preset every camera has.
    public static let vivid = CameraFilter(
        id: "vivid",
        title: .cameraKit("Vivid"),
        tone: CameraTone(contrast: 1.12, saturation: 1.35)
    )

    public static let warm = CameraFilter(
        id: "warm",
        title: .cameraKit("Warm"),
        tone: CameraTone(exposure: 0.06, saturation: 1.08, warmth: 0.55)
    )

    public static let cool = CameraFilter(
        id: "cool",
        title: .cameraKit("Cool"),
        tone: CameraTone(contrast: 1.06, saturation: 0.95, warmth: -0.5)
    )

    /// Greyscale with a little contrast, which is what stops a desaturated frame reading as a
    /// mistake rather than a choice.
    public static let mono = CameraFilter(
        id: "mono",
        title: .cameraKit("Mono"),
        tone: CameraTone(contrast: 1.15, saturation: 0)
    )

    /// The order they appear in the picker. `original` first, because getting back to it has to
    /// be the easiest thing on the strip.
    public static let all: [CameraFilter] = [.original, .vivid, .warm, .cool, .mono]
}

import SwiftUI

/// The host's tokens, handed in.
///
/// The camera used to reach straight for `Spacing`, `AppFont` and `Radius`, which is
/// exactly the coupling that stops a package being reusable. Injected instead, with
/// defaults that look like the system camera so a host that does not care can ignore it.
///
/// Note what is *not* in here: the viewfinder chrome colours. Yellow reticles, a red
/// record dot and white-on-black glass are what a camera looks like — they are the
/// package's identity, not the host's brand, and making them configurable would invite
/// a lilac shutter button.
public struct CameraTheme: Sendable {
    public var spacingXS: CGFloat
    public var spacingS: CGFloat
    public var spacingM: CGFloat
    public var spacingL: CGFloat
    public var largeCornerRadius: CGFloat
    public var titleFont: Font
    public var bodyFont: Font
    public var bodyStrongFont: Font

    public init(
        spacingXS: CGFloat = 4,
        spacingS: CGFloat = 8,
        spacingM: CGFloat = 16,
        spacingL: CGFloat = 24,
        largeCornerRadius: CGFloat = 20,
        titleFont: Font = .system(.title2, design: .rounded).weight(.semibold),
        bodyFont: Font = .system(.body),
        bodyStrongFont: Font = .system(.body).weight(.semibold)
    ) {
        self.spacingXS = spacingXS
        self.spacingS = spacingS
        self.spacingM = spacingM
        self.spacingL = spacingL
        self.largeCornerRadius = largeCornerRadius
        self.titleFont = titleFont
        self.bodyFont = bodyFont
        self.bodyStrongFont = bodyStrongFont
    }

    public static let `default` = CameraTheme()
}

private struct CameraThemeKey: EnvironmentKey {
    static let defaultValue = CameraTheme.default
}

public extension EnvironmentValues {
    var cameraTheme: CameraTheme {
        get { self[CameraThemeKey.self] }
        set { self[CameraThemeKey.self] = newValue }
    }
}

public extension View {
    /// Hands the camera the host's spacing and type scale.
    func cameraTheme(_ theme: CameraTheme) -> some View {
        environment(\.cameraTheme, theme)
    }
}

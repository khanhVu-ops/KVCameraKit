import SwiftUI

/// Focus reticle with an exposure slider beside it.
///
/// The reticle is corner brackets over a faint frame rather than a single hairline
/// square: at one point two of the box's own tick marks sat under the exposure track, so
/// the two controls read as one broken shape. The brackets also survive a bright scene,
/// which a 1.2 pt line does not — hence the shadow underneath.
///
/// The slider now lives entirely **outside** the box. It used to be positioned with a
/// `Spacer().frame(width: 48)` against a box of half-width 35, so a 96 pt track crossed
/// the box's right edge and the sun icon floated on top of the frame.
struct CameraFocusView: View {
    let position: CGPoint
    /// A long press pinned focus and exposure. The reticle then stays put instead of
    /// fading, because it is the only thing on screen saying the camera has stopped
    /// metering.
    let isLocked: Bool
    let initialExposureBias: Float
    let onExposureChange: ((Float) -> Void)?
    /// Fires once the reticle has faded out. Without it the faded view stays in the
    /// hierarchy for the life of the screen, holding its dismiss task, and every
    /// further tap adds another one.
    let onExpired: (() -> Void)?

    /// Box, gap and track are stated once so they cannot drift into each other again.
    private static let boxSide: CGFloat = 78
    private static let bracket: CGFloat = 13
    private static let gap: CGFloat = 16
    private static let trackHeight: CGFloat = 104
    private static let travel: CGFloat = 46

    private var trackCentreX: CGFloat { Self.boxSide / 2 + Self.gap }

    @State private var scale: CGFloat = 1.3
    @State private var opacity: Double = 1.0
    @State private var exposureOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDraggingExposure = false
    @State private var dismissTask: Task<Void, Never>?

    init(
        position: CGPoint,
        isLocked: Bool = false,
        initialExposureBias: Float = 0.0,
        onExposureChange: ((Float) -> Void)? = nil,
        onExpired: (() -> Void)? = nil
    ) {
        self.position = position
        self.isLocked = isLocked
        self.initialExposureBias = initialExposureBias
        self.onExposureChange = onExposureChange
        self.onExpired = onExpired
    }

    var body: some View {
        ZStack {
            reticle
            exposureSlider
                .offset(x: trackCentreX)
        }
        .contentShape(Rectangle())
        .frame(width: 230, height: 230)
        .scaleEffect(scale)
        .opacity(opacity)
        .position(position)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dismissTask?.cancel()
                    if !isDraggingExposure {
                        isDraggingExposure = true
                        dragStartOffset = exposureOffset
                        opacity = 1.0
                    }
                    // Drag up = brighter (negative translation.height), Drag down = darker
                    let newOffset = dragStartOffset + value.translation.height
                    let clamped = max(-Self.travel, min(newOffset, Self.travel))
                    exposureOffset = clamped
                    onExposureChange?(Float(-clamped / Self.travel) * 2.5) // -2.5 EV to +2.5 EV
                }
                .onEnded { _ in
                    isDraggingExposure = false
                    scheduleFadeOut()
                }
        )
        .onAppear {
            exposureOffset = CGFloat(-initialExposureBias / 2.5) * Self.travel
            withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
                scale = 1.0
            }
            scheduleFadeOut()
        }
        .onDisappear {
            dismissTask?.cancel()
        }
    }

    private var reticle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.yellow.opacity(0.30), lineWidth: 1.0)

            cornerBrackets
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: isLocked ? 2.6 : 2.0, lineCap: .round))
        }
        .frame(width: Self.boxSide, height: Self.boxSide)
        .shadow(color: Color.black.opacity(0.45), radius: 2.5, x: 0, y: 1)
    }

    /// Four L-shaped corners, drawn as one path so it is one layer to composite.
    private var cornerBrackets: Path {
        let side = Self.boxSide
        let arm = Self.bracket
        var path = Path()

        path.move(to: CGPoint(x: 0, y: arm))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: arm, y: 0))

        path.move(to: CGPoint(x: side - arm, y: 0))
        path.addLine(to: CGPoint(x: side, y: 0))
        path.addLine(to: CGPoint(x: side, y: arm))

        path.move(to: CGPoint(x: side, y: side - arm))
        path.addLine(to: CGPoint(x: side, y: side))
        path.addLine(to: CGPoint(x: side - arm, y: side))

        path.move(to: CGPoint(x: arm, y: side))
        path.addLine(to: CGPoint(x: 0, y: side))
        path.addLine(to: CGPoint(x: 0, y: side - arm))

        return path
    }

    private var exposureSlider: some View {
        ZStack {
            Capsule()
                .fill(Color.yellow.opacity(0.55))
                .frame(width: 1.5, height: Self.trackHeight)
                .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)

            Image(systemName: "sun.max.fill")
                .font(.system(size: isDraggingExposure ? 16 : 14, weight: .bold))
                .foregroundStyle(Color.yellow)
                .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 1)
                .shadow(
                    color: Color.yellow.opacity(isDraggingExposure ? 0.9 : 0.35),
                    radius: isDraggingExposure ? 8 : 3
                )
                .scaleEffect(isDraggingExposure ? 1.2 : 1.0)
                .offset(y: exposureOffset)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isDraggingExposure)
        }
    }

    private func scheduleFadeOut() {
        dismissTask?.cancel()
        guard !isLocked else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, !isDraggingExposure else { return }
            withAnimation(.easeOut(duration: 0.6)) {
                opacity = 0.0
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            onExpired?()
        }
    }
}

#Preview("Focus reticle") {
    ZStack {
        Color.black
        CameraFocusView(position: CGPoint(x: 160, y: 160), onExposureChange: { _ in })
    }
    .frame(width: 320, height: 320)
}

#Preview("Focus reticle - AE/AF locked") {
    ZStack {
        Color.black
        CameraFocusView(position: CGPoint(x: 160, y: 160), isLocked: true, onExposureChange: { _ in })
    }
    .frame(width: 320, height: 320)
}

#Preview("Focus reticle - exposure raised") {
    ZStack {
        Color.black
        CameraFocusView(
            position: CGPoint(x: 160, y: 160),
            initialExposureBias: 1.8,
            onExposureChange: { _ in }
        )
    }
    .frame(width: 320, height: 320)
}

import SwiftUI

/// In-viewfinder lens selector, built from the lenses the hardware reports.
///
/// Two things changed from the version that hard-coded `0,5 · 1x · 2 · 3`. The list now
/// comes from `availableZoomLevels()`, so a single-lens phone gets no pill instead of a
/// `0,5` button that clamped back to 1x. And the numbers are formatted through
/// `Text(_:format:)` rather than written as literals — `"0,5"` was a comma for everyone,
/// including the locales that use a point.
struct CameraZoomPicker: View {
    let levels: [CGFloat]
    let currentZoom: CGFloat
    let onSelectZoom: (CGFloat) -> Void
    /// Continuous zoom while dragging across the pill; `animated` is false so the lens
    /// tracks the finger instead of ramping behind it.
    let onZoomTo: (CGFloat, Bool) -> Void

    /// Points of horizontal drag that double the zoom. Exponential rather than linear
    /// because zoom is perceived in stops: 1→2 has to feel like the same gesture as 2→4.
    private static let pointsPerDoubling: CGFloat = 130

    @Namespace private var zoomNamespace
    @State private var dragBaseZoom: CGFloat?

    /// The chip the current zoom belongs to. Between two lenses the nearer one keeps the
    /// highlight and shows the live value, which is how Camera.app reads while pinching.
    private var selectedLevel: CGFloat? {
        levels.min(by: { abs($0 - currentZoom) < abs($1 - currentZoom) })
    }

    var body: some View {
        if levels.count > 1 {
            picker
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            ForEach(levels, id: \.self) { level in
                let isSelected = selectedLevel == level

                Button {
                    CameraHaptic.selection.play()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                        onSelectZoom(level)
                    }
                } label: {
                    chip(for: level, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .fixedSize()
        .contentShape(Capsule())
        // A wheel, on top of the chips. `minimumDistance` is what keeps the buttons
        // usable: below it the gesture never starts and the tap goes through.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let base = dragBaseZoom ?? currentZoom
                    if dragBaseZoom == nil { dragBaseZoom = base }
                    let doublings = value.translation.width / Self.pointsPerDoubling
                    onZoomTo(base * pow(2, doublings), false)
                }
                .onEnded { _ in
                    dragBaseZoom = nil
                    CameraHaptic.light.play()
                    onZoomTo(currentZoom, true)
                }
        )
    }

    /// A capsule rather than a circle, and a minimum width rather than a fixed one: the
    /// selected chip carries the live factor, so it has to hold `2,4×` as comfortably as
    /// `1×` — inside a fixed 44 pt circle the longer label pressed against the edges.
    ///
    /// Split out of the `ForEach` body because inline it defeated the type checker.
    private func chip(for level: CGFloat, isSelected: Bool) -> some View {
        label(for: level, isSelected: isSelected)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 38)
            .background { chipBackground(isSelected: isSelected) }
            .contentShape(Capsule())
    }

    @ViewBuilder
    private func chipBackground(isSelected: Bool) -> some View {
        if isSelected {
            Capsule()
                .fill(Color.white.opacity(0.20))
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.6), Color.white.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .matchedGeometryEffect(id: "ZOOM_PILL_BG", in: zoomNamespace)
                .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 1)
        }
    }

    /// The selected chip shows the live factor with a multiplication sign; the others
    /// show their own lens. Pinching to 2.4 therefore reads `2,4×` rather than snapping
    /// the label back to the nominal `2`.
    private func label(for level: CGFloat, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            Text(
                isSelected ? currentZoom : level,
                format: .number.precision(.fractionLength(0...1))
            )
            .contentTransition(.numericText())

            if isSelected {
                Text(verbatim: "×")
            }
        }
        .font(.system(size: 13, weight: isSelected ? .bold : .semibold, design: .rounded))
        .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.85))
        .shadow(color: isSelected ? Color.yellow.opacity(0.5) : Color.clear, radius: 4, x: 0, y: 0)
        .animation(.easeOut(duration: 0.18), value: currentZoom)
    }
}

#Preview("Zoom Picker - Pro triple camera") {
    ZStack {
        Color.black
        CameraZoomPicker(levels: [0.5, 1.0, 2.0, 5.0], currentZoom: 1.0, onSelectZoom: { _ in }, onZoomTo: { _, _ in })
    }
    .frame(width: 320, height: 100)
}

#Preview("Zoom Picker - iPhone 16 dual wide") {
    ZStack {
        Color.black
        CameraZoomPicker(levels: [0.5, 1.0, 2.0, 3.0], currentZoom: 2.0, onSelectZoom: { _ in }, onZoomTo: { _, _ in })
    }
    .frame(width: 320, height: 100)
}

#Preview("Zoom Picker - Pinched between lenses") {
    ZStack {
        Color.black
        CameraZoomPicker(levels: [0.5, 1.0, 2.0], currentZoom: 2.4, onSelectZoom: { _ in }, onZoomTo: { _, _ in })
    }
    .frame(width: 320, height: 100)
}

#Preview("Zoom Picker - Single lens hides itself") {
    ZStack {
        Color.black
        CameraZoomPicker(levels: [], currentZoom: 1.0, onSelectZoom: { _ in }, onZoomTo: { _, _ in })
    }
    .frame(width: 320, height: 100)
}

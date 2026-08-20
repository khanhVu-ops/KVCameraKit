import SwiftUI

/// A Liquid Glass picker for selecting the privacy censor mode (Off / Mosaic / Blur / Censor Bar).
public struct CameraCensorPicker: View {

    let selectedMode: CameraCensorMode
    let onSelect: (CameraCensorMode) -> Void

    public init(
        selectedMode: CameraCensorMode,
        onSelect: @escaping (CameraCensorMode) -> Void
    ) {
        self.selectedMode = selectedMode
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(CameraCensorMode.allCases, id: \.self) { mode in
                chip(for: mode)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.55))
                .background(.ultraThinMaterial.opacity(0.4))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
        }
    }

    private func chip(for mode: CameraCensorMode) -> some View {
        let isSelected = mode == selectedMode

        return Button {
            CameraHaptic.selection.play()
            onSelect(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.systemIconName)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))

                Text(mode.title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.yellow.opacity(0.18))
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1.5)
                        }
                        .shadow(color: Color.yellow.opacity(0.3), radius: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isSelected)
    }
}

#Preview("Censor Picker") {
    ZStack {
        Color.black.ignoresSafeArea()
        CameraCensorPicker(selectedMode: .mosaic, onSelect: { _ in })
    }
}

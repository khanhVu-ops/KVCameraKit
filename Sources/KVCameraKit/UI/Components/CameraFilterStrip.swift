import SwiftUI

/// The filter shelf: one chip per look, each showing the scene in front of the camera.
///
/// Designed in the modern Apple Photographic Styles aesthetic: a sleek, grounded carousel
/// with live rendered looks, glowing active card indicator, and tactile haptics.
struct CameraFilterStrip: View {

    let filters: [CameraFilter]
    let selectedID: String
    /// Where the chips get their picture. `nil` on a canvas or before the first frame lands,
    /// and then the chips fall back to a colour ramp.
    let frames: (any FrameSource)?
    let onSelect: (CameraFilter) -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.cameraTheme) private var theme
    @State private var thumbnails: [String: CGImage] = [:]

    private static let chipWidth: CGFloat = 62
    private static let chipHeight: CGFloat = 82
    private static let cardCornerRadius: CGFloat = 14

    private var activeFilter: CameraFilter? {
        filters.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(spacing: 8) {
            headerBadge
            cardCarousel
        }
        .padding(.vertical, 8)
        .background(backgroundLayer)
        .padding(.horizontal, 10)
        .task {
            await loadThumbnails()
        }
    }

    @ViewBuilder
    private var headerBadge: some View {
        if let active = activeFilter {
            HStack(spacing: 6) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.yellow)

                Text(active.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.yellow)
                    .tracking(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.5))
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                    }
            }
            .padding(.top, 4)
        }
    }

    private var cardCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(filters) { filter in
                        chip(for: filter)
                            .id(filter.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .onAppear {
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onChange(of: selectedID) { _, newID in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.black.opacity(0.45))
            .background(.ultraThinMaterial.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }

    private func chip(for filter: CameraFilter) -> some View {
        let isSelected = filter.id == selectedID

        return Button {
            CameraHaptic.selection.play()
            onSelect(filter)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let image = thumbnails[filter.id] {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: Self.chipWidth, height: Self.chipHeight)
                .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.yellow : Color.white.opacity(0.2),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
                .shadow(
                    color: isSelected ? Color.yellow.opacity(0.35) : Color.black.opacity(0.3),
                    radius: isSelected ? 6 : 3,
                    x: 0,
                    y: 2
                )

                Text(filter.title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: Self.chipWidth + 16)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.04 : 0.94)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }

    /// One frame, five looks, off the main actor.
    private func loadThumbnails() async {
        guard let frames, thumbnails.isEmpty else { return }
        let tones = filters.map(\.tone)
        let ids = filters.map(\.id)

        guard let base = await ToneRenderer.thumbnailBase(from: frames) else { return }
        let rendered = await Task.detached(priority: .userInitiated) {
            ToneRenderer.thumbnails(base: base, tones: tones)
        }.value

        thumbnails = Dictionary(uniqueKeysWithValues: zip(ids, rendered))
    }
}

#Preview("Filter strip") {
    VStack(spacing: 24) {
        CameraFilterStrip(
            filters: CameraFilter.all,
            selectedID: "original",
            frames: nil,
            onSelect: { _ in }
        )
        CameraFilterStrip(
            filters: CameraFilter.all,
            selectedID: "vivid",
            frames: nil,
            onSelect: { _ in }
        )
    }
    .padding()
    .background(Color.black)
}

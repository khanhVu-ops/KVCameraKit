import SwiftUI

/// The most recent capture, sitting where the flight animation lands.
///
/// A rounded square rather than a circle, for a geometric reason: the flying card is
/// square, and a uniform scale cannot turn a tall viewfinder frame into a circle
/// without warping the photo. Matching the destination shape is also what Camera.app
/// does.
///
/// The decode is the other reason this is its own view. `UIImage(data:)` inside a
/// `body` re-decodes the JPEG on every unrelated state change — and this screen
/// changes state on every zoom tick and every second of recording. Here it happens
/// once per image, downscaled to the size actually drawn.
struct CameraThumbnailButton: View {
    let imageData: Data?
    /// Encryption and the vault write are still running.
    let isSealing: Bool
    /// Driven by the parent so the bounce lands on the same frame as the card.
    let scale: CGFloat
    let action: () -> Void

    static let side: CGFloat = 50
    static let cornerRadius: CGFloat = 14

    @State private var image: UIImage?
    @State private var isSpinning = false

    var body: some View {
        Button(action: action) {
            content
        }
        .buttonStyle(.plain)
        .disabled(imageData == nil)
    }

    private var content: some View {
        ZStack {
            if let image = image {
                ZStack {
                    stackCard(rotation: -9, xOffset: -4)
                    stackCard(rotation: 7, xOffset: 4)
                    primaryCard(image)
                }
            } else {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: Self.side, height: Self.side)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1.0)
                    )
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.white.opacity(0.4))
                    )
            }

            // Indeterminate on purpose: `ImportMediaUseCase` reports no progress, and a
            // bar that invents one is worse than an arc that admits it is only "busy".
            if isSealing {
                RoundedRectangle(cornerRadius: Self.cornerRadius + 4, style: .continuous)
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                    .frame(width: Self.side + 8, height: Self.side + 8)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: isSpinning)
                    .shadow(color: Color.yellow.opacity(0.5), radius: 4)
                    .onAppear { isSpinning = true }
                    .onDisappear { isSpinning = false }
                    .transition(.opacity)
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(scale)
        .animation(.easeInOut(duration: 0.2), value: isSealing)
        .onAppear { image = Self.decode(imageData) }
        .onChange(of: imageData) { _, newValue in
            image = Self.decode(newValue)
        }
    }

    /// Two translucent cards make the control read as a library stack while keeping the
    /// latest capture as the only decoded bitmap. Repeating the image on every layer would
    /// triple the texture work for details that are almost entirely covered.
    private func stackCard(rotation: Double, xOffset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius - 2, style: .continuous)
            .fill(Color.white.opacity(0.18))
            .frame(width: Self.side - 4, height: Self.side - 4)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius - 2, style: .continuous)
                    .stroke(Color.white.opacity(0.38), lineWidth: 1)
            }
            .rotationEffect(.degrees(rotation))
            .offset(x: xOffset, y: 1)
            .shadow(color: Color.black.opacity(0.28), radius: 3, x: 0, y: 2)
            .accessibilityHidden(true)
    }

    private func primaryCard(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: Self.side, height: Self.side)
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.72), Color.white.opacity(0.24)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(0.42), radius: 6, x: 0, y: 2)
    }

    /// Downscaled at decode time. The source is either a 320 px vault thumbnail or a
    /// ~1 MP capture preview, and both were being decoded at full size for a 50 pt slot.
    private static func decode(_ data: Data?) -> UIImage? {
        guard let data = data, let image = UIImage(data: data) else { return nil }
        let target = CGSize(width: side * 3, height: side * 3)
        return image.preparingThumbnail(of: target) ?? image
    }
}

#Preview("Thumbnail - Sealing") {
    ZStack {
        Color.black
        CameraThumbnailButton(imageData: nil, isSealing: true, scale: 1.0, action: {})
    }
    .frame(width: 200, height: 200)
}

#Preview("Thumbnail - Empty") {
    ZStack {
        Color.black
        CameraThumbnailButton(imageData: nil, isSealing: false, scale: 1.0, action: {})
    }
    .frame(width: 200, height: 200)
}

import SwiftUI

/// Minimalist, Apple Camera-style horizon level indicator.
/// Fades in when the phone is close to level and turns golden yellow with a haptic snap when 0°.
public struct HorizonLevelView: View {

    let angle: Double
    let isLevel: Bool
    let isVisible: Bool

    public init(angle: Double, isLevel: Bool, isVisible: Bool = true) {
        self.angle = angle
        self.isLevel = isLevel
        self.isVisible = isVisible
    }

    public var body: some View {
        Group {
            if isVisible && abs(angle) <= 12.0 {
                HStack(spacing: isLevel ? 0 : 28) {
                    // Left level line
                    Rectangle()
                        .fill(isLevel ? Color.yellow : Color.white.opacity(0.7))
                        .frame(width: isLevel ? 52 : 36, height: 1.5)
                        .shadow(color: isLevel ? Color.yellow.opacity(0.6) : Color.black.opacity(0.4), radius: isLevel ? 4 : 2)

                    if isLevel {
                        // Center connected dot
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 4, height: 4)
                            .shadow(color: Color.yellow.opacity(0.8), radius: 4)
                    }

                    // Right level line
                    Rectangle()
                        .fill(isLevel ? Color.yellow : Color.white.opacity(0.7))
                        .frame(width: isLevel ? 52 : 36, height: 1.5)
                        .shadow(color: isLevel ? Color.yellow.opacity(0.6) : Color.black.opacity(0.4), radius: isLevel ? 4 : 2)
                }
                .rotationEffect(.degrees(-angle))
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: angle)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isLevel)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}

#Preview("Horizon Level") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 40) {
            HorizonLevelView(angle: 5.0, isLevel: false, isVisible: true)
            HorizonLevelView(angle: 0.0, isLevel: true, isVisible: true)
        }
    }
}

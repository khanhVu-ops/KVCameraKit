import SwiftUI

/// Custom animated shutter button with high-end mechanical feel and recording pulse animation.
struct CameraShutterButton: View {
    let isPhotoMode: Bool
    let isRecording: Bool
    /// A frame is in the pipeline. The inner disc closes like an iris and reopens when
    /// the capture leaves the sensor, which is the only mechanical cue the button gives
    /// that the tap was taken — the press scale alone ends the moment the finger lifts.
    let isExposing: Bool
    let action: () -> Void

    @State private var isPulsing = false

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                // Outer Pulsing Wave for Video Recording
                if !isPhotoMode && isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.4), lineWidth: 6)
                        .frame(width: 86, height: 86)
                        .scaleEffect(isPulsing ? 1.15 : 0.98)
                        .opacity(isPulsing ? 0.0 : 0.8)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                        .onAppear { isPulsing = true }
                        .onDisappear { isPulsing = false }
                }

                // Outer Ring
                Circle()
                    .stroke(Color.white, lineWidth: 4.5)
                    .frame(width: 78, height: 78)
                    .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)

                if isPhotoMode {
                    // Photo mode: Solid white circle with inner ring gap
                    Circle()
                        .fill(Color.white)
                        .frame(width: 64, height: 64)
                        .shadow(color: Color.black.opacity(0.2), radius: 2)
                        .scaleEffect(isExposing ? 0.80 : 1.0)
                        .animation(.spring(response: 0.18, dampingFraction: 0.62), value: isExposing)
                } else {
                    // Video mode: Red circle (idle) or Red square (recording)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 64, height: 64)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isRecording)
            .animation(.easeInOut(duration: 0.22), value: isPhotoMode)
        }
        .buttonStyle(ShutterButtonStyle())
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Shutter Button - Photo") {
    ZStack {
        Color.black
        CameraShutterButton(isPhotoMode: true, isRecording: false, isExposing: false, action: {})
    }
    .frame(width: 200, height: 200)
}

#Preview("Shutter Button - Exposing") {
    ZStack {
        Color.black
        CameraShutterButton(isPhotoMode: true, isRecording: false, isExposing: true, action: {})
    }
    .frame(width: 200, height: 200)
}

#Preview("Shutter Button - Video Recording") {
    ZStack {
        Color.black
        CameraShutterButton(isPhotoMode: false, isRecording: true, isExposing: false, action: {})
    }
    .frame(width: 200, height: 200)
}

#if DEBUG
import SwiftUI

/// The frame tap's numbers, on screen, next to the viewfinder it runs beside.
///
/// Step 3 exists to answer "can we get frames, and what do they cost" *before* anything
/// depends on the answer — so the answer has to be readable on a real device, where it is the
/// only place it can be true. A tap that quietly runs at 22 fps, or drops a third of its
/// frames, looks exactly like one that does not until a number says otherwise.
///
/// It is also the tap's first consumer, and that is not incidental: `CameraFrameTap` attaches
/// to the session only when someone subscribes, so without a consumer there is nothing to
/// measure. Subscribing an empty closure is what puts the output on the session — which is
/// precisely the parallel run being measured.
///
/// `#if DEBUG`, and no words: everything here is a symbol plus a number, so it needs no
/// entry in nineteen `.strings` files to say something only a developer reads.
struct CameraFrameStatisticsHUD: View {

    let frames: any FrameSource

    /// Local `@State`, deliberately not on `CameraState`. The ViewModel exposes one observable
    /// property, so pushing a once-a-second statistics tick through it would invalidate every
    /// view reading `state` — a diagnostic that made the screen it measures slower.
    @State private var statistics = FrameStatistics()
    @State private var subscription: FrameSubscription?

    var body: some View {
        HStack(spacing: 10) {
            reading(symbol: "speedometer", value: statistics.framesPerSecond ?? 0, decimals: 1)
            reading(symbol: "drop", value: Double(statistics.dropped), decimals: 0)
            reading(symbol: "square.stack.3d.down.right", value: Double(statistics.delivered), decimals: 0)

            if let dimensions = statistics.dimensions {
                Text(Int(dimensions.width), format: .number.grouping(.never))
                Text(verbatim: "×")
                Text(Int(dimensions.height), format: .number.grouping(.never))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55), in: Capsule())
        .task {
            // Subscribing is what attaches the output. An empty consumer measures the cost of
            // delivery without adding the cost of doing anything with it, which is the number
            // step 5 needs as its baseline.
            subscription = frames.addConsumer { _ in }
            while !Task.isCancelled {
                statistics = frames.statistics
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            subscription?.cancel()
            subscription = nil
        }
    }

    private func reading(symbol: String, value: Double, decimals: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(value, format: .number.precision(.fractionLength(decimals)))
        }
    }
}

#Preview {
    /// A source with numbers already in it, because the interesting states of a diagnostic are
    /// the ones that mean trouble — and neither is reachable by waiting.
    final class PreviewFrameSource: FrameSource, @unchecked Sendable {
        var statistics = FrameStatistics(
            delivered: 1_284,
            dropped: 37,
            framesPerSecond: 29.8,
            pixelFormat: nil,
            dimensions: CGSize(width: 1920, height: 1080)
        )
        func addConsumer(_ consumer: @escaping FrameConsumer) -> FrameSubscription {
            FrameSubscription {}
        }
    }

    return CameraFrameStatisticsHUD(frames: PreviewFrameSource())
        .padding()
        .background(Color.gray)
}
#endif

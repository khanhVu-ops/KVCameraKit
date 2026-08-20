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
    /// What the screen asked for — `CameraState.currentZoom`, the number under the pill.
    let requestedZoom: CGFloat
    /// What the device is actually at, re-read on every tick. A closure rather than a value
    /// because the whole point is that it may not be following the request.
    let zoomReading: () -> CameraZoomReading?

    /// Local `@State`, deliberately not on `CameraState`. The ViewModel exposes one observable
    /// property, so pushing a once-a-second statistics tick through it would invalidate every
    /// view reading `state` — a diagnostic that made the screen it measures slower.
    @State private var statistics = FrameStatistics()
    @State private var zoom: CameraZoomReading?
    @State private var subscription: FrameSubscription?

    var body: some View {
        // Two rows rather than one long one. The readings are monospaced and unbounded — a
        // frame count reaches five digits in three minutes — and this capsule sits across the
        // top of the narrowest phone the app supports. The mode switcher already ran off the
        // edge of a small screen once, for exactly this reason.
        VStack(alignment: .leading, spacing: 2) {
            firstRow
            secondRow
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                zoom = zoomReading()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            subscription?.cancel()
            subscription = nil
        }
    }

    private var firstRow: some View {
        HStack(spacing: 10) {
            reading(symbol: "speedometer", value: statistics.framesPerSecond ?? 0, decimals: 1)
            reading(symbol: "drop", value: Double(statistics.dropped), decimals: 0)
            reading(symbol: "square.stack.3d.down.right", value: Double(statistics.delivered), decimals: 0)
        }
        .foregroundStyle(Color.green)
    }

    private var secondRow: some View {
        HStack(spacing: 10) {
            if let dimensions = statistics.dimensions {
                Text(Int(dimensions.width), format: .number.grouping(.never))
                Text(verbatim: "×")
                Text(Int(dimensions.height), format: .number.grouping(.never))
            }

            // Asked → got, in the pill's own units, with the raw `videoZoomFactor` after it.
            // Amber when the first two disagree by more than a rounding wobble.
            //
            // Three numbers because each pair rules out a different story. Asked ≠ got: the
            // request never reached the lens. Asked = got but the picture did not change: the
            // frames are not being cropped. Asked = got and the raw factor is not their
            // product: the ladder's base is wrong for this hardware, which is the one case
            // where both UI numbers agree and the lens is still in the wrong place.
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                Text(requestedZoom, format: .number.precision(.fractionLength(1)))
                Text(verbatim: "→")
                if let zoom {
                    Text(zoom.ui, format: .number.precision(.fractionLength(1)))
                    Text(verbatim: "·")
                    Text(zoom.device, format: .number.precision(.fractionLength(1)))
                } else {
                    Text(verbatim: "—")
                }
            }
            .foregroundStyle(isZoomFollowing ? Color.green : Color.orange)
        }
        .foregroundStyle(Color.green)
    }

    /// A simulator has no device to disagree with, so the absence of a reading is not a fault.
    private var isZoomFollowing: Bool {
        guard let zoom else { return true }
        return abs(zoom.ui - requestedZoom) < 0.05
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

    return VStack(spacing: 8) {
        // Following.
        CameraFrameStatisticsHUD(
            frames: PreviewFrameSource(),
            requestedZoom: 2.0,
            zoomReading: { CameraZoomReading(device: 4.0, ui: 2.0) }
        )
        // Not following — the state a screenshot has to be able to show.
        CameraFrameStatisticsHUD(
            frames: PreviewFrameSource(),
            requestedZoom: 2.0,
            zoomReading: { CameraZoomReading(device: 2.0, ui: 1.0) }
        )
        // No camera at all.
        CameraFrameStatisticsHUD(
            frames: PreviewFrameSource(),
            requestedZoom: 1.0,
            zoomReading: { nil }
        )
    }
    .padding()
    .background(Color.gray)
}
#endif

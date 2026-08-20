import SwiftUI

/// The live page outline, drawn over the viewfinder in scan mode.
///
/// It owns its detector, its frame subscription and its quad, and reports none of that to
/// the ViewModel. That is the load-bearing decision here, not an organisational one:
/// `CameraViewModel` exposes exactly one observable property, so a quad landing on
/// `CameraState` ten times a second would invalidate every view that reads `state` — the
/// zoom pill, the mode switcher, the shutter, all of it — at detection rate. An overlay
/// that made the screen behind it stutter would be a worse feature than no overlay.
///
/// Subscribing is also what attaches the `AVCaptureVideoDataOutput`, so leaving scan mode
/// tears this view down and the session stops paying for frames. That is why `CameraMode`
/// answers `needsFrames` rather than the call site checking `mode == .scan`.
struct DocumentScanOverlay: View {

    let frames: any FrameSource

    @State private var quad: DocumentQuad?
    @State private var subscription: FrameSubscription?

    /// One detector for the lifetime of the overlay, so its smoothing has history to smooth
    /// against. Rebuilt per frame it would have none, and the outline would jitter exactly
    /// as much as raw Vision output.
    @State private var detector = DocumentDetector()

    var body: some View {
        GeometryReader { geometry in
            // Values, not the quad and not a detector. Splitting here is what lets the two
            // states that matter — a found page, and the hint — be looked at in a canvas,
            // which is otherwise impossible for a view whose content comes from Vision
            // running on a camera the simulator does not have.
            DocumentScanOverlayContent(corners: quad?.inViewSpace(of: geometry.size))
        }
        .allowsHitTesting(false)
        .task {
            // Detection runs on the frame source's queue — never the main actor. The
            // detector skips frames while one request is in flight, so this adapts to
            // whatever the device can manage instead of guessing an interval.
            let detector = self.detector
            subscription = frames.addConsumer { frame in
                guard let pixelBuffer = frame.pixelBuffer else { return }
                let found = detector.detect(in: pixelBuffer, orientation: .up)
                Task { @MainActor in
                    quad = found
                }
            }
        }
        .onDisappear {
            subscription?.cancel()
            subscription = nil
            detector.reset()
        }
    }

}

/// What the overlay actually draws: an outline, or a hint that there is nothing to outline.
///
/// Takes values so it can be previewed and asserted without Vision, a camera or a frame
/// stream. `Equatable` so a re-detection that lands on the same corners costs nothing.
struct DocumentScanOverlayContent: View, Equatable {

    /// `nil` means nothing was found — which is also what "still looking" produces, and
    /// deliberately so: a UI that distinguished the two would flicker between two hints at
    /// whatever rate Vision happens to manage.
    let corners: [CGPoint]?

    var body: some View {
        ZStack {
            if let corners {
                Quad(points: corners)
                    .fill(Color.yellow.opacity(0.14))
                Quad(points: corners)
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                ForEach(corners.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.yellow)
                        .frame(width: 8, height: 8)
                        .position(corners[index])
                }
            } else {
                hint
            }
        }
        .animation(.easeOut(duration: 0.12), value: corners)
    }

    private var hint: some View {
        Text("Position the document in frame", bundle: .module)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45), in: Capsule())
    }
}

private struct Quad: Shape {
    var points: [CGPoint]

    /// Animating the corners rather than cross-fading two outlines. Without this the
    /// smoothing in `DocumentDetector` still leaves visible steps, because SwiftUI has no
    /// reason to interpolate an array of points on its own.
    var animatableData: AnimatablePair<
        AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>,
        AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>
    > {
        get {
            let padded = Self.padded(points)
            return AnimatablePair(
                AnimatablePair(padded[0].animatableData, padded[1].animatableData),
                AnimatablePair(padded[2].animatableData, padded[3].animatableData)
            )
        }
        set {
            points = [
                CGPoint(x: newValue.first.first.first, y: newValue.first.first.second),
                CGPoint(x: newValue.first.second.first, y: newValue.first.second.second),
                CGPoint(x: newValue.second.first.first, y: newValue.second.first.second),
                CGPoint(x: newValue.second.second.first, y: newValue.second.second.second)
            ]
        }
    }

    func path(in rect: CGRect) -> Path {
        let corners = Self.padded(points)
        var path = Path()
        path.move(to: corners[0])
        for corner in corners.dropFirst() {
            path.addLine(to: corner)
        }
        path.closeSubpath()
        return path
    }

    /// A quad always has four corners; anything else is a bug upstream, and drawing a
    /// partial path would hide it. Padding keeps `animatableData` total rather than
    /// crashing on an index.
    private static func padded(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 4 else {
            return points + Array(repeating: .zero, count: 4 - points.count)
        }
        return Array(points.prefix(4))
    }
}

#Preview("Detected") {
    ZStack {
        Color.black
        DocumentScanOverlayContent(corners: [
            CGPoint(x: 60, y: 140),
            CGPoint(x: 300, y: 110),
            CGPoint(x: 320, y: 520),
            CGPoint(x: 40, y: 480)
        ])
    }
    .ignoresSafeArea()
}

#Preview("Nothing found") {
    ZStack {
        Color.black
        DocumentScanOverlayContent(corners: nil)
    }
    .ignoresSafeArea()
}

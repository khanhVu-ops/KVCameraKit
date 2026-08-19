import SwiftUI

/// Every duration in the capture animation, in one place.
///
/// The old sequence hard-coded `0.48` and `0.65` into two `DispatchQueue.asyncAfter`
/// calls and hoped they matched two springs declared thirty lines apart. They did
/// not, which is why the thumbnail bounced after the photo had already vanished.
/// Anything that needs to know when the card lands reads it from here.
enum CaptureFlightTiming {
    /// The curtain drops this fast — it is the frame of feedback for the tap.
    static let curtainDown: Double = 0.055
    /// The curtain lifts behind the departing card.
    static let curtainLift: Double = 0.26

    /// A short squeeze before the card leaves, so it reads as "picked up".
    static let liftOff: Double = 0.06
    /// Horizontal travel decelerates; vertical travel accelerates. Two curves of
    /// different length over the same move are what bends the path into an arc —
    /// one interpolation would slide the card along a straight diagonal.
    static let horizontal: Double = 0.52
    static let vertical: Double = 0.44
    static let scale: Double = 0.50

    /// The card cross-fades into the real thumbnail instead of fading to nothing
    /// mid-flight, which is what it used to do.
    static let crossFadeStart: Double = 0.46
    static let crossFade: Double = 0.08

    /// When the thumbnail should bounce: the card is effectively stopped by now.
    /// Teardown does not need a number — it hangs off the horizontal animation's own
    /// completion handler.
    static let touchdown: Double = liftOff + horizontal * 0.86

    /// Reduce Motion gets a plain cross-fade in place of the whole thing.
    static let reducedFade: Double = 0.20
}

/// The captured frame travelling from the viewfinder to the vault thumbnail.
///
/// It starts as the viewfinder — full preview aspect ratio — and lands as the square
/// thumbnail, which means the aspect ratio has to change on the way. That is done by
/// animating a **crop** around a fixed-size image, never the image's own frame: the
/// picture is laid out once at preview size and a shrinking window reveals less of it,
/// so nothing re-samples mid-flight. Driving `width`/`height` on the image directly —
/// the first version of this — re-laid out and re-scaled every frame and let
/// `scaledToFill` pick a different crop at each size, which is why the photo visibly
/// warped on the way down.
///
/// The destination is measured, not guessed: `targetRect` comes from the real thumbnail
/// through an anchor preference, so it lands on the thumbnail on an SE and on a Pro Max
/// rather than 50 pt from the corner on both.
struct CameraCaptureFlightView: View {
    let flight: CaptureFlight
    let canvasSize: CGSize
    let targetRect: CGRect
    let targetCornerRadius: CGFloat
    let reduceMotion: Bool
    let onCompleted: () -> Void

    @State private var image: UIImage?
    @State private var travelX: CGFloat = 0
    @State private var travelY: CGFloat = 0
    @State private var shrink: CGFloat = 0
    @State private var squeeze: CGFloat = 1.0
    @State private var cardOpacity: Double = 1.0

    /// The window onto the photo. Full preview height at rest, a square by the time it
    /// lands — the crop is what turns the viewfinder rectangle into a thumbnail without
    /// the image itself ever being re-laid out.
    private var cropHeight: CGFloat {
        canvasSize.height + (canvasSize.width - canvasSize.height) * shrink
    }

    private var endScale: CGFloat {
        guard canvasSize.width > 0 else { return 1 }
        return targetRect.width / canvasSize.width
    }

    private var scale: CGFloat {
        squeeze * (1 + (endScale - 1) * shrink)
    }

    /// The radius is specified in unscaled space, so the end value is divided by the
    /// end scale — 14 pt asked for at full size would arrive as 2 pt once shrunk.
    private var cornerRadius: CGFloat {
        let start: CGFloat = 14
        let end = endScale > 0 ? targetCornerRadius / endScale : start
        return start + (end - start) * shrink
    }

    private var offsetX: CGFloat { (targetRect.midX - canvasSize.width / 2) * travelX }
    private var offsetY: CGFloat { (targetRect.midY - canvasSize.height / 2) * travelY }

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // Fixed: the photo is sized and cropped to the viewfinder once.
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipped()
                    // Animated: a centred window that closes to a square.
                    .frame(width: canvasSize.width, height: cropHeight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.55 * shrink), lineWidth: 1.5 / max(scale, 0.01))
                    )
                    .compositingGroup()
                    .shadow(color: Color.black.opacity(0.45), radius: 26 * (1 - shrink) + 4, x: 0, y: 8 * (1 - shrink) + 2)
                    .scaleEffect(scale)
                    .offset(x: offsetX, y: offsetY)
                    .opacity(cardOpacity)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
        .onAppear(perform: start)
    }

    private func start() {
        // Decoded eagerly. A lazily decoded `UIImage` decodes on its first render,
        // which would land inside the flight instead of behind the curtain.
        image = UIImage(data: flight.imageData).flatMap { $0.preparingForDisplay() ?? $0 }

        guard !reduceMotion else {
            withAnimation(.easeOut(duration: CaptureFlightTiming.reducedFade)) {
                shrink = 1
                travelX = 1
                travelY = 1
                cardOpacity = 0
            } completion: {
                onCompleted()
            }
            return
        }

        withAnimation(.spring(response: 0.16, dampingFraction: 0.82)) {
            squeeze = 0.955
        }
        withAnimation(.easeOut(duration: 0.30).delay(0.12)) {
            squeeze = 1.0
        }
        // The completion runs when this animation actually ends, so nothing has to
        // re-derive the timeline with a sleep and hope the two agree. Horizontal is the
        // longest leg, which makes it the one that owns teardown.
        withAnimation(
            .timingCurve(0.16, 0.84, 0.44, 1.0, duration: CaptureFlightTiming.horizontal)
                .delay(CaptureFlightTiming.liftOff)
        ) {
            travelX = 1
        } completion: {
            onCompleted()
        }
        withAnimation(
            .timingCurve(0.50, 0.02, 0.72, 0.34, duration: CaptureFlightTiming.vertical)
                .delay(CaptureFlightTiming.liftOff)
        ) {
            travelY = 1
        }
        withAnimation(
            .timingCurve(0.32, 0.0, 0.24, 1.0, duration: CaptureFlightTiming.scale)
                .delay(CaptureFlightTiming.liftOff)
        ) {
            shrink = 1
        }
        withAnimation(
            .linear(duration: CaptureFlightTiming.crossFade)
                .delay(CaptureFlightTiming.crossFadeStart)
        ) {
            cardOpacity = 0
        }
    }
}

/// Where the flight is going.
///
/// The thumbnail publishes its own bounds and the flight reads them back, so the
/// two cannot drift apart when the bottom bar is re-laid out.
struct CaptureTargetAnchorKey: PreferenceKey {
    // Computed, not stored: a stored mutable static is global mutable state and
    // Swift 6 strict concurrency rejects it.
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// A flat colour frame, so the preview animates something visible without a device.
private func previewFlightImageData() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600))
    let image = renderer.image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        UIColor.white.withAlphaComponent(0.35).setFill()
        context.fill(CGRect(x: 120, y: 220, width: 360, height: 160))
    }
    return image.jpegData(compressionQuality: 0.9) ?? Data()
}

#Preview("Capture Flight") {
    GeometryReader { geo in
        ZStack {
            Color.black
            CameraCaptureFlightView(
                flight: CaptureFlight(id: UUID(), imageData: previewFlightImageData()),
                canvasSize: geo.size,
                targetRect: CGRect(x: 34, y: geo.size.height - 90, width: 52, height: 52),
                targetCornerRadius: 14,
                reduceMotion: false,
                onCompleted: {}
            )
        }
    }
}

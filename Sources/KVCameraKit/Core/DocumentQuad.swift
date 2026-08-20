import CoreGraphics
import Foundation

/// The four corners of a detected document, in Vision's normalised space.
///
/// Normalised means 0…1 on both axes, and **origin bottom-left** — which is the single
/// most common source of bugs in this kind of code, because every other coordinate space
/// this package touches (a `CALayer`, a `CGContext`, a `UIImage`) has its origin at the
/// top-left. A quad that renders upside down, or a crop that takes the wrong half of the
/// page, is nearly always this. So the flip lives in exactly one place — `inViewSpace(of:)`
/// — and never at a call site.
///
/// Normalised rather than pixels for a second reason: the quad is detected on one image and
/// applied to another. The live overlay is drawn over a view of some size, while the crop
/// runs on a full-resolution still, and neither knows the other's dimensions.
struct DocumentQuad: Equatable, Sendable {
    /// Vision space: origin bottom-left, 0…1.
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint

    /// The corners as a path, in a top-left-origin space of the given size.
    ///
    /// `1 - y` is the whole flip. Everything drawing this quad goes through here.
    func inViewSpace(of size: CGSize) -> [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft].map { point in
            CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
        }
    }

    /// The corners scaled to an image's pixel extent, still bottom-left origin — which is
    /// what Core Image wants, and why this is a separate function from `inViewSpace`.
    func inImageSpace(of size: CGSize) -> (
        topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint
    ) {
        func scale(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * size.width, y: point.y * size.height)
        }
        return (scale(topLeft), scale(topRight), scale(bottomLeft), scale(bottomRight))
    }

    /// Share of the frame the quad covers, by the shoelace formula.
    ///
    /// Used to throw away detections that are technically valid and useless: Vision will
    /// happily report a business card at the far end of a table, and cropping to 3% of the
    /// frame produces an unreadable smear rather than a scan.
    var areaFraction: CGFloat {
        let corners = [topLeft, topRight, bottomRight, bottomLeft]
        var sum: CGFloat = 0
        for index in corners.indices {
            let current = corners[index]
            let next = corners[(index + 1) % corners.count]
            sum += current.x * next.y - next.x * current.y
        }
        return abs(sum) / 2
    }

    /// Whether the quad hugs all four edges of the frame.
    ///
    /// Which is the detector saying it found no page, not that the page is enormous.
    /// Measured: pointed at a featureless surface, `VNDetectDocumentSegmentationRequest`
    /// returns the whole frame inset by well under one percent on every side. Taken at face
    /// value that means the hint never appears, the outline is permanently snapped to the
    /// screen edges, and a "scan" is an uncropped photo with the contrast nudged.
    ///
    /// A real page cannot do this. Filling the frame edge-to-edge on all four sides at once
    /// means its borders are outside the frame, so there is nothing to crop to.
    func hugsFrame(tolerance: CGFloat = 0.02) -> Bool {
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x]
        let ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return false }
        return minX <= tolerance && minY <= tolerance
            && maxX >= 1 - tolerance && maxY >= 1 - tolerance
    }

    /// Whether this is worth showing the user or cropping to.
    ///
    /// Three checks, each for something measured rather than imagined.
    ///
    /// A **minimum** area, because Vision will happily report a business card at the far end
    /// of a table, and cropping to 3% of the frame produces a smear.
    ///
    /// Not **hugging the frame** — see `hugsFrame`, which is the detector's way of saying it
    /// found nothing.
    ///
    /// And that the corners have not **crossed over**: a self-intersecting quad still has a
    /// plausible area, and `CIPerspectiveCorrection` given one produces a folded, unreadable
    /// image rather than failing.
    func isUsable(minimumArea: CGFloat = 0.10, frameHugTolerance: CGFloat = 0.02) -> Bool {
        guard areaFraction >= minimumArea else { return false }
        guard !hugsFrame(tolerance: frameHugTolerance) else { return false }
        // Top edge above bottom edge, left edge left of right edge. In Vision space "above"
        // means a larger y.
        guard topLeft.y > bottomLeft.y, topRight.y > bottomRight.y else { return false }
        guard topLeft.x < topRight.x, bottomLeft.x < bottomRight.x else { return false }
        return true
    }

    /// Blends towards `other`, for smoothing a jittering live detection.
    ///
    /// Vision re-detects every frame from scratch, so a perfectly still document still
    /// produces corners that move a pixel or two each time. Drawn raw, the overlay shivers.
    /// `factor` is how far to move towards the new reading: 1 is no smoothing.
    func interpolated(towards other: DocumentQuad, factor: CGFloat) -> DocumentQuad {
        func blend(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            CGPoint(
                x: from.x + (to.x - from.x) * factor,
                y: from.y + (to.y - from.y) * factor
            )
        }
        return DocumentQuad(
            topLeft: blend(topLeft, other.topLeft),
            topRight: blend(topRight, other.topRight),
            bottomLeft: blend(bottomLeft, other.bottomLeft),
            bottomRight: blend(bottomRight, other.bottomRight)
        )
    }

    /// How far the furthest corner has moved, as a fraction of the frame.
    ///
    /// The stability signal: a document the user has stopped moving reads near zero, which
    /// is what tells the UI it is worth saying "ready" rather than flickering a hint.
    func maximumCornerShift(from other: DocumentQuad) -> CGFloat {
        let pairs = [
            (topLeft, other.topLeft), (topRight, other.topRight),
            (bottomLeft, other.bottomLeft), (bottomRight, other.bottomRight)
        ]
        return pairs.map { hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) }.max() ?? 0
    }
}

import CoreImage
import CoreVideo
import Foundation
import Vision

/// Finds the page in a frame.
///
/// `VNDetectDocumentSegmentationRequest` rather than `VNDetectRectanglesRequest`: the
/// rectangle detector finds rectangles, of which a table edge, a laptop and a window frame
/// are all excellent examples. The document request is trained on pages and returns one
/// observation, which is the difference between a scanner and a rectangle-hunting toy.
///
/// Not `VNDocumentCameraViewController`. That is Apple's whole scanner UI in a modal view
/// controller — it cannot be themed, cannot share this screen's zoom and torch, and would
/// mean the camera has two completely different appearances depending on the mode.
final class DocumentDetector: @unchecked Sendable {

    /// One request object, reused. Vision requests are not cheap to build, and rebuilding
    /// one per frame at 30 Hz shows up as sawtooth memory before it shows up as latency.
    private let request = VNDetectDocumentSegmentationRequest()

    private let lock = NSLock()
    /// Whether a request is in flight.
    ///
    /// This *is* the throttle, and it is better than a fixed frame interval: on a fast
    /// device it runs often, on a slow one it runs as often as it can, and neither needs a
    /// number tuned per device. Frames arriving while busy are skipped, which is exactly
    /// right for a detector — the newest frame is the only one anybody wants.
    private var isBusy = false

    /// The last accepted quad, for smoothing and for the stability signal.
    private var lastQuad: DocumentQuad?

    /// How far to move towards each new reading. Vision re-detects from scratch every frame,
    /// so a stationary page still jitters by a pixel or two; drawn raw the overlay shivers.
    private let smoothing: CGFloat

    /// Below this, the observation is discarded.
    ///
    /// Vision reports one and it is worth using: on a featureless surface it returns a
    /// full-frame rectangle with a confidence of **exactly 0.0**, so the floor throws that
    /// away without any geometry heuristic having to guess.
    ///
    /// It is not a complete filter, and that is worth knowing rather than pretending: fed a
    /// flat white or flat black frame the same request returns a meaningless band across the
    /// bottom quarter with a confidence of 0.83–0.97. There is no threshold that separates
    /// that from a real page, because the request is trained on photographs and a uniform
    /// frame is not one. The geometry checks in `DocumentQuad.isUsable()` are what stand
    /// behind it.
    private let minimumConfidence: Float

    init(smoothing: CGFloat = 0.35, minimumConfidence: Float = 0.5) {
        self.smoothing = smoothing
        self.minimumConfidence = minimumConfidence
        request.revision = VNDetectDocumentSegmentationRequestRevision1
    }

    /// Runs detection unless one is already running.
    ///
    /// Returns `nil` both when busy and when nothing was found, and the caller cannot tell
    /// the difference — deliberately. A UI that distinguished "no page" from "still
    /// thinking" would flicker between two hints at whatever rate Vision happens to manage.
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> DocumentQuad? {
        lock.lock()
        if isBusy {
            lock.unlock()
            return nil
        }
        isBusy = true
        let previous = lastQuad
        lock.unlock()

        defer {
            lock.lock()
            isBusy = false
            lock.unlock()
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first as? VNRectangleObservation,
              observation.confidence >= minimumConfidence else {
            lock.lock()
            lastQuad = nil
            lock.unlock()
            return nil
        }

        let detected = DocumentQuad(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomLeft: observation.bottomLeft,
            bottomRight: observation.bottomRight
        )
        guard detected.isUsable() else {
            lock.lock()
            lastQuad = nil
            lock.unlock()
            return nil
        }

        let smoothed = previous?.interpolated(towards: detected, factor: smoothing) ?? detected
        lock.lock()
        lastQuad = smoothed
        lock.unlock()
        return smoothed
    }

    /// Detection on a still, for the capture itself.
    ///
    /// Run again on the full-resolution frame rather than reusing the live quad, and that is
    /// a correctness point rather than an accuracy one: the preview stream and the photo
    /// output can have different aspect ratios and fields of view, so a normalised quad from
    /// one does **not** describe the same region of the other. It would look almost right,
    /// which is the worst kind of wrong — a scan cropped a few percent off, every time.
    func detect(in image: CIImage) -> DocumentQuad? {
        let handler = VNImageRequestHandler(ciImage: image)
        let request = VNDetectDocumentSegmentationRequest()
        request.revision = VNDetectDocumentSegmentationRequestRevision1
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNRectangleObservation,
              observation.confidence >= minimumConfidence else { return nil }
        let quad = DocumentQuad(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomLeft: observation.bottomLeft,
            bottomRight: observation.bottomRight
        )
        return quad.isUsable() ? quad : nil
    }

    func reset() {
        lock.lock()
        lastQuad = nil
        lock.unlock()
    }
}

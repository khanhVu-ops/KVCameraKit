import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Turns a stream of frames into a stable set of `CensorRegion`s.
///
/// Detection alone is not enough for this feature and the reason is a property of the feature
/// rather than of the detector: a censor that is *usually* on the face is not a weaker version
/// of one that always is, it is a broken one. A single frame where the region is missing or
/// misplaced is a frame with an uncensored face in it, and if that frame goes into a recording
/// it is there permanently. So three things happen here that raw detection does not do:
///
/// **Identity.** Vision returns observations in an order that changes between frames. Keyed by
/// array index — which the first implementation did, via `ForEach(id: \.offset)` — two faces
/// swap identities as soon as the order changes, and with any smoothing at all one censor then
/// travels across the frame through everything in between. Regions are matched to tracks by
/// position and carry an id that outlives the observation.
///
/// **Coasting.** Detection misses. A blink, motion blur, a turn to profile, a hand across the
/// chin — any of them return nothing for a frame or two, and the censor blinking off is exactly
/// the failure above. A lost track is held for `coastDuration` and *grows* while it coasts,
/// because the reason it was lost is usually that the head moved.
///
/// **Smoothing, asymmetrically.** Size and roll are smoothed hard: they jitter frame to frame
/// on a stationary face, and a censor that breathes reads as broken. Position is smoothed
/// barely, and not at all past a threshold — lag on position is the one error that uncovers a
/// face, so a fast movement snaps rather than eases. The first implementation had a
/// `.spring(response: 0.25)` on the box, which is a quarter second of the face being visible
/// every time the subject moved.
///
/// Runs detection on its own queue. The frame tap's queue is serial and shared with whoever
/// draws the viewfinder, so a 10 ms Vision request on it is 10 ms the preview does not get.
final class CensorTracker: @unchecked Sendable {

    /// How long a lost track is kept, in seconds of stream time.
    ///
    /// Long enough to cover a blink and a turn of the head, short enough that a face that has
    /// genuinely left the frame stops being censored before the empty space is noticeable.
    private static let coastDuration: TimeInterval = 0.70
    /// How much a coasting region grows, at the end of the coast. It grows because a track is
    /// usually lost *because* the subject moved, so the last known position is the least
    /// trustworthy thing about it.
    private static let coastGrowth: CGFloat = 1.38
    /// The shader carries a fixed-size uniform array; this is its length. Beyond this the
    /// largest faces win, which is also the order in which they are recognisable.
    static let maximumRegions = 8

    /// Smoothing weight for a new observation. Position is fast, size and roll are slow.
    private static let centerWeight: CGFloat = 0.82
    private static let radiusWeight: CGFloat = 0.22
    private static let rollWeight: CGFloat = 0.18
    /// Past this distance — as a multiple of the region's own radius — a new observation is
    /// taken whole instead of blended. Smoothing a fast movement is indistinguishable from
    /// lagging behind it.
    private static let snapDistance: CGFloat = 0.62

    private let request: VNDetectFaceRectanglesRequest
    private let detectQueue = DispatchQueue(
        label: "com.iosvault.camera.censorQueue",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var tracks: [Track] = []
    private var published: [CensorRegion] = []
    private var nextID = 1
    /// At most one detection in flight. This is what bounds the buffer the closure below
    /// retains to exactly one — the same deliberate, bounded exception to `CameraFrame`'s
    /// "valid only for the callback" rule that `CameraPreviewRenderer` makes, and for the same
    /// reason: one held buffer is what AVFoundation's pool is sized for, and a queue of them
    /// empties it and stops delivery with nothing logged.
    private var isDetecting = false

    private struct Track {
        var region: CensorRegion
        var lastSeen: TimeInterval
    }

    /// Whether anything should run at all. Set from the service when the user picks a mode.
    var isEnabled = false {
        didSet {
            guard !isEnabled else { return }
            lock.lock()
            tracks = []
            published = []
            lock.unlock()
        }
    }

    init() {
        request = VNDetectFaceRectanglesRequest()
        // Revision 3 is the one that reports `roll` and that tolerates a face turned towards
        // profile. Pinned rather than left to default, because the default moves with the OS
        // and this code reads a property earlier revisions do not fill in.
        request.revision = VNDetectFaceRectanglesRequestRevision3
    }

    /// The current regions, in sensor-buffer space. Cheap: a copy of a small array.
    ///
    /// Read from the Metal draw at 60 Hz and from the writer queue per frame, written on the
    /// detect queue — hence the lock rather than any queue in particular.
    var regions: [CensorRegion] {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    // MARK: - Intake

    /// Called on the frame source's queue. Returns immediately.
    func accept(_ frame: CameraFrame) {
        guard isEnabled,
              let pixelBuffer = frame.pixelBuffer,
              let size = frame.dimensions else { return }

        lock.lock()
        if isDetecting {
            lock.unlock()
            return
        }
        isDetecting = true
        lock.unlock()

        // The rotation comes off the frame, so detection and the pixels it describes can never
        // disagree about which way up the scene was — the two are read from the same object.
        let rotation = frame.rotationAngle ?? 0
        let timestamp = frame.presentationTime.seconds

        detectQueue.async { [weak self] in
            guard let self else { return }
            self.detect(
                in: pixelBuffer,
                sensorSize: size,
                rotationDegrees: rotation,
                timestamp: timestamp.isFinite ? timestamp : 0
            )
            self.lock.lock()
            self.isDetecting = false
            self.lock.unlock()
        }
    }

    // MARK: - Detection

    /// Detect queue only.
    private func detect(
        in pixelBuffer: CVPixelBuffer,
        sensorSize: CGSize,
        rotationDegrees: CGFloat,
        timestamp: TimeInterval
    ) {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: CensorGeometry.visionOrientation(rotationDegrees: rotationDegrees),
            options: [:]
        )

        // A thrown request is a miss, not an emptying: falling through to `merge` with no
        // observations lets the existing tracks coast, which is what a one-frame failure
        // should look like. Clearing them here is the blink-off bug.
        try? handler.perform([request])
        let observations = (request.results ?? [])

        let detected = observations.map { observation in
            CensorGeometry.region(
                visionBox: observation.boundingBox,
                visionRoll: CGFloat(truncating: observation.roll ?? 0),
                // Replaced by the track's own id in `merge`; only the geometry is used here.
                id: 0,
                sensorSize: sensorSize,
                rotationDegrees: rotationDegrees
            )
        }

        merge(detected, at: timestamp)
    }

    // MARK: - Tracking

    /// Detect queue only, except for the lock.
    private func merge(_ detected: [CensorRegion], at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        // Checked again here, not only on entry. A detection is in flight for a few frames, so
        // the user can switch the censor off while one is running — and this is the line that
        // would otherwise repopulate the regions the setter had just cleared, leaving stale
        // geometry published for a mode that is no longer on.
        guard isEnabled else {
            tracks = []
            published = []
            return
        }

        var surviving: [Track] = []
        var unmatched = tracks

        for var observation in detected {
            // Greedy nearest neighbour. With at most a handful of faces on screen the optimal
            // assignment and the greedy one agree, and the greedy one cannot get stuck.
            let match = unmatched.enumerated().min { left, right in
                distance(left.element.region, observation) < distance(right.element.region, observation)
            }

            if let match, distance(match.element.region, observation) < Self.snapDistance {
                observation.id = match.element.region.id
                observation = smoothed(observation, towards: match.element.region)
                unmatched.remove(at: match.offset)
            } else {
                observation.id = nextID
                nextID += 1
            }
            surviving.append(Track(region: observation, lastSeen: timestamp))
        }

        // Whatever was not matched coasts, growing as it goes, until its grace period runs out.
        for track in unmatched {
            let age = timestamp - track.lastSeen
            guard age >= 0, age < Self.coastDuration else { continue }
            let progress = CGFloat(age / Self.coastDuration)
            let growth = 1 + (Self.coastGrowth - 1) * progress
            var coasted = track
            coasted.region.radius = CGSize(
                width: track.region.radius.width * growth,
                height: track.region.radius.height * growth
            )
            surviving.append(coasted)
        }

        // The shader's array is fixed-length, so when there are more faces than slots the
        // biggest go in. Truncating silently in the other order would drop the face closest to
        // the camera, which is the one that matters.
        tracks = surviving
            .sorted { area($0.region) > area($1.region) }
            .prefix(Self.maximumRegions)
            .map { $0 }
        published = tracks.map(\.region)
    }

    /// Distance between two regions, as a multiple of the larger one's radius.
    ///
    /// Relative rather than absolute, so the same threshold works for a face filling the frame
    /// and one across a room. An absolute threshold either loses the near face on a small
    /// movement or merges two distant ones.
    private func distance(_ a: CensorRegion, _ b: CensorRegion) -> CGFloat {
        let dx = a.center.x - b.center.x
        let dy = a.center.y - b.center.y
        let scale = max(a.radius.width, b.radius.width, 0.001)
        return (dx * dx + dy * dy).squareRoot() / scale
    }

    private func area(_ region: CensorRegion) -> CGFloat {
        region.radius.width * region.radius.height
    }

    /// A new observation blended onto the track it matched.
    private func smoothed(_ new: CensorRegion, towards old: CensorRegion) -> CensorRegion {
        let travelled = distance(old, new)
        // Past the threshold the observation is taken whole. Blending here is what produces a
        // censor that trails a turning head by its own width.
        let centerWeight = travelled > Self.snapDistance * 0.5 ? 1 : Self.centerWeight

        func blend(_ from: CGFloat, _ to: CGFloat, _ weight: CGFloat) -> CGFloat {
            from + (to - from) * weight
        }

        // Roll wraps, and a quarter turn of the device changes it by exactly pi/2 in one
        // frame. Easing across that gap draws a face tilting through 90 degrees it never
        // tilted through, so a large jump snaps like position does.
        let rollWeight = abs(new.roll - old.roll) > .pi / 4 ? 1 : Self.rollWeight

        return CensorRegion(
            id: new.id,
            center: CGPoint(
                x: blend(old.center.x, new.center.x, centerWeight),
                y: blend(old.center.y, new.center.y, centerWeight)
            ),
            radius: CGSize(
                // Growing is immediate, shrinking is smoothed. Asymmetric on purpose: an
                // under-sized censor uncovers a face and an over-sized one does not, so the
                // error is only ever paid in the safe direction.
                width: max(new.radius.width, blend(old.radius.width, new.radius.width, Self.radiusWeight)),
                height: max(new.radius.height, blend(old.radius.height, new.radius.height, Self.radiusWeight))
            ),
            roll: blend(old.roll, new.roll, rollWeight)
        )
    }
}

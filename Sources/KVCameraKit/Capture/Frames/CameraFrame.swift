import AVFoundation
import CoreMedia
import CoreVideo

/// One frame off the sensor, **valid only for the duration of the callback**.
///
/// That sentence is the entire contract and it is not a style note.
/// `AVCaptureVideoDataOutput` hands back buffers from a pool of fixed size. A consumer that
/// retains one keeps it out of the pool, and when the pool empties AVFoundation simply stops
/// delivering frames — no error, no callback, no log. The viewfinder freezes and everything
/// looks like a hang somewhere else entirely. Copy what you need (`CVPixelBufferCreate`, a
/// texture, a `CIImage` you render immediately) and let the frame go.
///
/// `@unchecked Sendable` because `CMSampleBuffer` carries no Swift concurrency annotation
/// that expresses "safe to hand to one queue, unsafe to keep". The compiler cannot enforce
/// the contract above, so it is written down instead.
struct CameraFrame: @unchecked Sendable {

    /// The buffer as AVFoundation delivered it. Kept whole rather than unpacked, because the
    /// recorder in a later step appends sample buffers directly and re-wrapping a pixel
    /// buffer means re-deriving timing that is already correct here.
    let sampleBuffer: CMSampleBuffer

    /// The rotation that makes this frame horizon-level, from the same
    /// `RotationCoordinator` that drives the preview layer. `nil` when the connection had
    /// no angle to report.
    let rotationAngle: CGFloat?

    var pixelBuffer: CVPixelBuffer? {
        CMSampleBufferGetImageBuffer(sampleBuffer)
    }

    var presentationTime: CMTime {
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }

    /// The native pixel format the camera chose.
    ///
    /// Reported rather than forced. Asking `AVCaptureVideoDataOutput` for BGRA is a
    /// per-frame conversion, and which format is actually cheapest depends on what the
    /// consumer does next — Metal can sample bi-planar YCbCr directly. Step 3 measures what
    /// the hardware gives; whoever renders it decides whether to pay for a change.
    var pixelFormat: OSType? {
        pixelBuffer.map(CVPixelBufferGetPixelFormatType)
    }

    var dimensions: CGSize? {
        pixelBuffer.map {
            CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
        }
    }
}

/// Called once per frame, on the frame source's own queue — never the main actor and never
/// the session queue. Do not block: the next frame is already on its way.
typealias FrameConsumer = @Sendable (CameraFrame) -> Void

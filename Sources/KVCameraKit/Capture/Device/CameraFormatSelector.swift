import AVFoundation
import CoreMedia
import Foundation

/// Chooses the `activeFormat` a device runs in, for the Metal viewfinder only.
///
/// The reason this exists is the single loudest complaint about the Metal preview: it looked
/// softer than the stock camera, and it was.
///
/// `AVCaptureVideoPreviewLayer` does not render the video data output — it gets its own stream
/// from the capture pipeline at whatever resolution the display needs. The Metal path has no such
/// privilege: it draws the frames `AVCaptureVideoDataOutput` delivers, and under
/// `sessionPreset = .photo` those are *preview-sized*, around 1440x1080. Aspect-filled onto a
/// modern iPhone screen that is a 1.8x bilinear upscale of a 1080-line image, which is exactly as
/// blurry as it sounds. The pixels were never there.
///
/// So the preset is dropped and the format is chosen, which is the only way to say "a sharper
/// video stream *and* full-resolution stills" — a preset picks one pair of numbers for both.
///
/// It is deliberately **not** applied to the system-preview path. There the current arrangement is
/// already correct, and a format chosen here could only take something away from it.
enum CameraFormatSelector {

    /// The most video pixels the viewfinder will ask a device for.
    ///
    /// A budget, not a maximum. Every one of those pixels is shaded by the look pass and scanned
    /// by the face detector thirty times a second, so asking for the sensor's full 12 MP would buy
    /// sharpness nobody can see on a 6-inch screen and spend it on a thermal limit. 1920x1440 is
    /// ~2.8 MP: on a 1179-point-wide display, aspect-filled, that is a *downscale* rather than an
    /// upscale for the first time, which is the whole point.
    static let videoPixelBudget = 1_920 * 1_440

    /// Frames per second the format has to be able to deliver. Below this a viewfinder judders,
    /// and some very high-resolution formats only offer 24.
    static let minimumFrameRate: Double = 30

    /// The format to run in, or `nil` to leave the device alone.
    ///
    /// `nil` is a real answer and not a failure: a device with one format, or one whose formats
    /// are all worse than what the preset would have picked, is better left as it is.
    static func format(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            guard format.mediaType == .video else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= minimumFrameRate })
            else { return false }
            // Depth, ProRes-log and the very high frame-rate formats all exist on modern devices
            // and none of them is a viewfinder format. Filtering on what is *needed* — plain
            // video, at ordinary rates, in a format the frame tap can read — rather than
            // blocklisting the exotic ones, which grow with every OS.
            guard isReadable(format) else { return false }
            return pixels(format.formatDescription) <= videoPixelBudget
        }

        guard !candidates.isEmpty else { return nil }

        return candidates.max { left, right in
            score(left, on: device) < score(right, on: device)
        }
    }

    /// How good a format is for this job, most significant first.
    ///
    /// Ordered as a tuple rather than summed into one number, because these are priorities and not
    /// weights: a format that shoots better photographs wins even if its video stream is smaller,
    /// and no amount of video resolution should be able to outvote it. Summing weights is how a
    /// selector ends up preferring a 4K binned format over a 12 MP still.
    private static func score(
        _ format: AVCaptureDevice.Format,
        on device: AVCaptureDevice
    ) -> (Int, Int, Int, Int) {
        (
            // 1 — stills first. This is a camera in a vault, and a sharper viewfinder that costs
            // photo resolution is a bad trade in a way the user only discovers later.
            photoPixels(format),
            // 2 — not binned. A binned format sums adjacent photosites: less noise, visibly less
            // detail, and it is the thing that makes a preview look like a video call.
            format.isVideoBinned ? 0 : 1,
            // 3 — 4:3, matching the photo the shutter will produce. A 16:9 video stream framed for
            // a 4:3 still shows the user less of the picture than they are about to take.
            isFourByThree(format) ? 1 : 0,
            // 4 — then, and only then, video resolution.
            pixels(format.formatDescription)
        )
    }

    /// Whether the frame tap can read this format's buffers.
    ///
    /// `CameraFrameTap` sets no `videoSettings`, so it receives the format's native pixel format —
    /// and the shader handles exactly three: BGRA, and bi-planar YCbCr in full or video range.
    /// A 10-bit or log format would arrive and render as nothing, which is a black viewfinder
    /// rather than an error.
    static func isReadable(_ format: AVCaptureDevice.Format) -> Bool {
        switch CMFormatDescriptionGetMediaSubType(format.formatDescription) {
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return true
        default:
            return false
        }
    }

    /// The largest still this format can produce, in pixels.
    ///
    /// From `supportedMaxPhotoDimensions`, which is what replaced `highResolutionStillImageDimensions`
    /// and is the only property that knows about the 24 and 48 MP modes on recent sensors.
    static func photoPixels(_ format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions
            .map { Int($0.width) * Int($0.height) }
            .max() ?? pixels(format.formatDescription)
    }

    /// The largest still dimensions to ask a photo output for, given the active format.
    ///
    /// Set explicitly because the default is not the maximum: `AVCapturePhotoOutput` starts at the
    /// active format's *video* dimensions, so a 48 MP sensor left alone produces photographs the
    /// size of the preview stream. That is a quiet way to lose most of a camera.
    static func maxPhotoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { left, right in
            Int(left.width) * Int(left.height) < Int(right.width) * Int(right.height)
        }
    }

    private static func isFourByThree(_ format: AVCaptureDevice.Format) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard dimensions.height > 0 else { return false }
        let ratio = Double(dimensions.width) / Double(dimensions.height)
        return abs(ratio - 4.0 / 3.0) < 0.02
    }

    private static func pixels(_ description: CMFormatDescription) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return Int(dimensions.width) * Int(dimensions.height)
    }
}

import AVFoundation
import CoreGraphics

/// The zoom numbers the user sees, derived from what the hardware actually has.
///
/// Every function here is pure and static, which is the point of the type existing: the
/// mapping between "the number on the pill" and `videoZoomFactor` is where this screen has
/// had most of its real bugs, and none of them needed a camera to reproduce — they needed
/// an iPhone 16's lens layout, an iPhone SE's, and a dual wide + tele, which is three
/// devices nobody has on a desk. As arithmetic over a couple of numbers it is three
/// assertions instead.
enum CameraZoomLadder {

    /// The device factor that the user calls "1x".
    ///
    /// The old code assumed `virtualDeviceSwitchOverVideoZoomFactors[0]`, which is only
    /// the wide lens on a device whose widest constituent is an ultra wide. On a
    /// wide + tele dual camera that first switch-over is the *telephoto* threshold, so
    /// "1x" was mapping onto the tele. Reading the wide lens out of
    /// `constituentDevices` is the version that holds for every layout.
    static func base(for device: AVCaptureDevice) -> CGFloat {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }),
              wideIndex > 0 else {
            return 1.0
        }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        guard wideIndex - 1 < switchOvers.count else { return 1.0 }
        return switchOvers[wideIndex - 1]
    }

    /// The ceiling, expressed as the user sees it.
    ///
    /// Clamping `maxAvailableVideoZoomFactor` at 15 and *then* dividing by the base was
    /// clamping in device space: on a phone whose wide lens sits at 2.0 that left a
    /// ceiling of 7,5× and quietly put `5×` near the top of the range. The limit belongs
    /// in the same units as the number on the chip.
    static func maxUIFactor(for device: AVCaptureDevice, base: CGFloat) -> CGFloat {
        guard base > 0 else { return 1.0 }
        return min(device.maxAvailableVideoZoomFactor / base, 15.0)
    }

    /// The optical constituents, as UI factors.
    static func opticalLevels(for device: AVCaptureDevice, base: CGFloat) -> [CGFloat] {
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }

        return device.constituentDevices.indices.compactMap { index -> CGFloat? in
            let deviceFactor: CGFloat
            if index == 0 {
                deviceFactor = device.minAvailableVideoZoomFactor
            } else if index - 1 < switchOvers.count {
                deviceFactor = switchOvers[index - 1]
            } else {
                return nil
            }
            return ((deviceFactor / base) * 10).rounded() / 10
        }
    }

    /// The lens list, topped up with the steps a user expects to find.
    ///
    /// Optical constituents alone are not the whole answer. An iPhone 16 has exactly two
    /// lenses — ultra wide and wide — so listing only those gave `0,5 · 1×` and dropped
    /// the `2×` that Camera.app shows, because on a 48 MP sensor that step is a crop
    /// rather than a lens and no API reports it as one. The rungs below are added only
    /// when the hardware range actually reaches them, so nothing on the pill is a
    /// promise the device cannot keep.
    ///
    /// The candidates stop at 5: past that it is plain digital crop, and a chip that
    /// offers 10× is advertising a blurry photo. Together with the optical lenses this
    /// lands on `0,5 · 1 · 2 · 3 · 5` on both an iPhone 16 and a Pro, which is the point —
    /// the same list, arrived at from different hardware.
    static func levels(
        optical: [CGFloat],
        maxFactor: CGFloat,
        candidates: [CGFloat] = [2.0, 3.0, 5.0],
        limit: Int = 5
    ) -> [CGFloat] {
        var levels = optical.filter { $0 <= maxFactor + 0.05 }.sorted()

        for candidate in candidates {
            guard levels.count < limit else { break }
            guard candidate <= maxFactor + 0.05 else { continue }
            // Within a fifth of an existing rung it is the same chip to the user.
            guard !levels.contains(where: { abs($0 - candidate) < 0.2 }) else { continue }
            levels.append(candidate)
            levels.sort()
        }

        return levels.count > 1 ? levels : []
    }

    /// The whole ladder for one device.
    static func levels(for device: AVCaptureDevice) -> [CGFloat] {
        let base = base(for: device)
        let optical = opticalLevels(for: device, base: base)
        return levels(
            optical: optical.isEmpty ? [1.0] : optical,
            maxFactor: maxUIFactor(for: device, base: base)
        )
    }

    /// The UI-factor range pinch may cover.
    static func range(for device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let base = base(for: device)
        let lower = device.minAvailableVideoZoomFactor / base
        let upper = maxUIFactor(for: device, base: base)
        guard lower < upper else { return 1.0...1.0 }
        return lower...upper
    }

    /// Where the device is sitting right now, in the units on the pill.
    static func currentUIFactor(of device: AVCaptureDevice) -> CGFloat? {
        let base = base(for: device)
        guard base > 0 else { return nil }
        return device.videoZoomFactor / base
    }

    /// Which rung of `levels` a factor is closest to.
    ///
    /// Used to keep the Camera Control HUD's highlighted lens in step with whatever moved
    /// the zoom — without it the button kept saying `1×` after the screen had moved on.
    ///
    /// Takes the factor rather than the device so it stays arithmetic: there is no way to
    /// build an `AVCaptureDevice` without hardware, so a device parameter here would have
    /// made the tie-breaking untestable for the sake of one division.
    static func nearestIndex(in levels: [CGFloat], forUIFactor factor: CGFloat) -> Int? {
        guard !levels.isEmpty else { return nil }
        return levels.indices.min(by: {
            abs(levels[$0] - factor) < abs(levels[$1] - factor)
        })
    }

    /// The device factor for a UI factor, clamped to what the lens can do.
    static func deviceFactor(forUIFactor factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        let base = base(for: device)
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = maxUIFactor(for: device, base: base) * base
        return max(minZoom, min(factor * base, maxZoom))
    }
}

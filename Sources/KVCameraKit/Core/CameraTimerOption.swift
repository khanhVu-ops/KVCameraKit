import Foundation

/// The self-timer delays the camera offers.
///
/// Public because the host has to supply one HUD title per option, in this order — and
/// guessing the order would silently mislabel the Camera Control picker.
public enum CameraTimerOption {
    public static let all: [Int] = [0, 3, 5, 10]
}

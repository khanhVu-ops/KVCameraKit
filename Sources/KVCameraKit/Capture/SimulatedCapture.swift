#if targetEnvironment(simulator)
import CoreGraphics
import Foundation
import UIKit

/// Stand-ins so the screen can be inspected on a simulator at all.
///
/// Gathered into one `#if` file rather than four scattered through the service: a
/// simulator branch inside a method is a second code path that reads as if it were part of
/// the real one, and the interesting question about each of these — "is this the shape a
/// device would return?" — is easier to answer when they sit together.
enum SimulatedCapture {

    /// Fed through the real ladder, so what shows up here has the same shape it will have
    /// on an iPhone 16.
    static var zoomLevels: [CGFloat] {
        CameraZoomLadder.levels(optical: [0.5, 1.0], maxFactor: 15.0)
    }

    static var zoomRange: ClosedRange<CGFloat> { 0.5...15.0 }

    static func photo() -> CapturedPhoto? {
        let size = CGSize(width: 1080, height: 1920)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

        let colors = [
            UIColor.black.cgColor,
            UIColor.darkGray.cgColor
        ] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }

        let text = "iOS-Vault Encrypted Capture"
        let font = UIFont.systemFont(ofSize: 36, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let data = image?.jpegData(compressionQuality: 0.85) else { return nil }
        return CapturedPhoto(data: data, preview: data, fileExtension: "jpg")
    }

    static func video() -> URL? {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SIM_REC_\(UUID().uuidString).mov")
        let dummyData = Data("SIMULATED_ENCRYPTED_VIDEO_STREAM".utf8)
        try? dummyData.write(to: tempURL)
        return tempURL
    }
}
#endif

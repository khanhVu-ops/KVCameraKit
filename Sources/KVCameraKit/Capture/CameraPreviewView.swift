import SwiftUI
import AVFoundation

/// Full-screen live camera viewfinder layer.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Handed up once, so rotation can be driven from a single `RotationCoordinator`
    /// that owns both the preview angle and the capture angle.
    let onLayerReady: (AVCaptureVideoPreviewLayer) -> Void
    /// `locked` is `true` for a long press: focus and exposure are pinned instead of
    /// handed back on the next scene change.
    let onTapToFocus: (CGPoint, CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)

        // Deliberately not a double tap. Making the single tap wait for a double to fail
        // would add the whole double-tap interval to every focus tap, and focus latency
        // is the thing this screen can least afford.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        view.addGestureRecognizer(longPress)

        onLayerReady(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Assigning the same session on every update tore down and rebuilt the
        // connection, which is a visible flicker.
        guard uiView.previewLayer.session !== session else { return }
        uiView.previewLayer.session = session
        onLayerReady(uiView.previewLayer)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapToFocus: onTapToFocus)
    }

    final class Coordinator: NSObject {
        let onTapToFocus: (CGPoint, CGPoint, Bool) -> Void

        init(onTapToFocus: @escaping (CGPoint, CGPoint, Bool) -> Void) {
            self.onTapToFocus = onTapToFocus
        }

        @MainActor
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            report(gesture, locked: false)
        }

        @MainActor
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            report(gesture, locked: true)
        }

        @MainActor
        private func report(_ gesture: UIGestureRecognizer, locked: Bool) {
            guard let view = gesture.view as? PreviewUIView else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTapToFocus(devicePoint, point, locked)
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

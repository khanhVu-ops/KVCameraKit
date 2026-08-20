import AVFoundation
import CoreGraphics
import MetalKit
import SwiftUI

/// The Metal viewfinder, as a SwiftUI view.
///
/// Deliberately the same shape as `CameraPreviewView` — same tap-to-focus callback, same
/// normalised device point — so the two engines are interchangeable at the call site. If
/// switching engines required the screen around it to change, the flag would not be a flag.
struct MetalCameraPreviewView: UIViewRepresentable {

    let frames: any FrameSource
    /// Mirrored for the front camera: a preview of your own face is a mirror in every camera
    /// app, while the captured file is not.
    let isMirrored: Bool
    /// `(devicePoint, viewPoint, isLocked)`, matching the system preview's contract.
    let onTapToFocus: (CGPoint, CGPoint, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, onTapToFocus: onTapToFocus)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        // Nothing reads the drawable back, so Metal may discard it after presenting.
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = .black

        // Driven by the display, pulling whatever the newest frame is, rather than the frame
        // queue calling `draw()` directly. A camera always has a next frame, so the wasted
        // work is a redraw of an identical texture — cheap — and in exchange there is no
        // cross-thread drawing to reason about. `MTKView` is not documented as safe to drive
        // from an arbitrary queue, and a viewfinder is a poor place to find out.
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)

        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        ))
        view.addGestureRecognizer(UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        ))

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.isMirrored = isMirrored
        context.coordinator.onTapToFocus = onTapToFocus
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        // Without this the subscription outlives the view, so the session keeps producing
        // frames for a renderer nobody draws — invisible except as battery.
        coordinator.detach()
    }

    final class Coordinator: NSObject, MTKViewDelegate {

        let renderer: CameraPreviewRenderer?
        var onTapToFocus: (CGPoint, CGPoint, Bool) -> Void

        private let frames: any FrameSource
        private var subscription: FrameSubscription?

        init(frames: any FrameSource, onTapToFocus: @escaping (CGPoint, CGPoint, Bool) -> Void) {
            self.frames = frames
            self.onTapToFocus = onTapToFocus
            self.renderer = CameraPreviewRenderer()
            super.init()
        }

        func attach(to view: MTKView) {
            guard let renderer else { return }
            subscription = frames.addConsumer { [weak renderer] frame in
                // Textures are built here, on the frame queue, while the buffer is still
                // guaranteed valid — see `CameraPreviewRenderer.accept`.
                renderer?.accept(frame)
            }
        }

        func detach() {
            subscription?.cancel()
            subscription = nil
        }

        deinit {
            subscription?.cancel()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Read here rather than observed, because *this view* is the thing being rotated
            // and its own window is the only authority on where the interface currently is.
            // Two property reads a frame, against the alternative of a notification whose
            // ordering against UIKit's own rotation is not guaranteed — and a preview that is
            // briefly sideways mid-rotation is exactly what this is fixing.
            renderer?.previewRotationAngle = CaptureRotation.previewAngle(
                for: view.window?.windowScene?.interfaceOrientation ?? .portrait
            )
            renderer?.draw(in: view)
        }

        // MARK: - Focus gestures

        /// The device point, derived arithmetically rather than by
        /// `captureDevicePointConverted(fromLayerPoint:)` — there is no preview layer to ask.
        ///
        /// Aspect **fill** means part of the frame is off screen, so a tap near an edge maps
        /// outside 0…1 and has to be clamped; without that, focusing near a corner asks the
        /// device for a point of interest it rejects and the tap silently does nothing.
        private func devicePoint(for viewPoint: CGPoint, in view: MTKView) -> CGPoint {
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
            // AVFoundation's point of interest is a portrait-oriented normalised space where
            // x runs down the long edge — the same convention the system layer converts into,
            // which is why both engines can share one callback.
            let x = min(max(viewPoint.y / size.height, 0), 1)
            let y = min(max(1 - viewPoint.x / size.width, 0), 1)
            return CGPoint(x: x, y: y)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? MTKView else { return }
            let point = recognizer.location(in: view)
            onTapToFocus(devicePoint(for: point, in: view), point, false)
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view as? MTKView else { return }
            let point = recognizer.location(in: view)
            onTapToFocus(devicePoint(for: point, in: view), point, true)
        }
    }
}

import AVFoundation
import CoreGraphics
import MetalKit
import QuartzCore
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
    /// Tone, LUT and film texture for the selected look.
    let filter: CameraFilter
    /// Skin smoothing composes with the selected look rather than replacing it.
    let beauty: CameraBeauty
    /// The censor look. The geometry it applies to arrives separately, and for a different
    /// reason — see `censorRegions`.
    let censorMode: CameraCensorMode
    /// The live face geometry, read once per drawn frame.
    ///
    /// A closure rather than a value, because a value here would be wrong most of the time.
    /// `updateUIView` runs when SwiftUI re-renders this view, which happens when something in
    /// `CameraState` changes — and the geometry deliberately does not live there. Pulled from
    /// the renderer's `draw`, the censor is always on the newest detection; pushed, it would sit
    /// wherever the faces were the last time an unrelated control was tapped.
    let censorRegions: @Sendable () -> [CensorRegion]
    /// `(devicePoint, viewPoint, isLocked)`, matching the system preview's contract.
    let onTapToFocus: (CGPoint, CGPoint, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, onTapToFocus: onTapToFocus)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        // The shader emits display-referred sRGB values. Without a layer color space Core
        // Animation treats them as untagged device RGB, which is visibly different from the
        // system preview on a wide-gamut display.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Nothing reads the drawable back, so Metal may discard it after presenting.
        view.framebufferOnly = true
        view.isOpaque = true
        view.backgroundColor = .black

        // Driven by the display, pulling whatever the newest frame is, rather than the frame
        // queue calling `draw()` directly: `MTKView` is not documented as safe to drive from an
        // arbitrary queue, and a viewfinder is a poor place to find out.
        //
        // Asking for the display's full rate is deliberate now that it is cheap. The renderer
        // returns immediately from a `draw` whose frame and look are both unchanged, so a 30 fps
        // camera on a 120 Hz screen costs one rendered frame in four and three early returns —
        // and the moment a stream *does* run faster, or the device is turned, the viewfinder is
        // already asking often enough to show it. The old value of 60 was doing the opposite:
        // re-shading an identical frame at twice the camera's rate, with the entire look in the
        // fragment shader.
        //
        // `MTKView` clamps this to what the display can actually do, so 120 means "as fast as
        // this screen goes" without asking a deprecated `UIScreen` which display that is.
        view.preferredFramesPerSecond = 120
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
        context.coordinator.renderer?.configure(filter: filter, beauty: beauty)
        context.coordinator.renderer?.censorMode = censorMode
        context.coordinator.renderer?.censorRegions = censorRegions
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

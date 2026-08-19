import SwiftUI
import UIKit
// `onCameraCaptureEvent` — the hardware shutter button — lives here.
import AVKit

/// Full-screen camera: photo and video capture, lens picker, focus and exposure, a
/// self-timer, Camera Control support, and the capture animation.
///
/// The host supplies three things and gets a screen: somewhere to put the bytes, the
/// Camera Control HUD titles, and what "close" means.
public struct CameraScreen: View {
    @StateObject private var viewModel: CameraViewModel
    private let controlTitles: CameraControlTitles

    @Environment(\.locale) private var locale

    private let onOpenLibrary: CameraLibraryOpener?

    public init(
        handler: any CameraArtifactHandler,
        controlTitles: CameraControlTitles,
        onDismiss: @escaping () -> Void,
        onOpenLibrary: CameraLibraryOpener? = nil
    ) {
        self.controlTitles = controlTitles
        self.onOpenLibrary = onOpenLibrary
        _viewModel = StateObject(
            wrappedValue: CameraViewModel(handler: handler, onDismiss: onDismiss)
        )
    }

    public var body: some View {
        CameraContentView(
            state: viewModel.state,
            cameraService: viewModel.cameraService,
            onAppear: { viewModel.send(.onAppear) },
            onDisappear: { viewModel.send(.onDisappear) },
            onSetPhotoMode: { viewModel.send(.setPhotoMode($0)) },
            onToggleFlash: { viewModel.send(.toggleFlash) },
            onToggleTorch: { viewModel.send(.toggleTorch) },
            onToggleGrid: { viewModel.send(.toggleGrid) },
            onToggleTimerMenu: { viewModel.send(.toggleTimerMenu) },
            onSetTimerDelay: { viewModel.send(.setTimerDelay($0)) },
            onSelectZoom: { factor, animated in viewModel.send(.setZoom(factor, animated: animated)) },
            onTapToFocus: { devPoint, viewPoint, locked in
                viewModel.send(.focusAt(devicePoint: devPoint, viewPoint: viewPoint, locked: locked))
            },
            onClearFocusLock: { viewModel.send(.clearFocusLock) },
            onOpenLibrary: onOpenLibrary,
            onSetExposureBias: { viewModel.send(.setExposureBias($0)) },
            onSwitchCamera: { viewModel.send(.switchCamera) },
            onShutterTap: { viewModel.send(.shutterTapped) },
            onFlightCompleted: { viewModel.send(.captureFlightCompleted) },
            onScenePhaseChanged: { viewModel.send(.scenePhaseChanged(isActive: $0)) },
            onDismissAlert: { viewModel.send(.dismissAlert) },
            onDismiss: { viewModel.send(.dismiss) }
        )
        .navigationBarHidden(true)
        .statusBar(hidden: true)
        // The HUD keeps whatever strings it was handed, so it has to be rebuilt when the
        // language changes. No `onChange` for that: the root view carries
        // `.id(language.current)`, so a language change recreates this screen and this
        // `onAppear` runs again — an `onChange` here could never fire.
        .onAppear {
            viewModel.send(.installHardwareControls(hardwareControlLabels))
        }
        // The lens list arrives once the session is up, and the HUD picker is built from
        // it, so the controls are rebuilt when it lands. Installing is idempotent — it
        // clears the session's controls first.
        .onChange(of: viewModel.state.zoomLevels) { _ in
            viewModel.send(.installHardwareControls(hardwareControlLabels))
        }
    }
}

private extension CameraScreen {

    var hardwareControlLabels: CameraControlLabels {
        CameraControlLabels(
            zoom: controlTitles.zoom,
            // Derived here, not supplied: the lens list comes from the hardware, and the
            // host has no way to know it. Formatted against the environment locale, which
            // is where the app's chosen language already lives.
            lensOptions: CameraControlLabels.lensOptionTitles(
                for: viewModel.state.zoomLevels,
                locale: locale
            ),
            exposure: controlTitles.exposure,
            timer: controlTitles.timer,
            timerOptions: controlTitles.timerOptions
        )
    }
}

/// Dumb child view taking values for high performance and clean SwiftUI subtree updates.
struct CameraContentView: View {
    let state: CameraState
    let cameraService: any CameraCapturing
    let onAppear: () -> Void
    let onDisappear: () -> Void
    let onSetPhotoMode: (Bool) -> Void
    let onToggleFlash: () -> Void
    let onToggleTorch: () -> Void
    let onToggleGrid: () -> Void
    let onToggleTimerMenu: () -> Void
    let onSetTimerDelay: (Int) -> Void
    let onSelectZoom: (CGFloat, Bool) -> Void
    let onTapToFocus: (CGPoint, CGPoint, Bool) -> Void
    let onClearFocusLock: () -> Void
    let onOpenLibrary: CameraLibraryOpener?
    let onSetExposureBias: (Float) -> Void
    let onSwitchCamera: () -> Void
    let onShutterTap: () -> Void
    let onFlightCompleted: () -> Void
    let onScenePhaseChanged: (Bool) -> Void
    let onDismissAlert: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.cameraTheme) private var theme

    @State private var localFocusPoint: CGPoint?
    @State private var currentPinchZoom: CGFloat = 1.0
    @State private var flipRotationDegrees: Double = 0
    @State private var viewfinderReveal: Double = 0
    @State private var thumbnailScale: CGFloat = 1.0
    @State private var bounceTask: Task<Void, Never>?

    @Namespace private var captureZoomNamespace

    /// One source for the thumbnail-to-library zoom; there is only ever one on screen.
    private static let libraryZoomID = "CAMERA_LATEST_CAPTURE"

    /// Stated once, because the timer menu hangs exactly this far below its button.
    private static let topBarButtonSide: CGFloat = 42

    @Namespace private var modeNamespace

    var body: some View {
        GeometryReader { fullScreenGeo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1. Full Screen Camera Viewfinder Layer
                //
                // Revealed rather than switched on. Starting the session takes a beat, and
                // cutting straight to a live layer showed a black frame first.
                ZStack {
                    if state.isAuthorized {
                        CameraPreviewView(
                            session: cameraService.session,
                            onLayerReady: { cameraService.attachPreviewLayer($0) },
                            onTapToFocus: { devicePoint, viewPoint, locked in
                                localFocusPoint = viewPoint
                                onTapToFocus(devicePoint, viewPoint, locked)
                            }
                        )
                        .ignoresSafeArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Full-screen 3x3 Grid Overlay
                        if state.isGridEnabled {
                            gridOverlay(size: fullScreenGeo.size)
                                .ignoresSafeArea()
                                .transition(.opacity)
                        }

                        // Focus Reticle & Interactive Sun Exposure Slider
                        if let focusPoint = localFocusPoint {
                            CameraFocusView(
                                position: focusPoint,
                                isLocked: state.isFocusLocked,
                                initialExposureBias: state.exposureBias,
                                onExposureChange: { bias in
                                    onSetExposureBias(bias)
                                },
                                onExpired: {
                                    localFocusPoint = nil
                                }
                            )
                            // Keyed on the point itself. Summing the coordinates gave two
                            // different taps the same identity whenever x + y matched, and
                            // the reticle then refused to move.
                            .id(focusPoint)
                        }
                    }
                }
                .opacity(viewfinderReveal)
                .scaleEffect(0.985 + 0.015 * viewfinderReveal)
                // Covers the reconfiguration rather than a guessed delay: `isSwitchingCamera`
                // is held for exactly as long as the session is being rebuilt.
                .blur(radius: state.isSwitchingCamera ? 16 : 0)
                .scaleEffect(state.isSwitchingCamera ? 1.07 : 1.0)
                .animation(.easeInOut(duration: 0.26), value: state.isSwitchingCamera)
                .animation(.easeInOut(duration: 0.22), value: state.isGridEnabled)

                if state.authorization == .denied {
                    permissionPrompt
                }

                // A frozen viewfinder with nothing said about it reads as a broken app.
                if state.isSessionInterrupted {
                    interruptionNotice
                }

                // 2. Shutter Curtain
                //
                // Black, not the white flash this used to do. White is a lie unless the
                // flash actually fired, and at 0.9 alpha it was blinding in a dark room.
                // The curtain's real job is to cover sensor latency: it drops on the tap
                // and lifts behind the departing card, so there is no gap between the
                // press and the first thing that moves.
                Color.black
                    .opacity(curtainOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .animation(curtainAnimation, value: state.captureStage)

                // 3. Ambient Readability Gradients (Scrims)
                //
                // `ignoresSafeArea` goes on the stack, not on each gradient. Applied to a
                // gradient inside a laid-out `VStack` it extended the drawing but left the
                // band's own height inside the safe area, so the strip below the home
                // indicator stayed clear — the viewfinder showed through it and there was a
                // visible seam where the gradient stopped.
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.45), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 130)

                    Spacer(minLength: 0)

                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.35), Color.black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 260)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // 4. User Controls Layer (Top Bar, Bottom Controls)
                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, theme.spacingM)
                        .padding(.top, theme.spacingS)

                    if state.isFocusLocked {
                        focusLockBadge
                            .padding(.top, theme.spacingS)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()

                    bottomControls
                        .padding(.bottom, theme.spacingL)
                }
                // Apple's guidance for Camera Control: while the system HUD is up, the
                // app's own controls step aside rather than argue for the same corner.
                .opacity(state.isHardwareHUDVisible ? 0 : 1)
                .animation(.easeInOut(duration: 0.22), value: state.isHardwareHUDVisible)
                // On the stack, not on `topBar`: the options row is a sibling of the bar,
                // and a transition only runs if an ancestor of the *inserted* view carries
                // the animation.
                .animation(.spring(response: 0.34, dampingFraction: 0.76), value: state.isTimerMenuOpen)
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: state.isFocusLocked)

                // 5. Giant Numeric Countdown Timer with Numeric Transition
                if state.timerCountdown > 0 {
                    countdownDisplay
                }
            }
            // 6. The captured frame, flying to the thumbnail that published its bounds.
            .overlayPreferenceValue(CaptureTargetAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if case .flying(let flight) = state.captureStage, let anchor = anchor {
                        CameraCaptureFlightView(
                            flight: flight,
                            canvasSize: proxy.size,
                            targetRect: proxy[anchor],
                            targetCornerRadius: CameraThumbnailButton.cornerRadius,
                            reduceMotion: reduceMotion,
                            onCompleted: onFlightCompleted
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .simultaneousGesture(
                // Swipe the strip, carousel style: dragging right brings the mode on the
                // left (VIDEO) into the middle.
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > 60,
                              abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                            onSetPhotoMode(value.translation.width < 0)
                        }
                    }
            )
            .simultaneousGesture(
                // No limits here any more. The view used to clamp to 0.5...10 from its own
                // guess while the device clamped to something else, so the pill could
                // promise zoom the lens did not have. The ViewModel owns the range now.
                MagnificationGesture()
                    .onChanged { scale in
                        onSelectZoom(currentPinchZoom * scale, false)
                    }
                    .onEnded { _ in
                        currentPinchZoom = state.currentZoom
                        onSelectZoom(state.currentZoom, true)
                    }
            )
        }
        .onChange(of: state.authorization) { authorization in
            guard authorization == .authorized else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.42)) {
                viewfinderReveal = 1
            }
        }
        // The hardware volume buttons, through the API that exists for it. Nothing else
        // may claim them, and this is also what makes the buttons work on a Camera
        // Control-equipped phone.
        .onCameraCaptureEvent { event in
            guard event.phase == .ended else { return }
            onShutterTap()
        }
        .onChange(of: scenePhase) { phase in
            onScenePhaseChanged(phase == .active)
        }
        .onChange(of: state.captureStage) { stage in
            guard case .flying = stage else { return }
            scheduleThumbnailBounce()
        }
        .cameraAlert(state.alert, onDismiss: onDismissAlert)
        .onAppear {
            onAppear()
        }
        .onDisappear {
            bounceTask?.cancel()
            onDisappear()
        }
    }

    // MARK: - Capture choreography

    private var curtainOpacity: Double {
        state.captureStage == .exposing ? 1.0 : 0.0
    }

    /// Down fast, up slow: the drop is feedback and has to beat the eye, the lift is
    /// scenery and reads better behind the card.
    private var curtainAnimation: Animation {
        state.captureStage == .exposing
            ? .easeOut(duration: CaptureFlightTiming.curtainDown)
            : .easeIn(duration: CaptureFlightTiming.curtainLift)
    }

    /// Scheduled from the shared timeline rather than guessed, so the bounce happens on
    /// the frame the card arrives instead of after it has gone.
    private func scheduleThumbnailBounce() {
        bounceTask?.cancel()
        guard !reduceMotion else { return }
        bounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(CaptureFlightTiming.touchdown * 1_000_000_000))
            guard !Task.isCancelled else { return }
            CameraHaptic.light.play()
            withAnimation(.spring(response: 0.20, dampingFraction: 0.5)) {
                thumbnailScale = 1.16
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.7).delay(0.12)) {
                thumbnailScale = 1.0
            }
        }
    }

    private var countdownDisplay: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.5))
                .frame(width: 140, height: 140)
                .overlay(
                    Circle()
                        .stroke(Color.yellow.opacity(0.25), lineWidth: 2)
                )

            // Draining ring, so the wait has a shape and not just a number.
            Circle()
                .trim(from: 0, to: CGFloat(state.timerCountdown) / CGFloat(max(state.timerDelaySeconds, 1)))
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 140, height: 140)
                .shadow(color: Color.yellow.opacity(0.5), radius: 6)
                .animation(.linear(duration: 1.0), value: state.timerCountdown)

            Text(verbatim: "\(state.timerCountdown)")
                .font(.system(size: 84, weight: .bold, design: .rounded))
                .foregroundStyle(Color.yellow)
                .contentTransition(.numericText(countsDown: true))
                .shadow(color: Color.yellow.opacity(0.8), radius: 16, x: 0, y: 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.timerCountdown)
    }

    private var topBar: some View {
        HStack(spacing: theme.spacingS) {
            // Flash Mode
            Button {
                onToggleFlash()
            } label: {
                Image(systemName: flashIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(state.flashMode == .off ? Color.white.opacity(0.8) : Color.yellow)
                    .frame(width: Self.topBarButtonSide, height: Self.topBarButtonSide)
                    .background(glassCircleBackground)
            }

            // Torch Toggle (in Video Mode)
            if !state.isPhotoMode {
                Button {
                    onToggleTorch()
                } label: {
                    Image(systemName: state.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(state.isTorchOn ? Color.yellow : Color.white.opacity(0.8))
                        .frame(width: Self.topBarButtonSide, height: Self.topBarButtonSide)
                        .background(glassCircleBackground)
                }
                .transition(.scale.combined(with: .opacity))
            }

            // Grid Toggle
            Button {
                onToggleGrid()
            } label: {
                Image(systemName: "grid")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(state.isGridEnabled ? Color.yellow : Color.white.opacity(0.8))
                    .frame(width: Self.topBarButtonSide, height: Self.topBarButtonSide)
                    .background(glassCircleBackground)
            }

            timerButton

            Spacer()

            // Dismiss / Close Button
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: Self.topBarButtonSide, height: Self.topBarButtonSide)
                    .background(glassCircleBackground)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: state.isPhotoMode)
    }

    /// Tap to open, tap an option to choose.
    ///
    /// It used to cycle: Off → 3 → 10 → Off, which only works if you already know how
    /// many stops it has, and adding 5s would have made it four blind taps to get back.
    private var timerButton: some View {
        timerButtonLabel
            // Anchored to the button rather than to the bar, so it stays under the timer
            // whether or not video mode has added a torch button beside it. An overlay
            // takes no part in layout, which is why it can hang below the bar at all.
            .overlay(alignment: .top) {
                if state.isTimerMenuOpen {
                    timerOptionsColumn
                        .offset(y: Self.topBarButtonSide + theme.spacingS)
                        .transition(.scale(scale: 0.86, anchor: .top).combined(with: .opacity))
                }
            }
    }

    private var timerButtonLabel: some View {
        Button {
            onToggleTimerMenu()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                if state.timerDelaySeconds > 0 && !state.isTimerMenuOpen {
                    // Spacing 0 between the number and its unit: at 2 pt the badge read
                    // "5 s" while the menu right above it said "5s".
                    HStack(spacing: 0) {
                        Text(state.timerDelaySeconds, format: .number)
                        Text(verbatim: "s")
                    }
                    .font(.system(size: 11, weight: .bold))
                }
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(state.timerDelaySeconds > 0 ? Color.yellow : Color.white.opacity(0.8))
            .frame(minWidth: Self.topBarButtonSide, minHeight: Self.topBarButtonSide)
            .padding(.horizontal, state.timerDelaySeconds > 0 && !state.isTimerMenuOpen ? 6 : 0)
            .background(glassCapsuleBackground)
        }
    }

    /// Drops straight down out of the button.
    ///
    /// Laid out sideways inside the top bar it had to share the width with every other
    /// control, and video mode adds a torch button — the four labels were then squeezed
    /// into unreadable slivers. Vertically there is nothing to compete with, however many
    /// buttons the bar grows to.
    private var timerOptionsColumn: some View {
        VStack(spacing: 2) {
            ForEach(CameraState.timerDelayOptions, id: \.self) { seconds in
                timerOption(seconds)
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .fixedSize()
    }

    private func timerOption(_ seconds: Int) -> some View {
        let isSelected = state.timerDelaySeconds == seconds

        return Button {
            onSetTimerDelay(seconds)
        } label: {
            Group {
                if seconds == 0 {
                    Text("Off", bundle: .module)
                } else {
                    HStack(spacing: 0) {
                        Text(seconds, format: .number)
                        Text(verbatim: "s")
                    }
                }
            }
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .rounded))
            .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
            .frame(width: 46, height: 32)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.8))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var glassCircleBackground: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
    }

    private var glassCapsuleBackground: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
    }

    private var bottomControls: some View {
        VStack(spacing: theme.spacingS) {
            // 1. Zoom Picker Pill
            CameraZoomPicker(
                levels: state.zoomLevels,
                currentZoom: state.currentZoom,
                onSelectZoom: { factor in
                    currentPinchZoom = factor
                    onSelectZoom(factor, true)
                },
                onZoomTo: { factor, animated in
                    currentPinchZoom = factor
                    onSelectZoom(factor, animated)
                }
            )
            .padding(.bottom, 2)

            // 2. Mode Switcher (PHOTO / VIDEO) or Recording Stopwatch
            if !state.isPhotoMode && state.isRecording {
                recordingStopwatch
                    .padding(.vertical, 4)
            } else {
                systemModeSwitcher
                    .padding(.vertical, 4)
            }

            // 3. Shutter Row: Thumbnail (left), Shutter Button (center), Flip Camera (right)
            HStack {
                CameraThumbnailButton(
                    imageData: state.latestCapturedThumbnailData,
                    isSealing: state.isSealing,
                    scale: thumbnailScale,
                    action: openLibrary
                )
                // The flight reads this back instead of guessing an offset from the
                // screen corner, which is what made it miss on every device but one.
                .anchorPreference(key: CaptureTargetAnchorKey.self, value: .bounds) { $0 }
                .matchedTransitionSource(id: Self.libraryZoomID, in: captureZoomNamespace) {
                    $0.clipShape(.rect(cornerRadius: CameraThumbnailButton.cornerRadius))
                }

                Spacer()

                CameraShutterButton(
                    isPhotoMode: state.isPhotoMode,
                    isRecording: state.isRecording,
                    isExposing: state.captureStage == .exposing,
                    action: onShutterTap
                )

                Spacer()

                // Right: Flip Camera Button with Liquid Glass styling
                if !state.isRecording {
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) {
                            flipRotationDegrees += 180
                        }
                        onSwitchCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .rotationEffect(.degrees(flipRotationDegrees))
                            .frame(width: 50, height: 50)
                            .background(glassCircleBackground)
                    }
                    .frame(width: 60, height: 60)
                } else {
                    Color.clear
                        .frame(width: 60, height: 60)
                }
            }
            .padding(.horizontal, theme.spacingL)
            .padding(.top, 4)
        }
    }

    private var recordingStopwatch: some View {
        HStack(spacing: theme.spacingXS) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)

            Text(state.formattedDuration)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, theme.spacingM)
        .padding(.vertical, theme.spacingXS)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.red.opacity(0.4), lineWidth: 1.0)
                )
        }
        .shadow(color: Color.red.opacity(0.4), radius: 8, x: 0, y: 0)
        .transition(.scale.combined(with: .opacity))
    }

    /// Modern Apple Camera Mode Switcher with Liquid Glass styling & Spring Transition
    private var systemModeSwitcher: some View {
        HStack(spacing: 2) {
            // `.cameraKit`, not a bare literal: a `LocalizedStringResource` literal resolves
            // against `Bundle.main`, which is the host app, so these two would read `VIDEO`
            // and `PHOTO` in every language outside this project.
            modeOption(title: .cameraKit("VIDEO"), isActive: !state.isPhotoMode) { onSetPhotoMode(false) }
            modeOption(title: .cameraKit("PHOTO"), isActive: state.isPhotoMode) { onSetPhotoMode(true) }
        }
        .padding(3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .fixedSize()
        .contentShape(Capsule())
    }

    private func modeOption(
        title: LocalizedStringResource,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                action()
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .bold : .semibold, design: .rounded))
                .foregroundStyle(isActive ? Color.yellow : Color.white.opacity(0.8))
                .shadow(color: isActive ? Color.yellow.opacity(0.5) : Color.clear, radius: 4, x: 0, y: 0)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background {
                    if isActive {
                        Capsule()
                            .fill(Color.white.opacity(0.20))
                            .overlay(
                                Capsule()
                                    .stroke(
                                        LinearGradient(
                                            colors: [Color.white.opacity(0.5), Color.white.opacity(0.15)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.8
                                    )
                            )
                            .matchedGeometryEffect(id: "ACTIVE_MODE_INDICATOR", in: modeNamespace)
                            .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func gridOverlay(size: CGSize) -> some View {
        Path { path in
            let stepY = size.height / 3
            path.move(to: CGPoint(x: 0, y: stepY))
            path.addLine(to: CGPoint(x: size.width, y: stepY))
            path.move(to: CGPoint(x: 0, y: stepY * 2))
            path.addLine(to: CGPoint(x: size.width, y: stepY * 2))

            let stepX = size.width / 3
            path.move(to: CGPoint(x: stepX, y: 0))
            path.addLine(to: CGPoint(x: stepX, y: size.height))
            path.move(to: CGPoint(x: stepX * 2, y: 0))
            path.addLine(to: CGPoint(x: stepX * 2, y: size.height))
        }
        .stroke(Color.white.opacity(0.42), lineWidth: 1.0)
        .allowsHitTesting(false)
    }

    /// Hands the zoom transition's source half to the host, which owns the destination.
    private func openLibrary() {
        guard state.latestCapturedThumbnailData != nil, let onOpenLibrary = onOpenLibrary else { return }
        CameraHaptic.light.play()
        onOpenLibrary(Self.libraryZoomID, captureZoomNamespace)
    }

    private var focusLockBadge: some View {
        Button {
            // The reticle's position lives in this view, not in the state, so releasing
            // the lock has to dismiss it here too — otherwise the badge goes and a stale
            // box hangs around until its own fade-out.
            withAnimation(.easeOut(duration: 0.2)) {
                localFocusPoint = nil
            }
            onClearFocusLock()
        } label: {
            Text("AE/AF LOCK", bundle: .module)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black)
                .padding(.horizontal, theme.spacingS)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.yellow)
                )
        }
        .buttonStyle(.plain)
    }

    private var interruptionNotice: some View {
        VStack(spacing: theme.spacingS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.yellow)

            Text("Camera is unavailable", bundle: .module)
                .font(theme.titleFont)
                .foregroundStyle(Color.white)

            Text("Another app or a phone call is using the camera.", bundle: .module)
                .font(theme.bodyFont)
                .foregroundStyle(Color.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, theme.spacingL)
        }
        .padding(theme.spacingL)
        .background {
            RoundedRectangle(cornerRadius: theme.largeCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .padding(.horizontal, theme.spacingL)
        .transition(.opacity)
    }

    private var permissionPrompt: some View {
        VStack(spacing: theme.spacingM) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.white.opacity(0.6))

            Text("Camera access is required", bundle: .module)
                .font(theme.titleFont)
                .foregroundStyle(Color.white)

            Text("Please enable camera access in Settings to take encrypted photos directly into your vault.", bundle: .module)
                .font(theme.bodyFont)
                .foregroundStyle(Color.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, theme.spacingL)

            // Without this the prompt tells the user to go somewhere and leaves them to
            // find it. The screen has no other way forward.
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings", bundle: .module)
                    .font(theme.bodyStrongFont)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, theme.spacingL)
                    .padding(.vertical, theme.spacingS)
                    .background(Capsule().fill(Color.white))
            }
            .padding(.top, theme.spacingS)
        }
        .transition(.opacity)
    }

    private var flashIcon: String {
        switch state.flashMode {
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        }
    }
}

#Preview("Camera View") {
    CameraContentView(
        state: CameraState(authorization: .authorized),
        cameraService: CameraService(),
        onAppear: {},
        onDisappear: {},
        onSetPhotoMode: { _ in },
        onToggleFlash: {},
        onToggleTorch: {},
        onToggleGrid: {},
        onToggleTimerMenu: {},
        onSetTimerDelay: { _ in },
        onSelectZoom: { _, _ in },
        onTapToFocus: { _, _, _ in },
        onClearFocusLock: {},
        onOpenLibrary: nil,
        onSetExposureBias: { _ in },
        onSwitchCamera: {},
        onShutterTap: {},
        onFlightCompleted: {},
        onScenePhaseChanged: { _ in },
        onDismissAlert: {},
        onDismiss: {}
    )
}

#Preview("Camera View - Permission Denied") {
    CameraContentView(
        state: CameraState(authorization: .denied),
        cameraService: CameraService(),
        onAppear: {},
        onDisappear: {},
        onSetPhotoMode: { _ in },
        onToggleFlash: {},
        onToggleTorch: {},
        onToggleGrid: {},
        onToggleTimerMenu: {},
        onSetTimerDelay: { _ in },
        onSelectZoom: { _, _ in },
        onTapToFocus: { _, _, _ in },
        onClearFocusLock: {},
        onOpenLibrary: nil,
        onSetExposureBias: { _ in },
        onSwitchCamera: {},
        onShutterTap: {},
        onFlightCompleted: {},
        onScenePhaseChanged: { _ in },
        onDismissAlert: {},
        onDismiss: {}
    )
}

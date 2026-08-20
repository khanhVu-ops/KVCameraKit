import SwiftUI

/// Every decision that changes the pixels, on one shelf: Styles, Film, LUT, Beauty, Privacy.
///
/// It replaces two shelves — `CameraFilterStrip` and `CameraCensorPicker` — that occupied the same
/// twelve points at the bottom of the screen and were kept apart by two independent booleans. The
/// user-visible symptom was that opening one closed the other with no way back except two more
/// taps, and that switching from a beauty slider to the censor picker felt like changing app.
///
/// Three things here are load-bearing rather than decoration:
///
/// **A header that names what is applied.** A film preset, a beauty slider and a censor all
/// compose. That is the design, but composing invisibly is what makes stacking them feel broken:
/// nothing on screen said both were on, so the picture was the only feedback. The pills say, and
/// tapping one goes to the tab that changes it.
///
/// **Chips for the visible tab only.** The old strip rendered all fourteen presets through Core
/// Image every time it appeared — and again on every tick of the beauty slider, after clearing
/// what it had so the chips flashed back to a grey gradient. Five renders, on the tab you are
/// looking at, once.
///
/// **One base frame, reused.** Grabbing a frame off the stream costs a wait of up to a second, so
/// it happens once per opening and the beauty slider re-renders from what is already in hand.
struct CameraLookShelf: View {

    let filters: [CameraFilter]
    let selectedFilterID: String
    let beauty: CameraBeauty
    let censorMode: CameraCensorMode
    let stages: [CameraLookStage]
    let tab: CameraLookShelfTab
    /// Whether the look tabs can do anything. `false` in a mode that cannot carry a look, where
    /// Privacy is still available — so the shelf is shown with the look tabs disabled rather than
    /// not shown at all.
    let canFilter: Bool
    let canCensor: Bool
    let frames: (any FrameSource)?

    let onSelectTab: (CameraLookShelfTab) -> Void
    let onSelectFilter: (CameraFilter) -> Void
    let onBeautyChange: (CameraBeauty) -> Void
    let onSelectCensorMode: (CameraCensorMode) -> Void
    let onReset: () -> Void
    let onClose: () -> Void

    /// The frame every chip is rendered from. Held for as long as the shelf is on screen so a
    /// beauty adjustment re-renders the looks without waiting for the camera again.
    @State private var base: CGImage?
    @State private var thumbnails: [String: CGImage] = [:]
    @State private var beautyAdjustment: BeautyAdjustment = .smooth

    private static let chipWidth: CGFloat = 62
    private static let chipHeight: CGFloat = 82
    private static let chipCornerRadius: CGFloat = 14
    private static let contentHeight: CGFloat = 122

    var body: some View {
        VStack(spacing: 10) {
            header
            tabBar
            content
                // A fixed height across all five tabs. Without it the shelf grows and shrinks as
                // the user moves between chips and sliders, which moves the shutter button under
                // their thumb.
                .frame(height: Self.contentHeight)
        }
        .padding(.vertical, 10)
        .background(shelfBackground)
        .padding(.horizontal, 10)
        .task(id: TaskKey(tab: tab, beauty: beauty)) { await refreshThumbnails() }
    }

    // MARK: - Header

    /// What is applied, and a way to undo all of it.
    private var header: some View {
        HStack(spacing: 6) {
            if stages.isEmpty {
                Text(LocalizedStringResource.cameraKit("No look applied"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(stages) { stage in
                            stagePill(stage)
                        }
                    }
                }
                .frame(height: 24)

                Button {
                    CameraHaptic.selection.play()
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringResource.cameraKit("Reset look")))
            }

            Spacer(minLength: 0)

            Button {
                CameraHaptic.light.play()
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringResource.cameraKit("Close")))
        }
        .padding(.horizontal, 12)
    }

    /// One applied stage, as a tappable pill that goes to the tab that controls it.
    private func stagePill(_ stage: CameraLookStage) -> some View {
        Button {
            CameraHaptic.light.play()
            onSelectTab(destination(for: stage.kind))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: stage.kind.systemIconName)
                    .font(.system(size: 9, weight: .bold))
                Text(stage.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.yellow)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color.yellow.opacity(0.14))
                    .overlay { Capsule().strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    /// Where the filter pill goes depends on which category is selected, which is why this is not
    /// a property of `CameraLookStage.Kind`: a stage knows what it does, not where its control is.
    private func destination(for kind: CameraLookStage.Kind) -> CameraLookShelfTab {
        switch kind {
        case .filter:
            return CameraLookShelfTab(category: activeFilter?.category ?? .styles)
        case .beauty:
            return .beauty
        case .censor:
            return .privacy
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(CameraLookShelfTab.allCases) { item in
                let isEnabled = item.needsLookSupport ? canFilter : canCensor
                Button {
                    onSelectTab(item)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.systemIconName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(tabForeground(item, isEnabled: isEnabled))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(tab == item ? Color.yellow : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                // A dot for "this tab is doing something", so the user can see a stage is on
                // without reading the header — the two agree, which is the point.
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(tab == item ? Color.black : Color.yellow)
                        .frame(width: 4, height: 4)
                        .padding(.trailing, 6)
                        .padding(.top, 4)
                        .opacity(isActive(item) ? 1 : 0)
                }
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func tabForeground(_ item: CameraLookShelfTab, isEnabled: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.25) }
        return tab == item ? Color.black : Color.white.opacity(0.72)
    }

    /// Whether this tab currently contributes to the picture.
    private func isActive(_ item: CameraLookShelfTab) -> Bool {
        switch item {
        case .styles, .film, .lut:
            return activeFilter?.category == item.category
        case .beauty:
            return beauty.isEnabled
        case .privacy:
            return censorMode.isEnabled
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .styles, .film, .lut:
            chipCarousel
        case .beauty:
            beautyControls
        case .privacy:
            privacyControls
        }
    }

    private var activeFilter: CameraFilter? {
        filters.first { $0.id == selectedFilterID }
    }

    private var visibleFilters: [CameraFilter] {
        guard let category = tab.category else { return [] }
        return filters.filter { $0.category == category }
    }

    private var chipCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(visibleFilters) { filter in
                        chip(for: filter).id(filter.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .onAppear { proxy.scrollTo(selectedFilterID, anchor: .center) }
            .onChange(of: selectedFilterID) { _, newID in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func chip(for filter: CameraFilter) -> some View {
        let isSelected = filter.id == selectedFilterID
        return Button {
            CameraHaptic.selection.play()
            onSelectFilter(filter)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let image = thumbnails[filter.id] {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: Self.chipWidth, height: Self.chipHeight)
                .clipShape(RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                        .strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.2), lineWidth: isSelected ? 2.5 : 1)
                }

                Text(filter.title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Color.yellow : Color.white.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: Self.chipWidth + 18)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.04 : 0.94)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
    }

    // MARK: - Beauty

    private var beautyControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(BeautyAdjustment.allCases) { adjustment in
                    Button {
                        CameraHaptic.selection.play()
                        withAnimation(.snappy(duration: 0.2)) { beautyAdjustment = adjustment }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: adjustment.symbol)
                                .font(.system(size: 13, weight: .semibold))
                            Text(adjustment.title)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(beautyAdjustment == adjustment ? Color.black : Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            beautyAdjustment == adjustment ? Color.yellow : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        // A dot per adjustment, because four sliders behind four buttons is
                        // otherwise three hidden values: turning on Rosy and forgetting is how a
                        // camera develops a mysterious colour cast.
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(beautyAdjustment == adjustment ? Color.black : Color.yellow)
                                .frame(width: 4, height: 4)
                                .padding(4)
                                .opacity(value(for: adjustment) > 0.001 ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: beautyAdjustment.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.yellow)
                    .frame(width: 20)

                Slider(
                    value: Binding(
                        get: { Double(value(for: beautyAdjustment)) },
                        set: { onBeautyChange(beauty.updating(beautyAdjustment, to: Float($0))) }
                    ),
                    in: 0...1
                )
                .tint(.yellow)
                .accessibilityLabel(Text(beautyAdjustment.title))

                Text(Double(value(for: beautyAdjustment)), format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Privacy

    private var privacyControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(CameraCensorMode.allCases, id: \.self) { mode in
                    let isSelected = mode == censorMode
                    Button {
                        CameraHaptic.selection.play()
                        onSelectCensorMode(mode)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.systemIconName)
                                .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                            Text(mode.title)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isSelected ? Color.yellow : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCensor)
                }
            }

            // Said out loud rather than implied by a disabled row. A censor that cannot be
            // honoured is the one feature where a vague UI is actively dangerous: the user has to
            // know their face is *not* being covered.
            Text(canCensor
                 ? LocalizedStringResource.cameraKit("Faces are covered in the photo and the video, not just on screen")
                 : LocalizedStringResource.cameraKit("Face censoring is unavailable in this build"))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(canCensor ? Color.white.opacity(0.5) : Color.orange.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Chrome

    private var shelfBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.black.opacity(0.45))
            .background(.ultraThinMaterial.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
    }

    // MARK: - Thumbnails

    /// What a thumbnail render depends on.
    ///
    /// The tab is in here because only the visible tab is rendered, and beauty is because it
    /// composes into every chip. Nothing else is: the *selected* filter is not, which is what
    /// stopped the whole strip re-rendering every time the user tapped a neighbouring chip.
    private struct TaskKey: Equatable {
        let tab: CameraLookShelfTab
        let beauty: CameraBeauty
    }

    private func refreshThumbnails() async {
        guard let category = tab.category, let frames else { return }
        let wanted = filters.filter { $0.category == category }
        guard !wanted.isEmpty else { return }

        // Grabbed once and kept. This is a wait on the camera of up to a second, and the old
        // strip paid it again on every tick of the beauty slider — while clearing the chips it
        // already had, so they flashed to a grey gradient and back for the length of a drag.
        if base == nil {
            base = await ToneRenderer.thumbnailBase(from: frames)
        }
        guard let base, !Task.isCancelled else { return }

        let beauty = beauty
        let rendered = await Task.detached(priority: .userInitiated) {
            CameraLookRenderer.thumbnails(base: base, filters: wanted, beauty: beauty)
        }.value

        guard !Task.isCancelled else { return }
        // Merged rather than replaced, so switching tabs keeps the chips already rendered and a
        // beauty change updates them in place instead of blanking them first.
        for (filter, image) in zip(wanted, rendered) {
            thumbnails[filter.id] = image
        }
    }

    private func value(for adjustment: BeautyAdjustment) -> Float {
        switch adjustment {
        case .smooth:   return beauty.smoothing
        case .brighten: return beauty.brightness
        case .rosy:     return beauty.rosy
        case .define:   return beauty.definition
        }
    }
}

// MARK: - Beauty adjustments

extension CameraLookShelf {
    enum BeautyAdjustment: String, CaseIterable, Identifiable {
        case smooth
        case brighten
        case rosy
        case define

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .smooth:   return .cameraKit("Smooth")
            case .brighten: return .cameraKit("Brighten")
            case .rosy:     return .cameraKit("Rosy")
            case .define:   return .cameraKit("Define")
            }
        }

        var symbol: String {
            switch self {
            case .smooth:   return "drop"
            case .brighten: return "sun.max"
            case .rosy:     return "heart"
            case .define:   return "circle.lefthalf.filled"
            }
        }
    }
}

private extension CameraBeauty {
    func updating(_ adjustment: CameraLookShelf.BeautyAdjustment, to value: Float) -> CameraBeauty {
        var copy = self
        switch adjustment {
        case .smooth:   copy.smoothing = min(max(value, 0), 1)
        case .brighten: copy.brightness = min(max(value, 0), 1)
        case .rosy:     copy.rosy = min(max(value, 0), 1)
        case .define:   copy.definition = min(max(value, 0), 1)
        }
        return copy
    }
}

// MARK: - Previews

private func previewShelf(
    tab: CameraLookShelfTab,
    filter: CameraFilter = .portra400,
    beauty: CameraBeauty = .off,
    censorMode: CameraCensorMode = .off,
    canCensor: Bool = true
) -> some View {
    var stages: [CameraLookStage] = []
    if filter.id != CameraFilter.original.id {
        stages.append(CameraLookStage(kind: .filter, title: filter.title))
    }
    if beauty.isEnabled {
        stages.append(CameraLookStage(kind: .beauty, title: CameraLookShelfTab.beauty.title))
    }
    if censorMode.isEnabled {
        stages.append(CameraLookStage(kind: .censor, title: censorMode.title))
    }

    return CameraLookShelf(
        filters: CameraFilter.all,
        selectedFilterID: filter.id,
        beauty: beauty,
        censorMode: censorMode,
        stages: stages,
        tab: tab,
        canFilter: true,
        canCensor: canCensor,
        frames: nil,
        onSelectTab: { _ in },
        onSelectFilter: { _ in },
        onBeautyChange: { _ in },
        onSelectCensorMode: { _ in },
        onReset: {},
        onClose: {}
    )
    .padding(.vertical)
    .background(Color.black)
}

#Preview("Film tab") {
    previewShelf(tab: .film)
}

#Preview("Everything stacked") {
    previewShelf(
        tab: .beauty,
        filter: .cinestill800T,
        beauty: CameraBeauty(smoothing: 0.45, rosy: 0.2),
        censorMode: .mosaic
    )
}

#Preview("Privacy, unsupported") {
    previewShelf(tab: .privacy, filter: .original, canCensor: false)
}

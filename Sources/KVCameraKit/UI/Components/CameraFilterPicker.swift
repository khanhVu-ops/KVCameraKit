import SwiftUI

/// The filter strip: one chip per look, the selected one filled.
///
/// Names rather than thumbnails, and that is a deliberate trade. Live thumbnails are what
/// Instagram trained everyone to expect, and each one costs a scaled render of the current
/// frame per filter per frame — five extra draws at 30 fps to decorate a strip that is open
/// for two seconds. The viewfinder behind it is already showing the look at full size, which
/// is the only preview that matters.
///
/// Behind a toggle rather than always on screen, because the bottom of this screen already
/// carries a zoom pill, a mode switcher and a shutter row, and a strip that ran off the edge
/// of a small phone is a bug this repo has already had once.
struct CameraFilterPicker: View {

    let filters: [CameraFilter]
    let selectedID: String
    let onSelect: (CameraFilter) -> Void

    @Environment(\.cameraTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters) { filter in
                    let isSelected = filter.id == selectedID

                    Button {
                        onSelect(filter)
                    } label: {
                        Text(filter.title)
                            .font(theme.bodyStrongFont)
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background {
                                Capsule().fill(isSelected ? Color.yellow : Color.white.opacity(0.12))
                            }
                            // The strip scrolls, so a chip must keep its own width rather than
                            // being compressed to fit — the mode switcher lost `DIGITALIZAR`
                            // to exactly that.
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background {
            Capsule().fill(.ultraThinMaterial)
        }
        .clipShape(Capsule())
        // Bounded, so a long translation cannot push the strip across the whole screen.
        .frame(maxWidth: 320)
    }
}

#Preview("Filter picker") {
    VStack(spacing: 16) {
        CameraFilterPicker(filters: CameraFilter.all, selectedID: "original", onSelect: { _ in })
        CameraFilterPicker(filters: CameraFilter.all, selectedID: "mono", onSelect: { _ in })
        // One filter is not a choice; the screen hides the strip, but the component must not
        // fall over if it is handed one anyway.
        CameraFilterPicker(filters: [.original], selectedID: "original", onSelect: { _ in })
    }
    .padding()
    .background(Color.black)
}

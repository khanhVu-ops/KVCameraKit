import SwiftUI

extension View {

    /// Presents a `CameraAlert` held in the ViewModel's state.
    ///
    /// The package cannot use the host's `AlertState` modifier, and the binding is the
    /// reason this is worth wrapping at all: a discarded alert whose state is never
    /// cleared cannot be shown a second time, so the dismiss action must not be
    /// forgettable.
    func cameraAlert(_ alert: CameraAlert?, onDismiss: @escaping () -> Void) -> some View {
        self.alert(item: Binding(get: { alert }, set: { if $0 == nil { onDismiss() } })) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("Close"), action: onDismiss)
            )
        }
    }
}

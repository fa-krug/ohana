import SwiftUI

/// The Cancel button of an editor sheet (`ToolbarItem(placement: .cancellationAction)`): with
/// unsaved changes it asks before throwing them away. Pair it with `.discardGuard(hasChanges:)`
/// on the sheet's content, so the sheet can't be swiped away with them either.
struct CancelButton: View {
    var title: LocalizedStringKey = "Cancel"
    let hasChanges: Bool
    /// Runs before the sheet closes (e.g. a draft to reset).
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    var body: some View {
        Button(title, role: .cancel) {
            if hasChanges {
                asking = true
            } else {
                onCancel()
                dismiss()
            }
        }
        .keyboardShortcut(.cancelAction)
        .confirmationDialog("Discard your changes?", isPresented: $asking, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                onCancel()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }
}

extension View {
    /// An editor sheet with unsaved changes can't be swiped away; Cancel asks (`CancelButton`).
    func discardGuard(hasChanges: Bool) -> some View {
        interactiveDismissDisabled(hasChanges)
    }
}

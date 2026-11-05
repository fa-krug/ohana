import SwiftUI

/// The Cancel button of an editor sheet (`ToolbarItem(placement: .cancellationAction)`): with
/// unsaved changes it asks before throwing them away. Pair it with `.discardGuard(hasChanges:)`
/// on the sheet's content, so the sheet can't be swiped away with them either; the guard also
/// asks the question: a dialog hung on a toolbar item never shows on the Mac, where a sheet's
/// toolbar is its bottom bar.
struct CancelButton: View {
    var title: LocalizedStringKey = "Cancel"
    let hasChanges: Bool
    /// Runs before the sheet closes (e.g. a draft to reset).
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.discardChanges) private var discardChanges
    @State private var asking = false

    var body: some View {
        Button(title, role: .cancel) {
            if !hasChanges {
                onCancel()
                dismiss()
            } else if let discardChanges {
                discardChanges.ask(onCancel)
            } else {
                asking = true
            }
        }
        .keyboardShortcut(.cancelAction)
        // Without a guard around the sheet (not on the Mac, see above).
        .confirmationDialog("Discard your changes?", isPresented: $asking, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                onCancel()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }
}

/// `CancelButton` asking the sheet's `discardGuard` to confirm: what to run before it closes.
struct DiscardChangesAction {
    let ask: (_ onDiscard: @escaping () -> Void) -> Void
}

extension EnvironmentValues {
    @Entry var discardChanges: DiscardChangesAction?
}

extension View {
    /// An editor sheet with unsaved changes can't be swiped away; Cancel asks (`CancelButton`).
    func discardGuard(hasChanges: Bool) -> some View {
        modifier(DiscardGuard(hasChanges: hasChanges))
    }
}

private struct DiscardGuard: ViewModifier {
    let hasChanges: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @State private var onDiscard: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .environment(\.discardChanges, DiscardChangesAction {
                onDiscard = $0
                asking = true
            })
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Discard your changes?", isPresented: $asking, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) {
                    onDiscard()
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            }
    }
}

import Foundation
import WidgetKit

/// Keeps the widgets (OhanaWidgets) in step with the app: which server and family they show
/// (`WidgetSource` in the App Group: the family selected here; nothing while signed out), and a
/// reload when the family's data changed here or the app leaves the screen. The widgets load the
/// overview themselves (`WidgetLoader`).
enum WidgetSync {
    /// Tells the widgets what to show; they reload when it changed.
    static func show(_ source: WidgetSource?) {
        if WidgetStore.saveSource(source) { reload() }
    }

    static func reload() {
        pending?.cancel()
        pending = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A reload a moment later, once for a burst of changes (`FamilyContext.didChange`).
    static func reloadSoon() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private static var pending: Task<Void, Never>?
}

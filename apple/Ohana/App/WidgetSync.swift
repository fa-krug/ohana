import Foundation
import WidgetKit

/// Keeps the widgets (OhanaWidgets) in step with the app. They show the family the app shows,
/// read with the server and token from the Keychain (`SharedConnection`); this tells them which
/// modules the server has off and reloads them when the family's data changed here, the family
/// switched, the app signed out or left the screen. The widgets load the overview themselves
/// (`WidgetLoader`).
enum WidgetSync {
    /// The modules the server has off (`WidgetStore`), and a reload.
    static func show(disabledModules: [String]) {
        WidgetStore.saveDisabledModules(disabledModules)
        reloadSoon()
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

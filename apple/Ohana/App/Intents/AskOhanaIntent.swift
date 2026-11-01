import AppIntents
import Foundation
import Observation

/// "Ask Ohana" for Siri, Shortcuts, Spotlight and the Action button: opens the app on a new chat
/// with the assistant, with the question sent when one is given.
struct AskOhanaIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Ohana"
    static let description = IntentDescription("Asks the family assistant in Ohana.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var prompt: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        // A shortcut can't be hidden at runtime: one for a server without the assistant says so.
        guard AssistantInbox.shared.available else { throw AskOhanaError.assistantOff }
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        AssistantInbox.shared.post(text?.isEmpty == false ? text : nil)
        return .result()
    }
}

/// Why "Ask Ohana" can't help, as Siri and Shortcuts say it.
nonisolated enum AskOhanaError: Error, CustomLocalizedStringResourceConvertible {
    /// The connected server has the assistant turned off.
    case assistantOff

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .assistantOff: "The assistant is turned off on your Ohana server."
        }
    }
}

struct OhanaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOhanaIntent(),
            phrases: ["Ask \(.applicationName)", "Open the \(.applicationName) assistant"],
            shortTitle: "Ask Ohana",
            systemImageName: "sparkles"
        )
        // String parameters can't be part of a phrase: Siri asks for the item, the title, the page.
        AppShortcut(
            intent: AddShoppingReminderIntent(),
            phrases: [
                "Add to the shopping list in \(.applicationName)",
                "Add something to the \(.applicationName) shopping list",
                "Put something on the \(.applicationName) shopping list",
            ],
            shortTitle: "Add to Shopping List",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: AddEventIntent(),
            phrases: [
                "Add an event in \(.applicationName)",
                "Add an event to the \(.applicationName) calendar",
                "New \(.applicationName) event",
            ],
            shortTitle: "Add Event",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: ImportRecipeIntent(),
            phrases: [
                "Import a recipe into \(.applicationName)",
                "Save a recipe in \(.applicationName)",
            ],
            shortTitle: "Import Recipe",
            systemImageName: "fork.knife"
        )
    }
}

/// Requests from outside the app (the intent) for the shell's family to pick up.
@Observable
final class AssistantInbox {
    static let shared = AssistantInbox()

    struct Pending: Equatable {
        let id = UUID()
        let prompt: String?
    }

    private(set) var pending: Pending?
    /// Whether the connected server has the assistant on (`AppModel.serverInfo`); true while
    /// that isn't known.
    var available = true

    func post(_ prompt: String?) { pending = Pending(prompt: prompt) }

    func take() -> Pending? {
        defer { pending = nil }
        return pending
    }
}

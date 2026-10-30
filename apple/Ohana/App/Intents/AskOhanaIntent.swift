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
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        AssistantInbox.shared.post(text?.isEmpty == false ? text : nil)
        return .result()
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

    func post(_ prompt: String?) { pending = Pending(prompt: prompt) }

    func take() -> Pending? {
        defer { pending = nil }
        return pending
    }
}

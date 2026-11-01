import AppIntents
import Foundation
import Observation

/// "Scan Letter" for Spotlight (the Home Screen search), Siri, Shortcuts and the Action button:
/// opens the app with the letter scanner over whatever it shows, for the family on screen. Works
/// without a server too (the demo): the PDF is saved on the device.
struct ScanLetterIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan Letter"
    static let description = IntentDescription("Scans a letter and saves it as a PDF, or has the assistant suggest the dates and tasks in it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LetterScanInbox.shared.post()
        return .result()
    }
}

/// The intent's request for the shell (`ShellLetterScan`) to pick up once it shows.
@Observable
final class LetterScanInbox {
    static let shared = LetterScanInbox()

    private(set) var pending: UUID?

    func post() { pending = UUID() }

    /// Whether there was a request (it's cleared).
    func take() -> Bool {
        defer { pending = nil }
        return pending != nil
    }
}

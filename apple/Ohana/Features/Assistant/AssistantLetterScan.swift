import Foundation

// A scanned letter for the assistant (the scan itself: Features/Letters), from the composer's
// attach menu: only its text goes to the assistant, as a text attachment with a prompt asking for
// the events, tasks and deadlines in it; its answer is a suggestions card
// (`AssistantSuggestionsCard`). The shell's letter scan doesn't open a chat: its review lists what
// the server finds in the text itself (`LetterFind.swift`). Both read the text with `text(_:)`.

/// What a scanned letter sends to the assistant: its text as a file and the request.
enum AssistantLetter {
    static var attachmentName: String { String(localized: "Scanned letter.txt") }

    static var prompt: String {
        String(localized: "I scanned this letter. Suggest the events, tasks and deadlines in it so I can add them.")
    }

    static func attachment(_ text: String) -> AssistantPendingAttachment {
        AssistantPendingAttachment(kind: "file", name: attachmentName, text: AssistantAttachments.cut(text, max: LetterScan.maxText))
    }

    /// The pages' text in reading order: on each page the lines top to bottom, pages separated by
    /// a blank line; "" when there is none.
    static func text(_ pages: [ScanPage]) -> String {
        text(pages: pages.map { $0.lines.map(\.piece) })
    }

    /// The text of the pages' pieces: on each page the lines top to bottom (pieces side by side
    /// on one line), pages separated by a blank line; "" when there is none.
    static func text(pages: [[ReceiptTextPiece]]) -> String {
        pages.map { ReceiptParser.lines($0).joined(separator: "\n") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

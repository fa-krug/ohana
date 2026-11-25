import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A chat (or one answer of it) as Markdown for the clipboard (web: transcript.ts): what the chat
/// shows, plus every tool call with its arguments and its result.
enum AssistantTranscript {
    static func markdown(_ items: [AssistantItem], result: (String) -> String? = { _ in nil }) -> String {
        var blocks: [String] = []
        for item in items where item.isVisible {
            if let block = block(item, first: blocks.isEmpty, result: result) { blocks.append(block) }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// One item of the chat as Markdown (nil for what the chat doesn't show).
    private static func block(_ item: AssistantItem, first: Bool, result: (String) -> String?) -> String? {
        saidBlock(item, first: first, result: result) ?? cardBlock(item)
    }

    /// What the family wrote, what the model answered, and what it called for it.
    private static func saidBlock(_ item: AssistantItem, first: Bool, result: (String) -> String?) -> String? {
        switch item {
        case let .user(text, attachments):
            let lines = ["**\(you):** \(text)"] + attachments.map { "📎 \($0.name)" }
            let message = lines.joined(separator: "\n")
            // A new question starts with a line of its own, so it reads apart from the answer above.
            first ? message : "---\n\n" + message
        case let .assistant(text, sources): AssistantSourceMarkers.transcript(text, sources: sources)
        case let .tool(tool): toolBlock(tool, result: result)
        case let .change(change): "✅ \(change.summary)" + (change.undone ? " (\(String(localized: "Undone")))" : "")
        case let .question(asked): questionBlock(asked)
        case .compacted: "*\(String(localized: "Earlier messages condensed for the model"))*"
        case let .error(text): "⚠️ \(text)"
        default: nil
        }
    }

    /// The cards that wait for the family to apply them, and the pages to look at.
    private static func cardBlock(_ item: AssistantItem) -> String? {
        switch item {
        case let .reminders(edit): remindersBlock(edit)
        case let .calendar(edit): calendarBlock(edit)
        case let .suggestions(edit): suggestionsBlock(edit)
        case let .notes(edit): notesBlock(edit)
        case let .memories(edit): memoriesBlock(edit)
        case let .pages(request): pagesBlock(request)
        default: nil
        }
    }

    /// The word for the family member who wrote a message.
    private static var you: String { String(localized: "You") }

    /// A tool call: what it was, its arguments and what came back.
    private static func toolBlock(_ tool: AssistantToolCall, result: (String) -> String?) -> String {
        let label = [AssistantToolLabels.label(tool), AssistantToolLabels.detail(tool)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let status = tool.status == "running" ? "…" : tool.status == "ok" ? "✓" : "✗"
        let args = pretty(JSONValue.object(tool.args)) ?? "{}"
        let answer = result(tool.id).map { fence(prettyText($0), lang: "json") } ?? tool.summary ?? ""
        return ["**🔧 \(label)** \(status)", fence("\(tool.name) \(args)"), answer]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The question the model asked: its options with what was picked, and its answer.
    private static func questionBlock(_ asked: AssistantQuestion) -> String {
        let picked = asked.answer?.selected ?? []
        let marks = asked.options.map { "- [\(picked.contains($0) ? "x" : " ")] \($0)" }
        var lines = ["**❓ \(asked.question)**"] + marks
        if let text = asked.answer?.text {
            lines.append("**\(you):** \(text)")
        } else if asked.skipped {
            lines.append("(\(String(localized: "Not answered")))")
        }
        return lines.joined(separator: "\n")
    }

    /// The Reminders an edit card waits to apply.
    private static func remindersBlock(_ edit: AssistantRemindersEdit) -> String {
        var lines = ["**☑️ \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let done = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
            let text = AssistantReminderOpLine.make(op).text
            lines.append("- " + text + (done.map(Self.mark) ?? ""))
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// The calendar events an edit card waits to apply.
    private static func calendarBlock(_ edit: AssistantCalendarEdit) -> String {
        var lines = ["**📅 \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let done = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
            let line = AssistantCalendarOpLine.make(op)
            let text = [line.text, line.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append("- " + text + (done.map(Self.mark) ?? ""))
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// The events, tasks and deadlines found in a letter.
    private static func suggestionsBlock(_ edit: AssistantSuggestions) -> String {
        var lines = ["**📄 \(edit.summary)**"]
        if let source = edit.source { lines.append("*\(source)*") }
        for (index, op) in edit.ops.enumerated() {
            let done = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
            let line = AssistantSuggestionLine.make(op)
            let text = [line.title, line.when, line.detail].compactMap { $0 }.filter { !$0.isEmpty }
            lines.append("- " + text.joined(separator: " · ") + (done.map(Self.mark) ?? ""))
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// The notes for the knowledge folder an edit card waits to write.
    private static func notesBlock(_ edit: AssistantNotesEdit) -> String {
        var lines = ["**📝 \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let done = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
            let line = AssistantNoteOpLine.make(op)
            let text = [line.text, line.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append("- " + text + (done.map(Self.mark) ?? ""))
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// What the assistant offers to remember, change or forget.
    private static func memoriesBlock(_ edit: AssistantMemoriesEdit) -> String {
        var lines = ["**🧠 \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let done = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
            let text = op.action == .update ? "\(op.old?.text ?? "") → \(op.text)" : op.text
            lines.append("- " + (op.action == .remove ? "~~\(text)~~" : text) + (done.map(Self.mark) ?? ""))
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// The pages of a document the assistant wants to look at.
    private static func pagesBlock(_ request: AssistantPagesRequest) -> String {
        var lines = ["**🖼️ \(request.summary)**", request.path]
        if let outcome = request.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// How an op went: ✓, – (left out) or ✗ with the error.
    private static func mark(_ result: AssistantReminderResult) -> String {
        if result.ok { return " ✓" }
        if result.isDeclined { return " –" }
        return " ✗ \(result.error ?? "")"
    }

    private static func pretty(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// JSON pretty-printed; anything else (e.g. a result cut short) as it is.
    private static func prettyText(_ text: String) -> String {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return text }
        return pretty(value) ?? text
    }

    /// A fenced code block that can't be closed early by backticks in its text.
    private static func fence(_ text: String, lang: String = "") -> String {
        var longest = 0, run = 0
        for ch in text {
            run = ch == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return "\(ticks)\(lang)\n\(text)\n\(ticks)"
    }

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

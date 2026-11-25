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
        var out: [String] = []
        for item in items where item.isVisible {
            guard let block = block(for: item, result: result) else { continue }
            out.append(out.isEmpty ? block : "---\n\n" + block)
        }
        return out.joined(separator: "\n\n")
    }

    /// "You", as the transcript labels what the user wrote.
    private static var you: String { String(localized: "You") }

    /// One chat entry as Markdown; nil for what the transcript leaves out. The edits (questions,
    /// reminders, calendar, suggestions, notes, memories, pages) answer in `editBlock`.
    private static func block(for item: AssistantItem, result: (String) -> String?) -> String? {
        switch item {
        case let .user(text, attachments):
            return userBlock(text: text, attachments: attachments)
        case let .assistant(text, sources):
            return AssistantSourceMarkers.transcript(text, sources: sources)
        case let .tool(tool):
            return toolBlock(tool, result: result)
        case let .change(change):
            return "✅ \(change.summary)" + (change.undone ? " (\(String(localized: "Undone")))" : "")
        case .compacted:
            return "*\(String(localized: "Earlier messages condensed for the model"))*"
        case let .error(text):
            return "⚠️ \(text)"
        case .unknown:
            return nil
        default:
            return editBlock(for: item)
        }
    }

    /// The cards that wait for the user: one question, or an edit of reminders, calendars,
    /// suggestions, notes, memories, or the pages asked for.
    private static func editBlock(for item: AssistantItem) -> String? {
        switch item {
        case let .question(ask):
            return questionBlock(ask)
        case let .reminders(edit):
            return remindersBlock(edit)
        case let .calendar(edit):
            return calendarBlock(edit)
        case let .suggestions(edit):
            return suggestionsBlock(edit)
        case let .notes(edit):
            return notesBlock(edit)
        case let .memories(edit):
            return memoriesBlock(edit)
        case let .pages(request):
            return pagesBlock(request)
        default:
            return nil
        }
    }

    private static func userBlock(text: String, attachments: [AssistantAttachmentRef]) -> String {
        let lines = ["**\(you):** \(text)"] + attachments.map { "📎 \($0.name)" }
        return lines.joined(separator: "\n")
    }

    private static func toolBlock(_ tool: AssistantToolCall, result: (String) -> String?) -> String {
        let label = [AssistantToolLabels.label(tool), AssistantToolLabels.detail(tool)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let status = tool.status == "running" ? "…" : tool.status == "ok" ? "✓" : "✗"
        let args = pretty(JSONValue.object(tool.args)) ?? "{}"
        let answer = result(tool.id).map { fence(prettyText($0), lang: "json") } ?? tool.summary ?? ""
        return ["**🔧 \(label)** \(status)", fence("\(tool.name) \(args)"), answer]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func questionBlock(_ ask: AssistantQuestion) -> String {
        let picked = ask.answer?.selected ?? []
        var lines = ["**❓ \(ask.question)**"] + ask.options.map { "- [\(picked.contains($0) ? "x" : " ")] \($0)" }
        if let text = ask.answer?.text { lines.append("**\(you):** \(text)") }
        else if ask.skipped { lines.append("(\(String(localized: "Not answered")))") }
        return lines.joined(separator: "\n")
    }

    private static func remindersBlock(_ edit: AssistantRemindersEdit) -> String {
        var lines = ["**☑️ \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let mark = resultMark(edit.answer?.results, at: index)
            lines.append("- " + AssistantReminderOpLine.make(op).text + mark)
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    private static func calendarBlock(_ edit: AssistantCalendarEdit) -> String {
        var lines = ["**📅 \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let mark = resultMark(edit.answer?.results, at: index)
            let line = AssistantCalendarOpLine.make(op)
            let text = [line.text, line.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append("- " + text + mark)
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    private static func suggestionsBlock(_ edit: AssistantSuggestions) -> String {
        var lines = ["**📄 \(edit.summary)**"]
        if let source = edit.source { lines.append("*\(source)*") }
        for (index, op) in edit.ops.enumerated() {
            let mark = resultMark(edit.answer?.results, at: index)
            let line = AssistantSuggestionLine.make(op)
            let text = [line.title, line.when, line.detail].compactMap { $0 }.filter { !$0.isEmpty }
            lines.append("- " + text.joined(separator: " · ") + mark)
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    private static func notesBlock(_ edit: AssistantNotesEdit) -> String {
        var lines = ["**📝 \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let mark = resultMark(edit.answer?.results, at: index)
            let line = AssistantNoteOpLine.make(op)
            let text = [line.text, line.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append("- " + text + mark)
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    private static func memoriesBlock(_ edit: AssistantMemoriesEdit) -> String {
        var lines = ["**🧠 \(edit.summary)**"]
        for (index, op) in edit.ops.enumerated() {
            let mark = resultMark(edit.answer?.results, at: index)
            let text = op.action == .update ? "\(op.old?.text ?? "") → \(op.text)" : op.text
            let prefix = op.action == .remove ? "~~\(text)~~" : text
            lines.append("- " + prefix + mark)
        }
        if let outcome = edit.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    private static func pagesBlock(_ request: AssistantPagesRequest) -> String {
        var lines = ["**🖼️ \(request.summary)**", request.path]
        if let outcome = request.outcome { lines.append("(\(outcome))") }
        return lines.joined(separator: "\n")
    }

    /// The mark of the op at `index` in an edit's results, "" while it has none (or none for it).
    private static func resultMark(_ results: [AssistantReminderResult]?, at index: Int) -> String {
        let one = results.flatMap { index < $0.count ? $0[index] : nil }
        return one.map(Self.mark) ?? ""
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

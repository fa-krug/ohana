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
        let you = String(localized: "You")
        var out: [String] = []
        for item in items where item.isVisible {
            switch item {
            case let .user(text, attachments):
                let lines = ["**\(you):** \(text)"] + attachments.map { "📎 \($0.name)" }
                let block = lines.joined(separator: "\n")
                out.append(out.isEmpty ? block : "---\n\n" + block)
            case let .assistant(text):
                out.append(text)
            case let .tool(tool):
                let label = [AssistantToolLabels.label(tool), AssistantToolLabels.detail(tool)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                let status = tool.status == "running" ? "…" : tool.status == "ok" ? "✓" : "✗"
                let args = pretty(JSONValue.object(tool.args)) ?? "{}"
                let answer = result(tool.id).map { fence(prettyText($0), lang: "json") } ?? tool.summary ?? ""
                out.append(["**🔧 \(label)** \(status)", fence("\(tool.name) \(args)"), answer]
                    .filter { !$0.isEmpty }.joined(separator: "\n"))
            case let .change(change):
                out.append("✅ \(change.summary)" + (change.undone ? " (\(String(localized: "Undone")))" : ""))
            case let .question(q):
                let picked = q.answer?.selected ?? []
                var lines = ["**❓ \(q.question)**"] + q.options.map { "- [\(picked.contains($0) ? "x" : " ")] \($0)" }
                if let text = q.answer?.text { lines.append("**\(you):** \(text)") }
                else if q.skipped { lines.append("(\(String(localized: "Not answered")))") }
                out.append(lines.joined(separator: "\n"))
            case let .reminders(edit):
                var lines = ["**☑️ \(edit.summary)**"]
                for (index, op) in edit.ops.enumerated() {
                    let result = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
                    let mark = result.map(Self.mark) ?? ""
                    lines.append("- " + AssistantReminderOpLine.make(op).text + mark)
                }
                if let outcome = edit.outcome { lines.append("(\(outcome))") }
                out.append(lines.joined(separator: "\n"))
            case let .calendar(edit):
                var lines = ["**📅 \(edit.summary)**"]
                for (index, op) in edit.ops.enumerated() {
                    let result = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
                    let mark = result.map(Self.mark) ?? ""
                    let line = AssistantCalendarOpLine.make(op)
                    lines.append("- " + ([line.text, line.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) + mark)
                }
                if let outcome = edit.outcome { lines.append("(\(outcome))") }
                out.append(lines.joined(separator: "\n"))
            case let .suggestions(edit):
                var lines = ["**📄 \(edit.summary)**"]
                if let source = edit.source { lines.append("*\(source)*") }
                for (index, op) in edit.ops.enumerated() {
                    let result = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
                    let line = AssistantSuggestionLine.make(op)
                    let text = [line.title, line.when, line.detail].compactMap { $0 }.filter { !$0.isEmpty }
                    lines.append("- " + text.joined(separator: " · ") + (result.map(Self.mark) ?? ""))
                }
                if let outcome = edit.outcome { lines.append("(\(outcome))") }
                out.append(lines.joined(separator: "\n"))
            case .compacted:
                out.append("*\(String(localized: "Earlier messages condensed for the model"))*")
            case let .error(text):
                out.append("⚠️ \(text)")
            case .unknown:
                break
            }
        }
        return out.joined(separator: "\n\n")
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

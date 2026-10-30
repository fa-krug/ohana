import SwiftUI

/// A block of an answer in Markdown (web: components/assistant/markdown.tsx): paragraphs,
/// headings, lists, tables and code; the inline parts (bold, italics, code, links) go through
/// `AttributedString(markdown:)`.
enum AssistantMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case list(ordered: Bool, items: [String])
    case code(String)
    case table(header: [String], alignments: [HorizontalAlignment?], rows: [[String]])

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.paragraph(x), .paragraph(y)), let (.heading(x), .heading(y)), let (.code(x), .code(y)): x == y
        case let (.list(o1, i1), .list(o2, i2)): o1 == o2 && i1 == i2
        case let (.table(h1, _, r1), .table(h2, _, r2)): h1 == h2 && r1 == r2
        default: false
        }
    }

    private static let listItem = /^\s*([-*•+]|\d+[.)])\s+/
    private static let headingLine = /^(#{1,6})\s+(.*)$/
    private static let tableRule = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

    /// A table row's cells (`\|` is a literal pipe).
    static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        let marker = "\u{0}"
        return row.replacingOccurrences(of: "\\|", with: marker)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: marker, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        lines[i].contains("|") && i + 1 < lines.count && lines[i + 1].wholeMatch(of: tableRule) != nil
            && cells(lines[i + 1]).count == cells(lines[i]).count
    }

    private static func isListItem(_ line: String) -> Bool { line.prefixMatch(of: listItem) != nil }

    private static func alignment(_ rule: String) -> HorizontalAlignment? {
        let left = rule.hasPrefix(":"), right = rule.hasSuffix(":")
        return left && right ? .center : right ? .trailing : left ? .leading : nil
    }

    static func parse(_ text: String) -> [AssistantMarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var blocks: [AssistantMarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            if line.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let m = line.wholeMatch(of: headingLine) {
                blocks.append(.heading(String(m.2)))
                i += 1
                continue
            }
            if isListItem(line) {
                let ordered = line.trimmingCharacters(in: .whitespaces).first?.isNumber == true
                var items: [String] = []
                while i < lines.count, isListItem(lines[i]) {
                    items.append(lines[i].replacing(listItem, maxReplacements: 1) { _ in "" })
                    i += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }
            if isTableStart(lines, i) {
                let header = cells(line)
                let alignments = cells(lines[i + 1]).map(alignment)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                continue
            }
            var para: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i].hasPrefix("```"),
                  lines[i].wholeMatch(of: headingLine) == nil, !isListItem(lines[i]), !isTableStart(lines, i) {
                para.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }
        return blocks
    }

    /// Inline Markdown (bold, italics, code, links); links only for http(s) and the app's own pages.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var s = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in s.runs {
            // The app's own pages (/f/{id}/…, e.g. a recipe the assistant saved) open in the app.
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? ""),
               !(link.scheme == nil && link.path.hasPrefix("/f/")) {
                s[run.range].link = nil
            }
        }
        return s
    }
}

/// An answer of the assistant, rendered from its Markdown.
struct AssistantMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AssistantMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(AssistantMarkdownBlock.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .heading(text):
            Text(AssistantMarkdownBlock.inline(text)).font(.headline)
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: ordered ? "\(index + 1)." : "•")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(AssistantMarkdownBlock.inline(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        case let .table(header, alignments, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
                            Text(AssistantMarkdownBlock.inline(cell)).bold()
                                .gridColumnAlignment(alignments.indices.contains(c) ? alignments[c] ?? .leading : .leading)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(header.indices, id: \.self) { c in
                                Text(AssistantMarkdownBlock.inline(row.indices.contains(c) ? row[c] : ""))
                            }
                        }
                    }
                }
                .font(.caption)
                .padding(.vertical, 4)
            }
        }
    }
}

import SwiftUI

/// An item of a list in an answer: its depth (0: the list's own items, 1: under one of them, …)
/// and, in a numbered list, its number as written.
nonisolated struct AssistantListItem: Equatable, Sendable {
    var text: String
    var level = 0
    var number: Int? = nil
}

/// A block of an answer in Markdown (web: components/assistant/markdown.tsx): paragraphs,
/// headings, lists, tables and code; the inline parts (bold, italics, code, links) go through
/// `AttributedString(markdown:)`. Pure, so answers can be read off the main thread
/// (`AssistantMarkdownCache.prewarm`).
nonisolated enum AssistantMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    case list([AssistantListItem])
    case code(String)
    case table(header: [String], alignments: [HorizontalAlignment?], rows: [[String]])

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.paragraph(x), .paragraph(y)), let (.heading(x), .heading(y)), let (.code(x), .code(y)): x == y
        case let (.list(x), .list(y)): x == y
        case let (.table(h1, _, r1), .table(h2, _, r2)): h1 == h2 && r1 == r2
        default: false
        }
    }

    // Not `Sendable` (its output type could be anything), but matching is safe from any thread.
    private nonisolated(unsafe) static let listItem = /^\s*([-*•+]|(\d+)[.)])\s+/
    private nonisolated(unsafe) static let headingLine = /^(#{1,6})\s+(.*)$/
    private nonisolated(unsafe) static let tableRule = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

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

    // The regexes only where they can match: they are slow, and every line of an answer is tried
    // against them several times, again with each piece of a streaming answer.

    private static func isListItem(_ line: String) -> Bool {
        guard let first = line.first(where: { !$0.isWhitespace }),
              first.isNumber || "-*•+".contains(first) else { return false }
        return line.prefixMatch(of: listItem) != nil
    }

    private static func heading(_ line: String) -> Substring? {
        guard line.hasPrefix("#") else { return nil }
        return line.wholeMatch(of: headingLine)?.2
    }

    private static func alignment(_ rule: String) -> HorizontalAlignment? {
        let left = rule.hasPrefix(":"), right = rule.hasSuffix(":")
        return left && right ? .center : right ? .trailing : left ? .leading : nil
    }

    /// The width of a line's indentation (a tab counts 4).
    private static func indent(_ line: String) -> Int {
        var width = 0
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// The list starting at `start`: its items with their depth (from their indentation: two
    /// spaces more than the item above go one deeper) and number, and the line after it. Blank
    /// lines between items (a "loose" list) don't end it while the next item is nested or of the
    /// first item's kind, so its numbers and spacing stay one list's.
    private static func listItems(_ lines: [String], from start: Int) -> ([AssistantListItem], Int) {
        var items: [AssistantListItem] = []
        var indents: [Int] = []  // the indentation of each open depth
        var i = start
        while i < lines.count {
            var line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count, isListItem(lines[j]), let first = items.first,
                      indent(lines[j]) >= (indents.first ?? 0) + 2
                        || (lines[j].prefixMatch(of: listItem)?.2 != nil) == (first.number != nil) else { break }
                i = j
                line = lines[i]
            }
            guard let match = line.prefixMatch(of: listItem) else { break }
            let width = indent(line)
            while let last = indents.last, width < last { indents.removeLast() }
            if let last = indents.last, width < last + 2 {} else { indents.append(width) }
            items.append(AssistantListItem(
                text: String(line[match.range.upperBound...]),
                level: max(indents.count - 1, 0),
                number: match.2.flatMap { Int($0) }
            ))
            i += 1
        }
        return (items, i)
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
            if let title = heading(line) {
                blocks.append(.heading(String(title)))
                i += 1
                continue
            }
            if isListItem(line) {
                let (items, next) = listItems(lines, from: i)
                blocks.append(.list(items))
                i = next
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
                  heading(lines[i]) == nil, !isListItem(lines[i]), !isTableStart(lines, i) {
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
        guard var s = try? AttributedString(markdown: text, options: options) else {
            return AssistantSourceMarkers.chips(in: AttributedString(text))
        }
        for run in s.runs {
            // The app's own pages (/f/{id}/…, e.g. a recipe the assistant saved) open in the app.
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? ""),
               !(link.scheme == nil && link.path.hasPrefix("/f/")) {
                s[run.range].link = nil
            }
        }
        // The source chips (`AssistantSourceMarkers.prepare`), after the links are sorted out.
        return AssistantSourceMarkers.chips(in: s)
    }
}

/// Answers already read, so none is read twice: an answer's blocks by its text and sources, each
/// inline part (paragraph, list item, cell) by its text. A streaming answer's finished paragraphs
/// aren't read again with each new piece of text, nor an answer drawn again (a chat opened again,
/// the panel built again). Bounded by the length of the texts kept. Usable from any thread
/// (`NSCache` is thread-safe): a chat's answers are read ahead off the main thread (`prewarm`).
nonisolated enum AssistantMarkdownCache {
    private final class Box<Value: Sendable>: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static func cache<Value>(_: Value.Type) -> NSCache<NSString, Box<Value>> {
        let cache = NSCache<NSString, Box<Value>>()
        cache.totalCostLimit = 4_000_000
        return cache
    }

    private nonisolated(unsafe) static let blockCache = cache([AssistantMarkdownBlock].self)
    private nonisolated(unsafe) static let inlineCache = cache(AttributedString.self)

    private static func blockKey(_ text: String, sources: [AssistantSource]) -> NSString {
        (sources.map(\.ref).joined(separator: " ") + "\u{0}" + text) as NSString
    }

    /// `AssistantMarkdownBlock.parse` of the text prepared for its sources.
    static func blocks(_ text: String, sources: [AssistantSource]) -> [AssistantMarkdownBlock] {
        let key = blockKey(text, sources: sources)
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let blocks = AssistantMarkdownBlock.parse(AssistantSourceMarkers.prepare(text, sources: sources))
        blockCache.setObject(Box(blocks), forKey: key, cost: key.length)
        return blocks
    }

    /// `AssistantMarkdownBlock.inline`.
    static func inline(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let inline = AssistantMarkdownBlock.inline(text)
        inlineCache.setObject(Box(inline), forKey: key, cost: key.length)
        return inline
    }

    /// Reads a chat's answers off the main thread, as `AssistantMarkdownView` asks for them (the
    /// blocks, then each paragraph's, heading's, list item's and cell's inline text), so drawing
    /// the chat finds them read. Only the answers the chat draws when it opens: those among its
    /// last `AssistantItemWindow.page` visible items. Returns the answers' texts it read (tests:
    /// the cache itself may let go of entries at any time).
    @concurrent @discardableResult
    static func prewarm(_ items: [AssistantItem]) async -> [String] {
        var read: [String] = []
        for item in items.filter(\.isVisible).suffix(AssistantItemWindow.page) {
            guard case let .assistant(text, sources) = item else { continue }
            if Task.isCancelled { break }
            for block in blocks(text, sources: sources) {
                for part in inlineParts(block) { _ = inline(part) }
            }
            read.append(text)
        }
        return read
    }

    /// The inline texts `AssistantMarkdownView` draws for a block (a row's missing cells as "").
    static func inlineParts(_ block: AssistantMarkdownBlock) -> [String] {
        switch block {
        case let .paragraph(text), let .heading(text): [text]
        case let .list(items): items.map(\.text)
        case .code: []
        case let .table(header, _, rows):
            header + rows.flatMap { row in header.indices.map { row.indices.contains($0) ? row[$0] : "" } }
        }
    }
}

/// An answer of the assistant, rendered from its Markdown: its source markers as chips (those
/// without a source, and one still being written, hidden).
struct AssistantMarkdownView: View {
    let text: String
    var sources: [AssistantSource] = []

    // Room to read: paragraphs, list items and headings apart, lines a little further apart than
    // the system's, nested items indented. All grow with the text size.
    @ScaledMetric(relativeTo: .body) private var blockSpacing: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var itemSpacing: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var headingSpacing: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var levelIndent: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(AssistantMarkdownCache.blocks(text, sources: sources).enumerated()), id: \.offset) { index, block in
                blockView(block)
                    // A heading after something belongs to what follows it.
                    .padding(.top, index > 0 && block.isHeading ? headingSpacing : 0)
            }
        }
        .lineHeight(.multiple(factor: 1.2))
        // On the Mac only: on iOS the answer's menu offers "Select Text" instead.
        #if os(macOS)
        .textSelection(.enabled)
        #endif
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockView(_ block: AssistantMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(AssistantMarkdownCache.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case let .heading(text):
            Text(AssistantMarkdownCache.inline(text))
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: itemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: Self.marker(item))
                            .monospacedDigit()
                            .frame(minWidth: markerWidth, alignment: item.number == nil ? .center : .trailing)
                        Text(AssistantMarkdownCache.inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(min(item.level, 3)) * levelIndent)
                }
            }
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: AssistantSourceMarkers.stripPlaceholders(code))
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
            }
            // Moves sideways only when the code is wider than the column: the chat never wiggles.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        case let .table(header, alignments, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { c, cell in
                            Text(AssistantMarkdownCache.inline(cell)).bold()
                                .gridColumnAlignment(alignments.indices.contains(c) ? alignments[c] ?? .leading : .leading)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(header.indices, id: \.self) { c in
                                Text(AssistantMarkdownCache.inline(row.indices.contains(c) ? row[c] : ""))
                            }
                        }
                    }
                }
                .font(.caption)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    /// A numbered item's number, else a bullet by depth.
    private static func marker(_ item: AssistantListItem) -> String {
        if let number = item.number { return "\(number)." }
        return ["•", "◦", "▪︎"][min(item.level, 2)]
    }
}

private extension AssistantMarkdownBlock {
    var isHeading: Bool {
        if case .heading = self { true } else { false }
    }
}

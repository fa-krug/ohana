import CoreGraphics
import Foundation
import ImageIO

// The pure parts of reading a scanned page (`KnowledgeOCR`): which way the page is turned and a
// page as text with its tables as Markdown. Everything here is pure, so it's tested without Vision.

/// A cell of a recognized table: its first row and column (a spanning cell is put there once).
nonisolated struct KnowledgeOCRCell: Equatable, Sendable {
    var row: Int
    var column: Int
    var text: String
}

/// Which way a page is turned, from the baselines of the text read upright.
nonisolated enum KnowledgeOCROrientation {
    /// The share of the text (by characters) that must run one way for the page to count as
    /// turned that way.
    static let minShare = 0.6
    /// How far (in degrees) a baseline may be from a direction and still count for it.
    static let tolerance = 25.0

    /// A line's baseline angle in degrees (from its bottom left to its bottom right, in pixels,
    /// y up: 0 is upright text, −90 text running down the page) and its number of characters.
    struct Sample: Equatable, Sendable {
        var angle: Double
        var weight: Int
    }

    /// The angle of a baseline from `left` to `right` (normalized points) on an image of `size`.
    static func angle(from left: CGPoint, to right: CGPoint, size: CGSize) -> Double {
        let dx = Double((right.x - left.x) * size.width), dy = Double((right.y - left.y) * size.height)
        return atan2(dy, dx) * 180 / .pi
    }

    /// The orientation (as Vision takes it) that reads the page upright: text running down
    /// (−90°) → `.left`, running up (+90°) → `.right`, upside down (180°) → `.down`; `.up` unless
    /// at least `minShare` of the characters agree on one of them.
    static func vote(_ samples: [Sample]) -> CGImagePropertyOrientation {
        var total = 0
        var votes: [CGImagePropertyOrientation: Int] = [:]
        for sample in samples where sample.weight > 0 {
            total += sample.weight
            if let way = direction(sample.angle) { votes[way, default: 0] += sample.weight }
        }
        guard total > 0 else { return .up }
        for way in [CGImagePropertyOrientation.left, .right, .down] {
            if Double(votes[way] ?? 0) >= minShare * Double(total) { return way }
        }
        return .up
    }

    private static func direction(_ angle: Double) -> CGImagePropertyOrientation? {
        if abs(angle + 90) <= tolerance { return .left }
        if abs(angle - 90) <= tolerance { return .right }
        if abs(abs(angle) - 180) <= tolerance { return .down }
        return nil
    }
}

/// A page's text with its tables as Markdown, in reading order.
nonisolated enum KnowledgeOCRLayout {
    /// A table as Markdown: the first row as its header; line breaks inside a cell become spaces,
    /// "|" is escaped; rows and columns with nothing in them are left out. Empty for no text.
    static func markdownTable(_ cells: [KnowledgeOCRCell]) -> String {
        let filled = cells.map { cell in
            KnowledgeOCRCell(row: cell.row, column: cell.column, text: clean(cell.text))
        }
        let rows = Set(filled.filter { !$0.text.isEmpty }.map(\.row)).sorted()
        let columns = Set(filled.filter { !$0.text.isEmpty }.map(\.column)).sorted()
        guard !rows.isEmpty else { return "" }
        var grid: [Int: [Int: String]] = [:]
        for cell in filled where grid[cell.row]?[cell.column] == nil {
            grid[cell.row, default: [:]][cell.column] = cell.text
        }
        func line(_ row: Int) -> String {
            "| " + columns.map { grid[row]?[$0] ?? "" }.joined(separator: " | ") + " |"
        }
        var lines = [line(rows[0]), "|" + String(repeating: " --- |", count: columns.count)]
        lines += rows.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// A paragraph or a table of the page and where it is (normalized, either origin).
    struct Block: Equatable, Sendable {
        var text: String
        var box: CGRect
    }

    /// The page's text: the paragraphs in Vision's order, each table (Markdown) where its first
    /// paragraph was and the paragraphs inside it left out (they're its cells); a table without one
    /// at the end. Paragraphs one line each, a table set off by a blank line.
    static func arrange(paragraphs: [Block], tables: [Block]) -> String {
        var parts: [(text: String, table: Bool)] = []
        var placed = Set<Int>()
        for paragraph in paragraphs {
            let center = CGPoint(x: paragraph.box.midX, y: paragraph.box.midY)
            if let index = tables.indices.first(where: { tables[$0].box.insetBy(dx: -0.005, dy: -0.005).contains(center) }) {
                if placed.insert(index).inserted, !tables[index].text.isEmpty { parts.append((tables[index].text, true)) }
                continue
            }
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append((text, false)) }
        }
        for index in tables.indices where !placed.contains(index) && !tables[index].text.isEmpty {
            parts.append((tables[index].text, true))
        }
        var result = ""
        for (index, part) in parts.enumerated() {
            if index > 0 { result += part.table || parts[index - 1].table ? "\n\n" : "\n" }
            result += part.text
        }
        return result
    }
}

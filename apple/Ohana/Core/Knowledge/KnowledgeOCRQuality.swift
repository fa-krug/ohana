import CoreGraphics
import Foundation
import ImageIO

// The pure parts of reading a scanned page (`KnowledgeOCR`): which way the page is turned, a page
// as text with its tables as Markdown, and whether what came out looks good enough or should go to
// the family's AI as an image (`KnowledgeOCRQuality`). Everything here is pure, so it's tested
// without Vision.

/// A recognized line of text and Vision's confidence in it (0…1).
nonisolated struct KnowledgeOCRLine: Equatable, Sendable {
    var text: String
    var confidence: Float

    init(_ text: String, _ confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

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

/// Whether a page read by OCR looks right, or is better transcribed by the family's AI from the
/// image (`KnowledgeIndexer`'s page scans). Judged from the lines (text and Vision's confidence),
/// the tables' cells, the words the system's spell checker knows (German or English) and how much
/// ink the page has. Deliberately eager: a page goes to the AI unless it reads like clean print, so
/// handwriting and small mistakes in a table are written out too. Calibrated on a real scan, a
/// timetable photographed sideways: read upright by the document reader (mean confidence 0.51, 23 %
/// of the letters on lines under 0.4, 71 % of the words known) and turned (0.70 / 13 % / 80 %, its
/// handwritten times wrong, one cell read as Hangul) both are poor; clean print (confidence about
/// 0.9 and up, every word known) is good.
nonisolated enum KnowledgeOCRQuality {
    /// Below this mean confidence (weighted by characters) a page is poor.
    static let minConfidence: Float = 0.6
    /// Below this one a page is unsure: poor when more than `maxWeakShare` of its letters are on
    /// weak lines or fewer than `minKnownShareUnsure` of its words are known.
    static let unsureConfidence: Float = 0.85
    static let maxWeakShare = 0.05
    static let minKnownShareUnsure = 0.9
    /// A line below this confidence is one Vision is unsure of.
    static let weakLine: Float = 0.4
    /// Below this share of known words a page is poor whatever its confidence…
    static let minKnownShare = 0.75
    /// … when at least this many words could be checked.
    static let minCheckedWords = 8
    /// Above this share of 1–2 character fragments a page is poor…
    static let maxFragmentShare = 0.2
    /// … when it has at least this many tokens.
    static let minTokens = 10
    /// Above this share of letters from a script other than Latin, Greek or Cyrillic (garbage:
    /// Vision reads smudges as Hangul) a page is poor: about any.
    static let maxForeignShare = 0.01
    /// A table (of at least `minTableCells` cells) with more empty cells than this, or any garbled
    /// one (more than `maxGarbledCells`), is poor.
    static let maxEmptyCells = 0.35
    static let maxGarbledCells = 0.0
    static let minTableCells = 6
    /// A page with at least this share of ink (dark pixels; the timetable has 3.9 %) but fewer
    /// letters than `minLetters` has text the OCR missed (handwriting, a faint scan).
    static let inkedShare = 0.02
    static let minLetters = 25

    enum Reason: String, Equatable, Sendable {
        case lowConfidence, unknownWords, fragments, foreignScript, garbledTable, littleText
    }

    enum Verdict: Equatable, Sendable {
        case good
        case poor(Reason)

        var isPoor: Bool { if case .poor = self { true } else { false } }
    }

    /// The measures a verdict rests on (for tests and the log).
    struct Measures: Equatable, Sendable {
        var letters = 0
        var confidence: Float = 1
        /// The share of the letters on lines Vision is unsure of (below `weakLine`).
        var weakShare = 0.0
        var checkedWords = 0
        var knownShare = 1.0
        var tokens = 0
        var fragmentShare = 0.0
        var foreignShare = 0.0
        var emptyCells = 0.0
        var garbledCells = 0.0
    }

    /// The words the spell checker is asked about: letters only, at least 3 of them, no capitals
    /// only (abbreviations), as written (German nouns are capitalized), each once.
    static func checkableWords(_ lines: [KnowledgeOCRLine]) -> Set<String> {
        var words = Set<String>()
        for line in lines {
            for token in tokens(line.text) where isCheckable(token) { words.insert(token) }
        }
        return words
    }

    static func judge(lines: [KnowledgeOCRLine], tables: [[KnowledgeOCRCell]], ink: Double?,
                      known: ((String) -> Bool)?) -> Verdict {
        verdict(measure(lines: lines, tables: tables, known: known), ink: ink)
    }

    static func measure(lines: [KnowledgeOCRLine], tables: [[KnowledgeOCRCell]],
                        known: ((String) -> Bool)?) -> Measures {
        var m = Measures()
        var weighted: Float = 0
        var letters = 0, foreign = 0, weak = 0
        var allTokens: [String] = []
        for line in lines {
            var count = 0
            for scalar in line.text.unicodeScalars where scalar.properties.isAlphabetic {
                count += 1
                if !isLatinOrCommon(scalar) { foreign += 1 }
            }
            letters += count
            if line.confidence < weakLine { weak += count }
            weighted += line.confidence * Float(count)
            allTokens += tokens(line.text)
        }
        m.letters = letters
        if letters > 0 {
            m.confidence = weighted / Float(letters)
            m.foreignShare = Double(foreign) / Double(letters)
            m.weakShare = Double(weak) / Double(letters)
        }
        let meaningful = allTokens.filter { !$0.isEmpty }
        m.tokens = meaningful.count
        if !meaningful.isEmpty {
            m.fragmentShare = Double(meaningful.filter(isFragment).count) / Double(meaningful.count)
        }
        if let known {
            let checkable = allTokens.filter(isCheckable)
            m.checkedWords = checkable.count
            if !checkable.isEmpty {
                m.knownShare = Double(checkable.filter { known($0) }.count) / Double(checkable.count)
            }
        }
        for table in tables where table.count >= minTableCells {
            let empty = table.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            let garbled = table.filter { isGarbled($0.text) }.count
            m.emptyCells = max(m.emptyCells, Double(empty) / Double(table.count))
            m.garbledCells = max(m.garbledCells, Double(garbled) / Double(table.count))
        }
        return m
    }

    static func verdict(_ m: Measures, ink: Double?) -> Verdict {
        if m.letters < minLetters {
            // Hardly any text: poor only when the page has ink the OCR didn't read (a blank page or
            // a photo is no transcription job).
            if let ink, ink >= inkedShare { return .poor(.littleText) }
            if m.letters == 0 { return .good }
        }
        if m.confidence < minConfidence { return .poor(.lowConfidence) }
        if m.confidence < unsureConfidence {
            if m.weakShare > maxWeakShare { return .poor(.lowConfidence) }
            if m.checkedWords >= minCheckedWords, m.knownShare < minKnownShareUnsure { return .poor(.unknownWords) }
        }
        if m.foreignShare > maxForeignShare { return .poor(.foreignScript) }
        if m.checkedWords >= minCheckedWords, m.knownShare < minKnownShare { return .poor(.unknownWords) }
        if m.tokens >= minTokens, m.fragmentShare > maxFragmentShare { return .poor(.fragments) }
        if m.emptyCells > maxEmptyCells || m.garbledCells > maxGarbledCells { return .poor(.garbledTable) }
        return .good
    }

    // MARK: Tokens

    /// The line's tokens: runs without whitespace or "/" ("Religion/Ethik" is two words),
    /// punctuation and symbols around them taken off ("" for a token of punctuation only).
    static func tokens(_ text: String) -> [String] {
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).map { $0.trimmingCharacters(in: trim) }
    }

    /// A word for the spell checker: letters only, at least 3, not capitals only.
    private static func isCheckable(_ token: String) -> Bool {
        token.count >= 3 && token.allSatisfy(\.isLetter) && token != token.uppercased()
    }

    /// A broken piece: one or two characters, but not a number ("2", "15") or capitals ("GU", "EU").
    private static func isFragment(_ token: String) -> Bool {
        guard (1...2).contains(token.count) else { return false }
        if token.allSatisfy(\.isNumber) { return false }
        if token.allSatisfy({ $0.isLetter && $0.isUppercase }) { return false }
        return true
    }

    private static func isGarbled(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter(\.properties.isAlphabetic)
        return letters.contains { !isLatinOrCommon($0) } || text.contains("\u{FFFD}")
    }

    /// Latin letters (with their accents), and the Greek and Cyrillic a German or English letter
    /// may quote; anything else (CJK, Hangul, Arabic …) is taken for garbage.
    private static func isLatinOrCommon(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF, 0x0370...0x03FF, 0x0400...0x04FF, 0x00AA, 0x00BA: true
        default: false
        }
    }
}

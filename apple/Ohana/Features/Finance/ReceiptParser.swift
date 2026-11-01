import Foundation

/// A piece of text Vision recognized, placed on the page in normalized coordinates with the
/// origin at the top left (0…1): `x` its left edge, `y` its vertical middle, `height` its height.
nonisolated struct ReceiptTextPiece: Sendable, Hashable {
    var text: String
    var x: Double
    var y: Double
    var height: Double
}

/// What a receipt says: each part nil when it couldn't be read.
struct ReceiptScan: Hashable {
    var amountCents: Int?   // positive, the total paid
    var date: Day?
    var shop: String?
}

/// Reads a photographed receipt's text: the total paid, the day and the shop, for a new
/// transaction. German and English receipts mostly (supermarkets, drugstores, US/UK shops).
enum ReceiptParser {
    /// Groups pieces into the receipt's lines, top to bottom, each line's pieces left to right joined by two spaces
    /// (Vision returns "SUMME" and "12,34" as separate pieces on the same printed row).
    static func lines(_ pieces: [ReceiptTextPiece]) -> [String] {
        var rows: [[ReceiptTextPiece]] = []
        for piece in pieces.sorted(by: { $0.y < $1.y }) where !trimmed(piece.text).isEmpty {
            let fitting = rows.indices.compactMap { index -> (index: Int, distance: Double)? in
                let row = middle(of: rows[index])
                let distance = abs(piece.y - row.y)
                return distance <= min(piece.height, row.height) / 2 ? (index, distance) : nil
            }
            if let best = fitting.min(by: { $0.distance < $1.distance }) {
                rows[best.index].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows
            .sorted { middle(of: $0).y < middle(of: $1).y }
            .map { $0.sorted { $0.x < $1.x }.map { trimmed($0.text) }.joined(separator: "  ") }
            .filter { !$0.isEmpty }
    }

    /// Reads the total, date and shop from the lines. `monthFirst`: how to read an ambiguous "a/b/yyyy" (US style).
    static func parse(_ lines: [String], today: Day, monthFirst: Bool) -> ReceiptScan {
        let lines = lines.map(trimmed).filter { !$0.isEmpty }
        return ReceiptScan(amountCents: total(lines),
                           date: date(lines, today: today, monthFirst: monthFirst),
                           shop: shop(lines))
    }

    // MARK: Lines

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A row's vertical middle and height: the means of its pieces'.
    private static func middle(of row: [ReceiptTextPiece]) -> (y: Double, height: Double) {
        let count = Double(row.count)
        return (row.map(\.y).reduce(0, +) / count, row.map(\.height).reduce(0, +) / count)
    }

    // MARK: Total

    /// Words that make a line the total, the surest first.
    private static let strongTotal: [[String]] = [
        ["zu", "zahlen"], ["zahlbetrag"], ["gesamtbetrag"], ["endbetrag"], ["endsumme"], ["gesamtsumme"],
        ["rechnungsbetrag"], ["amount", "due"], ["balance", "due"], ["total", "due"], ["grand", "total"],
        ["total", "to", "pay"], ["amount", "to", "pay"],
    ]
    private static let weakTotal: [[String]] = [["summe"], ["gesamt"], ["total"], ["betrag"], ["amount"], ["sum"]]
    /// Lines that are never the total: subtotals, what was handed over and given back, savings.
    private static let notTotal: [[String]] = [
        ["zwischensumme"], ["subtotal"], ["sub", "total"], ["ruckgeld"], ["rueckgeld"], ["wechselgeld"],
        ["change"], ["gegeben"], ["geg"], ["given"], ["tendered"], ["tend"], ["cash"], ["bar"],
        ["savings"], ["saved"], ["ersparnis"], ["gespart"],
    ]
    /// Tax lines and the tax table.
    private static let taxWords: [[String]] = [
        ["mwst"], ["mws"], ["ust"], ["tax"], ["vat"], ["netto"], ["brutto"], ["steuer"],
    ]

    private static func total(_ lines: [String]) -> Int? {
        let info = lines.map { (tokens: tokens($0), amounts: amounts(in: $0), hasDigit: $0.contains(where: \.isNumber)) }
        for (keywords, strong) in [(strongTotal, true), (weakTotal, false)] {
            for (index, line) in info.enumerated() {
                guard has(line.tokens, keywords), !has(line.tokens, notTotal), strong || !has(line.tokens, taxWords) else { continue }
                if let amount = line.amounts.last {
                    if amount > 0 { return amount }
                    continue
                }
                // "zu zahlen" on a line of its own, the amount below it.
                if !line.hasDigit, index + 1 < info.count, !has(info[index + 1].tokens, notTotal),
                   let next = info[index + 1].amounts.last, next > 0 {
                    return next
                }
            }
        }
        return info
            .filter { !has($0.tokens, notTotal) && !has($0.tokens, taxWords) }
            .compactMap { $0.amounts.last }
            .filter { $0 > 0 }
            .max()
    }

    /// Two decimals after "," or ".", optional thousands separators, a minus before or after;
    /// not part of a date ("12.10.26") or a percentage ("19,00 %").
    private static let amountPattern = regex(#"(?<![\d.,])(-)?(\d{1,3}(?:[.,]\d{3})+|\d+)[.,](\d{2})(?!\d|[.,]\d|\s?%)(-(?!\d))?"#)

    /// The line's amounts in cents, left to right; negative ones (deposit returns) stay negative.
    private static func amounts(in line: String) -> [Int] {
        matches(amountPattern, in: line).compactMap { match in
            guard let whole = match.groups[1], let cents = match.groups[2] else { return nil }
            let digits = whole.filter(\.isNumber)
            guard digits.count <= 9, let units = Int(digits), let fraction = Int(cents) else { return nil }
            let value = units * 100 + fraction
            return match.groups[0] != nil || match.groups[3] != nil ? -value : value
        }
    }

    // MARK: Date

    private static let dottedDate = regex(#"(?<![\d./-])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?!\d|\.\d)"#)
    private static let isoDate = regex(#"(?<![\d./-])(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#)
    private static let slashDate = regex(#"(?<![\d./-])(\d{1,2})/(\d{1,2})/(\d{4}|\d{2})(?!\d|/\d)"#)

    /// The first real date on the receipt, from about two years back up to tomorrow.
    private static func date(_ lines: [String], today: Day, monthFirst: Bool) -> Day? {
        let earliest = today.adding(months: -24), latest = today.adding(days: 1)
        for line in lines {
            var found: [(location: Int, year: Int, month: Int, day: Int)] = []
            for match in matches(dottedDate, in: line) {
                guard let day = int(match.groups[0]), let month = int(match.groups[1]), let year = int(match.groups[2]) else { continue }
                found.append((match.location, year, month, day))
            }
            for match in matches(isoDate, in: line) {
                guard let year = int(match.groups[0]), let month = int(match.groups[1]), let day = int(match.groups[2]) else { continue }
                found.append((match.location, year, month, day))
            }
            for match in matches(slashDate, in: line) {
                guard let first = int(match.groups[0]), let second = int(match.groups[1]), let year = int(match.groups[2]) else { continue }
                let dayFirst = first > 12 ? true : second > 12 ? false : !monthFirst
                found.append((match.location, year, dayFirst ? second : first, dayFirst ? first : second))
            }
            for candidate in found.sorted(by: { $0.location < $1.location }) {
                let year = candidate.year < 100 ? 2000 + candidate.year : candidate.year
                guard (1...12).contains(candidate.month),
                      (1...daysIn(month: candidate.month, year: year)).contains(candidate.day) else { continue }
                let day = Day(year: year, month: candidate.month, day: candidate.day)
                if day >= earliest && day <= latest { return day }
            }
        }
        return nil
    }

    private static func int(_ text: String?) -> Int? { text.flatMap { Int($0) } }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    // MARK: Shop

    /// A chain and the words that name it. `anywhere: false` for names that are also ordinary
    /// words or surnames: they count only at the start of a line ("Netto", not "Bäckerei Müller").
    private struct Chain {
        let name: String
        let words: [[String]]
        var anywhere = true
    }

    private static let chains: [Chain] = [
        Chain(name: "Aldi Süd", words: [["aldi", "sud"], ["aldi", "sued"]]),
        Chain(name: "Aldi Nord", words: [["aldi", "nord"]]),
        Chain(name: "Aldi", words: [["aldi"]]),
        Chain(name: "REWE", words: [["rewe"]]),
        Chain(name: "EDEKA", words: [["edeka"]]),
        Chain(name: "Lidl", words: [["lidl"]]),
        Chain(name: "Kaufland", words: [["kaufland"]]),
        Chain(name: "Netto", words: [["netto"]], anywhere: false),
        Chain(name: "Penny", words: [["penny"]]),
        Chain(name: "dm", words: [["dm"]]),
        Chain(name: "Rossmann", words: [["rossmann"]]),
        Chain(name: "Müller", words: [["muller"], ["mueller"]], anywhere: false),
        Chain(name: "Globus", words: [["globus"]]),
        Chain(name: "tegut", words: [["tegut"]]),
        Chain(name: "Norma", words: [["norma"]]),
        Chain(name: "Alnatura", words: [["alnatura"]]),
        Chain(name: "denn's", words: [["denn", "s"], ["denns"]]),
        Chain(name: "Real", words: [["real"]], anywhere: false),
        Chain(name: "Marktkauf", words: [["marktkauf"]]),
        Chain(name: "famila", words: [["famila"]]),
        Chain(name: "Budni", words: [["budni"], ["budnikowsky"]]),
        Chain(name: "Hit", words: [["hit"]], anywhere: false),
        Chain(name: "Spar", words: [["spar"], ["eurospar"], ["interspar"]], anywhere: false),
        Chain(name: "Billa", words: [["billa"]]),
        Chain(name: "Hofer", words: [["hofer"]]),
        Chain(name: "Migros", words: [["migros"]]),
        Chain(name: "Coop", words: [["coop"]], anywhere: false),
        Chain(name: "IKEA", words: [["ikea"]]),
        Chain(name: "OBI", words: [["obi"]]),
        Chain(name: "Bauhaus", words: [["bauhaus"]]),
        Chain(name: "Hornbach", words: [["hornbach"]]),
        Chain(name: "toom", words: [["toom"]]),
        Chain(name: "Tesco", words: [["tesco"]]),
        Chain(name: "Sainsbury's", words: [["sainsbury"], ["sainsburys"]]),
        Chain(name: "Asda", words: [["asda"]]),
        Chain(name: "Walmart", words: [["walmart"]]),
        Chain(name: "Target", words: [["target"]], anywhere: false),
        Chain(name: "Costco", words: [["costco"]]),
        Chain(name: "Trader Joe's", words: [["trader", "joe"], ["trader", "joes"]]),
        Chain(name: "Whole Foods", words: [["whole", "foods"]]),
        Chain(name: "Kroger", words: [["kroger"]]),
        Chain(name: "Safeway", words: [["safeway"]]),
    ]

    /// Headings and greetings at the top of a receipt, never the shop's name.
    private static let headings = ["kassenbon", "kassenbeleg", "beleg", "rechnung", "quittung", "receipt", "willkommen",
                                   "welcome", "vielen dank", "thank you", "danke", "herzlich"]
    private static let contactWords: Set<String> = ["tel", "telefon", "fon", "phone", "fax", "www", "http", "https", "email", "mail"]
    private static let taxIdWords: Set<String> = ["ust", "ustid", "ustidnr", "idnr", "uid", "steuernr", "steuernummer", "vat"]
    private static let currencyWords: Set<String> = ["eur", "euro", "usd", "gbp", "chf"]
    private static let streetWords: Set<String> = ["street", "st", "road", "rd", "avenue", "ave", "blvd", "lane", "ln", "drive", "way"]
    private static let streetSuffixes = ["str", "strasse", "straße", "weg", "platz", "allee", "gasse", "damm", "ring", "markt", "ufer"]
    private static let postcode = regex(#"(?<!\d)\d{4,5}\s+\p{L}|^\d+\s+\p{L}|\b[A-Z]{2}\s+\d{5}\b|\b[A-Z]{1,2}\d[A-Z\d]?\s+\d[A-Z]{2}\b"#)
    private static let domainOrTime = regex(#"\.(de|com|at|ch|net|org|eu|uk)\b|@|\d{1,2}:\d{2}"#)

    private static func shop(_ lines: [String]) -> String? {
        for line in lines.prefix(10) where amounts(in: line).isEmpty {
            let words = tokens(line)
            for chain in chains {
                let named = chain.words.contains { phrase in
                    chain.anywhere ? contains(words, phrase) : words.starts(with: phrase)
                }
                // "Netto" heading the tax table is no shop.
                if named, chain.anywhere || !has(words.filter { !chain.words.joined().contains($0) }, taxWords) {
                    return chain.name
                }
            }
        }
        guard let line = lines.prefix(6).first(where: isName) else { return nil }
        var name = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !name.contains(where: \.isLowercase) && name.filter(\.isLetter).count > 4 {
            name = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
        return trimmed(String(name.prefix(60)))
    }

    /// Whether a line at the top could be the shop's name: letters, and none of the address,
    /// contact, tax id, date, amount or heading lines around it.
    private static func isName(_ line: String) -> Bool {
        guard line.filter(\.isLetter).count >= 3, line.filter(\.isNumber).count < 5, amounts(in: line).isEmpty else { return false }
        let words = tokens(line)
        let folded = fold(line)
        if headings.contains(where: { folded.contains($0) }) { return false }
        if words.contains(where: { contactWords.contains($0) || taxIdWords.contains($0) }) { return false }
        if words.allSatisfy({ currencyWords.contains($0) }) { return false }
        if contains(words, ["st", "nr"]) { return false }
        if !matches(domainOrTime, in: line).isEmpty || !matches(postcode, in: line).isEmpty { return false }
        for pattern in [dottedDate, isoDate, slashDate] where !matches(pattern, in: line).isEmpty { return false }
        if line.contains(where: \.isNumber),
           words.contains(where: { word in streetWords.contains(word) || streetSuffixes.contains(where: { word.hasSuffix($0) }) }) {
            return false
        }
        return true
    }

    // MARK: Text

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    /// The line's words, folded to lower case without diacritics ("Rückgeld" → "ruckgeld").
    private static func tokens(_ line: String) -> [String] {
        fold(line).split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func has(_ tokens: [String], _ phrases: [[String]]) -> Bool {
        phrases.contains { contains(tokens, $0) }
    }

    private static func contains(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= tokens.count else { return false }
        return (0...(tokens.count - phrase.count)).contains { Array(tokens[$0..<($0 + phrase.count)]) == phrase }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// Each match's start and capture groups (nil when a group didn't take part).
    private static func matches(_ regex: NSRegularExpression, in text: String) -> [(location: Int, groups: [String?])] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            let groups = (1..<max(match.numberOfRanges, 1)).map { index -> String? in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            return (match.range.location, groups)
        }
    }
}

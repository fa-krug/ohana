import Foundation

/// The character set of a statement file.
enum FinanceCSVEncoding: String, Codable, CaseIterable, Hashable {
    case utf8 = "utf-8"
    case windows1252 = "windows-1252"

    var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .windows1252: "Windows-1252 / ISO-8859-1"
        }
    }
}

enum FinanceDateFormat: String, Codable, CaseIterable, Hashable {
    case iso = "YYYY-MM-DD"
    case german = "DD.MM.YYYY"
    case germanShort = "DD.MM.YY"
    case european = "DD/MM/YYYY"
    case american = "MM/DD/YYYY"
}

/// How the columns of one bank's export map to transactions; saved per family in the finance
/// settings (web/lib/finance/csv.ts CsvMapping: the same JSON, so the web reads the app's too).
struct FinanceCSVMapping: Codable, Hashable {
    /// The header cells, to recognize the same bank's files later.
    var signature: String
    var encoding: FinanceCSVEncoding
    var delimiter: String
    /// Lines before the header (or the first row).
    var skipRows: Int
    var hasHeader: Bool
    var date: Int
    var dateFormat: FinanceDateFormat
    /// One signed amount column, or separate debit / credit columns.
    var amount: Int?
    var debit: Int?
    var credit: Int?
    /// "," or "."
    var decimal: String
    var payee: Int?
    var description: [Int]
    /// The account this bank's statements are imported into.
    var accountId: String?
    /// Whether transfers between accounts are combined on import (on when unset).
    var autoTransfers: Bool?

    enum CodingKeys: String, CodingKey {
        case signature, encoding, delimiter, skipRows, hasHeader, date, dateFormat, amount, debit, credit,
             decimal, payee, description, accountId, autoTransfers
    }

    init(signature: String, encoding: FinanceCSVEncoding, delimiter: String, skipRows: Int, hasHeader: Bool,
         date: Int, dateFormat: FinanceDateFormat, amount: Int?, debit: Int?, credit: Int?, decimal: String,
         payee: Int?, description: [Int], accountId: String? = nil, autoTransfers: Bool? = nil) {
        self.signature = signature
        self.encoding = encoding
        self.delimiter = delimiter
        self.skipRows = skipRows
        self.hasHeader = hasHeader
        self.date = date
        self.dateFormat = dateFormat
        self.amount = amount
        self.debit = debit
        self.credit = credit
        self.decimal = decimal
        self.payee = payee
        self.description = description
        self.accountId = accountId
        self.autoTransfers = autoTransfers
    }

    /// A saved mapping, if this app can read it.
    init?(json: JSONValue) {
        guard let data = try? APIClient.encoder.encode(json),
              let mapping = try? APIClient.decoder.decode(FinanceCSVMapping.self, from: data) else { return nil }
        self = mapping
    }

    var json: JSONValue { FinanceJSON.encode(self) }

    var decimalSeparator: Character { decimal == "," ? "," : "." }

    // The web reads `amount: null` as "debit and credit": the nullable columns are written as
    // null, not left out.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(signature, forKey: .signature)
        try c.encode(encoding, forKey: .encoding)
        try c.encode(delimiter, forKey: .delimiter)
        try c.encode(skipRows, forKey: .skipRows)
        try c.encode(hasHeader, forKey: .hasHeader)
        try c.encode(date, forKey: .date)
        try c.encode(dateFormat, forKey: .dateFormat)
        try c.encode(amount, forKey: .amount)
        try c.encode(debit, forKey: .debit)
        try c.encode(credit, forKey: .credit)
        try c.encode(decimal, forKey: .decimal)
        try c.encode(payee, forKey: .payee)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(accountId, forKey: .accountId)
        try c.encodeIfPresent(autoTransfers, forKey: .autoTransfers)
    }
}

/// A statement row as read: what POST /finance/import takes.
struct FinanceParsedRow: Hashable {
    /// The data row it came from.
    var line: Int
    var date: String
    var amountCents: Int
    var payee: String
    var description: String

    var json: JSONValue {
        .object([
            "date": .string(date),
            "amountCents": FinanceJSON.int(amountCents),
            "payee": .string(payee),
            "description": .string(description),
        ])
    }
}

/// Bank statement CSV files (web/lib/finance/csv.ts): decoding, splitting into cells, and
/// guessing how the columns map to transactions (German and English bank formats).
enum FinanceCSV {
    enum DecodeError: LocalizedError {
        case notUTF8
        var errorDescription: String? { String(localized: "The file is not valid UTF-8.") }
    }

    /// Decodes a file: UTF-8 if it is valid UTF-8, else Windows-1252 (older German banks).
    static func decode(_ data: Data, encoding: FinanceCSVEncoding? = nil) throws -> (text: String, encoding: FinanceCSVEncoding) {
        if encoding != .windows1252 {
            if var text = String(data: data, encoding: .utf8) {
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
                return (text, .utf8)
            }
            if encoding == .utf8 { throw DecodeError.notUTF8 }
        }
        return (String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self), .windows1252)
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Splits CSV text into rows of cells (quotes with "" escapes, newlines inside quotes).
    static func parse(_ text: String, delimiter: String) -> [[String]] {
        let d = delimiter.unicodeScalars.first ?? ";"
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = String.UnicodeScalarView()
        var quoted = false
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if quoted {
                if ch == "\"", i + 1 < scalars.count, scalars[i + 1] == "\"" {
                    cell.append("\"")
                    i += 1
                } else if ch == "\"" {
                    quoted = false
                } else {
                    cell.append(ch)
                }
            } else if ch == "\"", trim(String(cell)).isEmpty {
                quoted = true
                cell = String.UnicodeScalarView()
            } else if ch == d {
                row.append(trim(String(cell)))
                cell = String.UnicodeScalarView()
            } else if ch == "\n" || ch == "\r" {
                if ch == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                row.append(trim(String(cell)))
                rows.append(row)
                row = []
                cell = String.UnicodeScalarView()
            } else {
                cell.append(ch)
            }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty {
            row.append(trim(String(cell)))
            rows.append(row)
        }
        return rows.filter { $0.contains { !$0.isEmpty } }
    }

    static let delimiters: [(String, String)] = [(";", ";"), (",", ","), ("\t", "Tab"), ("|", "|")]

    /// The delimiter that splits the first lines most consistently into the most columns.
    static func detectDelimiter(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
            .map(String.init)
            .filter { !trim($0).isEmpty }
            .prefix(30)
        var best = ";", bestScore = -1
        for (d, _) in delimiters {
            let counts = lines.map { parse($0, delimiter: d).first?.count ?? 0 }
            let mode = modal(Array(counts))
            let score = mode > 1 ? counts.filter { $0 == mode }.count * mode : 0
            if score > bestScore { (best, bestScore) = (d, score) }
        }
        return best
    }

    private static func modal(_ values: [Int]) -> Int {
        var n: [Int: Int] = [:]
        for v in values { n[v, default: 0] += 1 }
        var best = 0, count = 0
        for v in values where n[v] != nil {
            let c = n[v]!
            if c > count || (c == count && v > best) { (best, count) = (v, c) }
        }
        return best
    }

    /// A date cell as YYYY-MM-DD, or nil if it doesn't match the format or isn't a real day.
    static func parseDate(_ cell: String, format: FinanceDateFormat) -> String? {
        let text = trim(cell)
        let numbers: (Int, Int, Int)?
        switch format {
        case .iso:
            numbers = text.prefixMatch(of: #/(\d{4})-(\d{1,2})-(\d{1,2})/#.asciiOnlyDigits()).map { (Int($0.1)!, Int($0.2)!, Int($0.3)!) }
        case .german:
            numbers = text.prefixMatch(of: #/(\d{1,2})\.(\d{1,2})\.(\d{4})/#.asciiOnlyDigits()).map { (Int($0.3)!, Int($0.2)!, Int($0.1)!) }
        case .germanShort:
            numbers = text.prefixMatch(of: #/(\d{1,2})\.(\d{1,2})\.(\d{2})(?!\d)/#.asciiOnlyDigits()).map {
                let y = Int($0.3)!
                return (y + (y < 70 ? 2000 : 1900), Int($0.2)!, Int($0.1)!)
            }
        case .european:
            numbers = text.prefixMatch(of: #/(\d{1,2})\/(\d{1,2})\/(\d{4})/#.asciiOnlyDigits()).map { (Int($0.3)!, Int($0.2)!, Int($0.1)!) }
        case .american:
            numbers = text.prefixMatch(of: #/(\d{1,2})\/(\d{1,2})\/(\d{4})/#.asciiOnlyDigits()).map { (Int($0.3)!, Int($0.1)!, Int($0.2)!) }
        }
        guard let (y, m, d) = numbers, (1...12).contains(m), d >= 1, d <= FinanceDates.daysIn(year: y, month: m) else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Whether at least 80% of the non-empty cells pass.
    private static func mostly(_ cells: [String], _ ok: (String) -> Bool) -> Bool {
        let filled = cells.filter { !trim($0).isEmpty }
        return !filled.isEmpty && Double(filled.filter(ok).count) >= Double(filled.count) * 0.8
    }

    /// The format that reads (almost) all samples; DD/MM before MM/DD unless a day is > 12.
    static func detectDateFormat(_ samples: [String]) -> FinanceDateFormat? {
        let cells = samples.filter { !trim($0).isEmpty }
        func count(_ f: FinanceDateFormat) -> Int { cells.filter { parseDate($0, format: f) != nil }.count }
        var best: FinanceDateFormat?
        for f in FinanceDateFormat.allCases where mostly(cells, { parseDate($0, format: f) != nil }) {
            if best == nil || count(f) > count(best!) { best = f }
        }
        return best
    }

    /// "," if the amounts look German (1.234,56), else ".".
    static func detectDecimal(_ samples: [String]) -> String {
        var comma = 0, dot = 0
        for s in samples {
            let t = trim(s)
            if t.contains(#/,\d{1,2}\D*$/#) { comma += 1 } else if t.contains(#/\.\d{1,2}\D*$/#) { dot += 1 }
        }
        return comma >= dot ? "," : "."
    }

    private static func pattern(_ p: String) -> Regex<AnyRegexOutput> {
        try! Regex(p).ignoresCase()
    }

    private static let guess = (
        date: pattern("buchungstag|buchungsdatum|^datum|date|booking"),
        amount: pattern("betrag|amount|umsatz|^summe|value"),
        debit: pattern("^soll|debit|ausgang|withdrawal"),
        credit: pattern("^haben|credit|eingang|deposit"),
        payee: pattern("empf[äa]nger|auftraggeber|beg[üu]nstigter|zahlungspflichtiger|payee|counterparty|^name|gegenkonto.*name|partner"),
        description: pattern("verwendungszweck|buchungstext|description|purpose|memo|reference|details|text")
    )

    /// Looks at a file and guesses a mapping: the delimiter, where the table starts (after a
    /// preamble with fewer columns), whether it has a header, and which column is what.
    static func guessMapping(_ text: String, encoding: FinanceCSVEncoding) -> FinanceCSVMapping {
        let delimiter = detectDelimiter(text)
        let rows = parse(text, delimiter: delimiter)
        let width = modal(rows.map(\.count))
        let first = max(0, rows.firstIndex { $0.count == width } ?? -1)
        let head = rows.indices.contains(first) ? rows[first] : []
        // A header has no amounts and no dates.
        let letters = try! Regex("[a-zäöü]").ignoresCase()
        let hasHeader = !head.isEmpty
            && head.allSatisfy { FinanceMoney.parse($0) == nil || $0.contains(letters) }
            && !head.contains { detectDateFormat([$0]) != nil }
        let data = Array(rows.dropFirst(first + (hasHeader ? 1 : 0)).filter { $0.count == width }.prefix(50))
        func column(_ i: Int) -> [String] { data.map { $0.indices.contains(i) ? $0[i] : "" } }
        func byName(_ re: Regex<AnyRegexOutput>) -> Int { hasHeader ? (head.firstIndex { $0.contains(re) } ?? -1) : -1 }

        // Date: the named column if it parses, else the first column that does.
        var date = byName(guess.date)
        if date < 0 || detectDateFormat(column(date)) == nil {
            date = head.indices.first { detectDateFormat(column($0)) != nil } ?? 0
        }
        func isAmounts(_ i: Int) -> Bool { i >= 0 && mostly(column(i)) { FinanceMoney.parse($0) != nil } }
        var amount: Int? = byName(guess.amount)
        let debit = byName(guess.debit), credit = byName(guess.credit)
        let split = debit >= 0 && credit >= 0 && isAmounts(debit) && isAmounts(credit)
        if !isAmounts(amount ?? -1) {
            amount = split ? nil : head.indices.filter { $0 != date }.first { i in
                isAmounts(i) && column(i).contains { $0.contains(#/[,.]\d{2}/#) }
            }
        }
        var used: Set<Int> = [date, amount ?? -1, split ? debit : -1, split ? credit : -1]
        var payee: Int? = byName(guess.payee)
        if let p = payee, p < 0 || used.contains(p) { payee = nil }
        if let payee { used.insert(payee) }
        let named = byName(guess.description)
        var description = named >= 0 && !used.contains(named) ? [named] : []
        if description.isEmpty {
            // The column with the longest texts.
            let texts = head.indices.filter { !used.contains($0) && !isAmounts($0) }
                .sorted { averageLength(column($0)) > averageLength(column($1)) }
            description = Array(texts.prefix(1))
        }
        let amounts = amount.map(column) ?? (column(debit) + column(credit))
        return FinanceCSVMapping(
            signature: hasHeader ? head.joined(separator: delimiter) : "",
            encoding: encoding,
            delimiter: delimiter,
            skipRows: first,
            hasHeader: hasHeader,
            date: date,
            dateFormat: detectDateFormat(column(date)) ?? .german,
            amount: amount,
            debit: amount == nil && split ? debit : nil,
            credit: amount == nil && split ? credit : nil,
            decimal: detectDecimal(amounts),
            payee: payee,
            description: description
        )
    }

    private static func averageLength(_ cells: [String]) -> Double {
        Double(cells.reduce(0) { $0 + $1.utf16.count }) / Double(max(cells.count, 1))
    }

    /// The table part of the file under a mapping: header cells and data rows.
    static func table(_ text: String, mapping: FinanceCSVMapping) -> (header: [String], rows: [[String]]) {
        let rows = Array(parse(text, delimiter: mapping.delimiter).dropFirst(mapping.skipRows))
        let header = mapping.hasHeader ? rows.first ?? [] : []
        return (header, mapping.hasHeader ? Array(rows.dropFirst()) : rows)
    }

    enum RowError: Hashable { case date, amount }

    /// Applies a mapping to data rows; rows that don't parse come back as errors.
    static func map(_ rows: [[String]], mapping m: FinanceCSVMapping) -> (ok: [FinanceParsedRow], errors: [(line: Int, reason: RowError)]) {
        var ok: [FinanceParsedRow] = []
        var errors: [(line: Int, reason: RowError)] = []
        func cell(_ r: [String], _ i: Int?) -> String {
            guard let i, r.indices.contains(i) else { return "" }
            return r[i]
        }
        for (line, r) in rows.enumerated() {
            guard let date = parseDate(cell(r, m.date), format: m.dateFormat) else {
                errors.append((line, .date))
                continue
            }
            let cents: Int?
            if m.amount != nil {
                cents = FinanceMoney.parse(cell(r, m.amount), decimal: m.decimalSeparator)
            } else {
                // Debit / credit: debits may be written with or without a minus.
                let debit = FinanceMoney.parse(cell(r, m.debit), decimal: m.decimalSeparator)
                let credit = FinanceMoney.parse(cell(r, m.credit), decimal: m.decimalSeparator)
                cents = debit == nil && credit == nil ? nil : abs(credit ?? 0) - abs(debit ?? 0)
            }
            guard let cents else {
                errors.append((line, .amount))
                continue
            }
            let description = m.description.map { cell(r, $0) }.filter { !$0.isEmpty }.joined(separator: " ")
                .replacing(#/\s+/#, with: " ")
            ok.append(FinanceParsedRow(
                line: line,
                date: date,
                amountCents: cents,
                payee: m.payee != nil ? limit(cell(r, m.payee), 200) : "",
                description: limit(description, 500)
            ))
        }
        return (ok, errors)
    }

    /// At most `n` UTF-16 units, as the server counts (JavaScript's `slice`), whole characters.
    static func limit(_ s: String, _ n: Int) -> String {
        guard s.utf16.count > n else { return s }
        var out = ""
        var count = 0
        for ch in s {
            let size = ch.utf16.count
            if count + size > n { break }
            out.append(ch)
            count += size
        }
        return out
    }
}

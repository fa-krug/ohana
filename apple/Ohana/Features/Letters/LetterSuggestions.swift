import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What a scanned letter is about, for its file name and tags: worked out on the device only,
/// first by `LetterHeuristic`, then (where Apple Intelligence is on) by Apple's on-device model
/// (`LetterModel`).
struct LetterSuggestion: Equatable {
    /// A short title in the letter's language, e.g. "Elternbrief Klasse 3b – Laternenfest".
    var title: String?
    /// The day the letter was written.
    var date: Day?
    var tags: [String] = []

    static let maxTitle = 60

    /// The file name without ".pdf": "YYYY-MM-DD Title", with the letter's date, else `today`.
    func fileName(today: Day) -> String {
        let day = (date ?? today).description
        guard let title, !title.isEmpty else { return day }
        return "\(day) \(title)"
    }

    /// Tidied: the title trimmed and at most `maxTitle` characters (cut at a word), the tags
    /// trimmed, without duplicates (case ignored), each short, at most five (`ScanTags`).
    func cleaned() -> LetterSuggestion {
        var title = title.map(LetterSuggestion.oneLine) ?? ""
        if title.count > Self.maxTitle {
            let cut = String(title.prefix(Self.maxTitle))
            title = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–-"))
        }
        return LetterSuggestion(title: title.isEmpty ? nil : title, date: date, tags: ScanTags.cleaned(tags))
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'„“”"))
    }
}

// MARK: - The heuristic

/// The suggestion without a model: the title from a subject line or a heading near the top, the
/// letter's date from the first date near the top, tags from keywords and the family's first
/// names found in the text.
enum LetterHeuristic {
    /// How far down the letter's date and heading are looked for.
    static let topLines = 25

    static func suggest(_ text: String, names: [String] = []) -> LetterSuggestion {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return LetterSuggestion(title: title(lines), date: date(lines), tags: tags(text, names: names)).cleaned()
    }

    // MARK: Title

    static func title(_ lines: [String]) -> String? {
        if let subject = lines.lazy.compactMap(subject).first { return subject }
        let top = Array(lines.prefix(topLines))
        // A letter's subject usually stands right above its greeting.
        if let greeting = top.firstIndex(where: isGreeting),
           let heading = top[..<greeting].last(where: isHeading) {
            return heading
        }
        return top.first(where: isHeading)
    }

    /// The text of a subject line: "Betreff: …", "Betr. …", "Subject: …", "Re: …".
    static func subject(_ line: String) -> String? {
        let pattern = #"^(?:betreff|betrifft|subject|re)\s*:\s*(.+)$|^betr\.\s*:?\s*(.+)$"#
        guard let match = firstMatch(pattern, in: line) else { return nil }
        let text = [1, 2].compactMap { match[$0] }.first?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? nil : text
    }

    /// A line that reads like a heading: 8–60 characters, mostly letters, not an address, a
    /// greeting, a date, a phone number or a web or mail address.
    static func isHeading(_ line: String) -> Bool {
        guard (8...60).contains(line.count) else { return false }
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        guard Double(letters) / Double(line.count) >= 0.6, digits <= 3 else { return false }
        let lower = line.lowercased()
        if isGreeting(line) || date(in: line) != nil { return false }
        let notStarting = ["tel", "fax", "phone", "mobil", "e-mail", "email", "seite ", "page ", "an ", "to "]
        let notContaining = ["@", "www.", "http", "str.", "straße", "strasse", "postfach", " weg ", " platz ", " allee "]
        if notStarting.contains(where: { lower.hasPrefix($0) }) || notContaining.contains(where: { lower.contains($0) }) {
            return false
        }
        // A postal code and town ("12345 Berlin").
        if firstMatch(#"\b\d{4,5}\s+\p{L}"#, in: line) != nil { return false }
        // Ends like a sentence or a greeting's comma: prose, not a heading.
        if line.hasSuffix(",") || line.hasSuffix(".") && !line.hasSuffix("..") { return false }
        return true
    }

    static func isGreeting(_ line: String) -> Bool {
        let lower = line.lowercased()
        let greetings = ["liebe ", "lieber ", "sehr geehrte", "hallo", "guten tag", "dear ", "hello", "hi ",
                         "to whom", "mit freundlichen", "viele grüße", "kind regards", "best regards", "sincerely"]
        return greetings.contains { lower.hasPrefix($0) }
    }

    // MARK: Date

    /// The first date near the top.
    static func date(_ lines: [String]) -> Day? {
        lines.prefix(topLines).lazy.compactMap(date(in:)).first
    }

    private static let germanMonths = [
        "januar": 1, "jan": 1, "jänner": 1, "februar": 2, "feb": 2, "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
        "april": 4, "apr": 4, "mai": 5, "juni": 6, "jun": 6, "juli": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "oktober": 10, "okt": 10, "november": 11, "nov": 11,
        "dezember": 12, "dez": 12,
    ]
    private static let englishMonths = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    /// The earliest date in `line`: 13.11.2026 (or .26), 13. November 2026, 2026-11-13,
    /// November 13, 2026 or 13 November 2026.
    static func date(in line: String) -> Day? {
        let monthNames = Set(germanMonths.keys).union(englishMonths.keys)
            .sorted { $0.count > $1.count }
            .joined(separator: "|")
        let patterns: [(String, (Match) -> Day?)] = [
            (#"\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})(?!\d)"#, { m in
                valid(year: m.int(3), month: m.int(2), day: m.int(1))
            }),
            (#"\b(\d{4})-(\d{2})-(\d{2})\b"#, { m in valid(year: m.int(1), month: m.int(2), day: m.int(3)) }),
            (#"\b(\d{1,2})(?:\.|st|nd|rd|th)?\s+(\#(monthNames))\.?\s+(\d{4})\b"#, { m in
                valid(year: m.int(3), month: month(m[2]), day: m.int(1))
            }),
            (#"\b(\#(monthNames))\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#, { m in
                valid(year: m.int(3), month: month(m[1]), day: m.int(2))
            }),
        ]
        return patterns
            .compactMap { pattern, read -> (Int, Day)? in
                guard let match = firstMatch(pattern, in: line), let day = read(match) else { return nil }
                return (match.location, day)
            }
            .min { $0.0 < $1.0 }?.1
    }

    private static func month(_ name: String?) -> Int? {
        guard let name = name?.lowercased() else { return nil }
        return germanMonths[name] ?? englishMonths[name]
    }

    private static func valid(year: Int?, month: Int?, day: Int?) -> Day? {
        guard var year, let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        if year < 100 { year += 2000 }
        guard (1900...2200).contains(year) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = Day.calendar.date(from: components),
              Day.calendar.component(.day, from: date) == day else { return nil }
        return Day(year: year, month: month, day: day)
    }

    // MARK: Tags

    /// Keywords (in the normalized text: lowercased, words split by single spaces, padded with a
    /// space at both ends) and their tag, in the letter's language.
    static let keywordTags: [(tag: String, keywords: [String])] = [
        ("Elternbrief", ["elternbrief", " liebe eltern", "sehr geehrte eltern", "elternabend"]),
        ("Schule", ["schule ", "schule,", " schüler", "klassenlehrer", " klasse ", "lehrerin", "schulleitung"]),
        ("Kita", [" kita", "kindergarten", "kindertagesstätte", " krippe ", " hort "]),
        ("Einladung", ["einladung", " laden wir", " lade ich", " laden euch", "eingeladen"]),
        ("Ausflug", ["ausflug", "klassenfahrt", "wandertag"]),
        ("Arzt", [" arzt", "ärztin", " praxis ", "impfung", "untersuchung"]),
        ("Rechnung", ["rechnung", "zahlbar bis", " überweisen", "überweisung"]),
        ("Verein", [" verein", " e v ", "mitgliedschaft", "mitgliedsbeitrag"]),
        ("Versicherung", ["versicherung"]),
        ("Steuer", ["finanzamt", "steuerbescheid", "steuererklärung"]),
        ("Parents", [" dear parents", "parents and carers", "parents and guardians"]),
        ("School", [" school ", " school,", " school.", " pupils", " teacher", " classroom"]),
        ("Daycare", [" daycare", " day care", " nursery ", " preschool"]),
        ("Invitation", [" invitation", " invite you", " you are invited", " you re invited"]),
        ("Trip", [" field trip", " school trip"]),
        ("Doctor", [" doctor", " clinic ", " vaccination", " check up "]),
        ("Invoice", [" invoice", " amount due", " payment due"]),
        ("Club", [" club ", " membership"]),
        ("Insurance", [" insurance"]),
        ("Tax", [" tax ", " tax return", " irs ", " hmrc "]),
    ]

    /// Up to three keyword tags, then the family's first names found in the text.
    static func tags(_ text: String, names: [String]) -> [String] {
        let normalized = " " + text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ") + " "
        // The keyword lists hold some punctuation for readability; compare like the text.
        func normal(_ keyword: String) -> String {
            keyword.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
        }
        let keywordTags = Self.keywordTags
            .filter { $0.keywords.contains { normalized.contains(normal($0)) } }
            .map(\.tag)
            .prefix(3)
        let firstNames = names.compactMap { $0.split(separator: " ").first.map(String.init) }
            .filter { $0.count >= 2 }
            .filter { normalized.contains(" \(normal($0.lowercased())) ") }
        return ScanTags.cleaned(Array(keywordTags) + firstNames)
    }

    // MARK: Matching

    struct Match {
        let groups: [String?]
        let location: Int

        subscript(_ index: Int) -> String? { index < groups.count ? groups[index] : nil }
        func int(_ index: Int) -> Int? { self[index].flatMap { Int($0) } }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        let groups = (0..<result.numberOfRanges).map { index -> String? in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
        return Match(groups: groups, location: result.range.location)
    }
}

// MARK: - Apple's on-device model

/// The suggestion of Apple's on-device model (FoundationModels), where Apple Intelligence is on;
/// nil when it isn't, fails or takes longer than `timeout`.
enum LetterModel {
    static let timeout: Duration = .seconds(10)
    /// The model's context is small: the top of the letter says what it's about.
    static let maxText = 3000

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.availability == .available
        #else
        false
        #endif
    }

    static func suggest(_ text: String, names: [String]) async -> LetterSuggestion? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let prompt = Self.prompt(text, names: names)
        return await withTaskGroup(of: LetterSuggestion?.self) { group in
            group.addTask { await ask(prompt) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }

    static func prompt(_ text: String, names: [String]) -> String {
        var prompt = "The scanned letter:\n\n\(text.prefix(maxText))"
        let firstNames = names.compactMap { $0.split(separator: " ").first.map(String.init) }
        if !firstNames.isEmpty {
            prompt += "\n\nThe family's first names: \(firstNames.joined(separator: ", ")). "
                + "When the letter is about one of them, use that name as a tag."
        }
        return prompt
    }

    #if canImport(FoundationModels)
    private static func ask(_ prompt: String) async -> LetterSuggestion? {
        let session = LanguageModelSession(instructions: """
            You name scanned letters (from a school, a daycare, a club, a doctor, an office) so a \
            family can file them as PDFs. Write the title and the tags in the letter's language.
            """)
        guard let answer = try? await session.respond(to: prompt, generating: LetterModelAnswer.self).content
        else { return nil }
        return LetterSuggestion(title: answer.title, date: Day(answer.date), tags: answer.tags).cleaned()
    }
    #endif
}

#if canImport(FoundationModels)
@Generable
nonisolated struct LetterModelAnswer {
    @Guide(description: "A short title for the letter, at most 60 characters, in the letter's language, naming the sender or kind and the topic, e.g. \"Elternbrief Klasse 3b – Laternenfest\" or \"Invitation – Mia's birthday party\"")
    var title: String
    @Guide(description: "The date the letter was written, as YYYY-MM-DD; an empty string when it shows none")
    var date: String
    @Guide(description: "1 to 5 short tags in the letter's language for filing it, e.g. \"Schule\", \"Kita\", \"Einladung\", \"Rechnung\" or a child's first name", .count(1...5))
    var tags: [String]
}
#endif

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What a scanned letter is about and whose it is, for its file name and tags: by
/// `LetterHeuristic`, Apple's on-device model (`LetterModel`, where Apple Intelligence is on) and
/// the server's assistant model (`LetterFindings.filing`, from the shell).
struct LetterSuggestion: Equatable {
    /// A short title in the letter's language, e.g. "Elternbrief Klasse 3b – Laternenfest".
    var title: String?
    /// The day the letter was written.
    var date: Day?
    var tags: [String] = []
    /// The family member the letter is about, as the family lists them (not necessarily who
    /// scans it).
    var person: String?

    static let maxTitle = 60

    /// The file name without ".pdf": "YYYY-MM-DD_Label_Title_Words", with the letter's date, else
    /// `today`; `label` (the person's tag or first name) unless the title already names them.
    func fileName(today: Day, label: String? = nil) -> String {
        var parts = [(date ?? today).description]
        if let label, !label.isEmpty, !titleNames(label) { parts.append(label) }
        if let title, !title.isEmpty { parts.append(title) }
        return ScanFileName.joined(parts.joined(separator: " "))
    }

    /// The title has `label` or the person's first name as a word.
    private func titleNames(_ label: String) -> Bool {
        guard let title else { return false }
        let words = Set(title.split { !$0.isLetter }.map { NameMatch.folded(String($0)) })
        let names = [label] + NameMatch.firstNames([person ?? ""])
        return names.contains { words.contains(NameMatch.folded($0)) }
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
        let person = person?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LetterSuggestion(title: title.isEmpty ? nil : title, date: date, tags: ScanTags.cleaned(tags),
                                person: person?.isEmpty == false ? person : nil)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'„“”"))
    }
}

// MARK: - The heuristic

/// The suggestion without a model: the title from a subject line or a heading near the top, the
/// letter's date from the first date near the top, tags from the known ones, keywords and the
/// family's first names found in the text, the person the one family member it mentions.
enum LetterHeuristic {
    /// How far down the letter's date and heading are looked for.
    static let topLines = 25

    /// `known`: the existing tags; given, only those are suggested.
    static func suggest(_ text: String, names: [String] = [], known: [String]? = nil) -> LetterSuggestion {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var tags = tags(text, names: names, known: known ?? [])
        if let known { tags = ScanTags.existing(tags, known: known, names: names) }
        let people = people(text, names: names)
        return LetterSuggestion(title: title(lines), date: date(lines), tags: tags,
                                person: people.count == 1 ? people[0] : nil).cleaned()
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

    /// The `known` tags found in the text, the known tags that are a variant of a family member's
    /// name the letter mentions ("Michi" when it says "Michael"), up to three keyword tags, then
    /// the family's first names found in the text.
    static func tags(_ text: String, names: [String], known: [String] = []) -> [String] {
        let normalized = normalized(text)
        let keywordTags = Self.keywordTags
            .filter { $0.keywords.contains { normalized.contains(normal($0)) } }
            .map(\.tag)
            .prefix(3)
        let family = NameMatch.firstNames(names)
        let mentioned = NameMatch.firstNames(people(text, names: names))
        let knownFound = known.filter { $0.count >= 2 && normalized.contains(" \(normal($0.lowercased())) ") }
        let nameTags = known.filter { tag in mentioned.contains { NameMatch.isVariant(tag, of: $0, family: family) } }
        return ScanTags.cleaned(knownFound + nameTags + Array(keywordTags) + mentioned, limit: .max)
    }

    /// The family's members (`names`, as listed) the text mentions: by their first name, or a
    /// variant of it written with a capital (`NameMatch`).
    static func people(_ text: String, names: [String]) -> [String] {
        let normalized = normalized(text)
        let family = NameMatch.firstNames(names)
        let words = NameMatch.capitalizedWords(text)
        return names.filter { full in
            guard let name = NameMatch.firstNames([full]).first else { return false }
            return name.count >= 2 && normalized.contains(" \(normal(name.lowercased())) ")
                || words.contains { NameMatch.isVariant($0, of: name, family: family) }
        }
    }

    /// The text lowercased, words split by single spaces, padded with a space at both ends.
    private static func normalized(_ text: String) -> String {
        " " + text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ") + " "
    }

    /// The keyword lists hold some punctuation for readability; compared like the text.
    private static func normal(_ keyword: String) -> String {
        keyword.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
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

// MARK: - Names

/// Whether two first names are the same person's: the same, or one a short form of the other
/// ("Michi" – Michael, "Alex" – Alexander, "Basti" – Sebastian, "Hannes" – Johannes), case and
/// accents ignored. A short form has at most six letters: the long name's first four or more,
/// perhaps a doubled letter and a pet ending ("Steffi" – Stefanie), or its middle or end without
/// the ending. Not one: a name of three letters ("Leo" – Leonie), another name that only adds an
/// ending (Michael – Michaela), a word that goes on differently ("Hanna" – Hannover).
nonisolated enum NameMatch {
    static func firstNames(_ names: [String]) -> [String] {
        names.compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// The words of `text` that start with a capital letter (names among them), each once.
    static func capitalizedWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split { !$0.isLetter }
            .filter { $0.count >= 3 && $0.first!.isUppercase }
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let a = folded(a), b = folded(b)
        guard a.count >= 3, b.count >= 3 else { return false }
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count <= 6 else { return false }
        // Another name with an ending: Michael – Michaela.
        if long.hasPrefix(short), long.count - short.count <= 2 { return false }
        let stem = nicknameStem(short)
        let prefix = zip(stem, long).prefix { $0 == $1 }.count
        if prefix >= 4 {
            // What's left of the short form: nothing, or a doubled letter (Steff-i – Stefanie).
            let rest = stem.dropFirst(prefix)
            if rest.isEmpty || rest.count == 1 && rest.first == stem[stem.index(stem.startIndex, offsetBy: prefix - 1)] {
                return true
            }
        }
        // A short form from the middle or the end: Basti – Sebastian, Lena – Magdalena.
        return stem.count >= 4 && long.count - stem.count <= 6 && long.contains(stem)
    }

    /// `word` (in a letter, or a tag) names `name` of the `family`: a variant of it, and not
    /// another member's own name.
    static func isVariant(_ word: String, of name: String, family: [String]) -> Bool {
        let folded = folded(word)
        if family.contains(where: { Self.folded($0) == folded }) { return Self.folded(name) == folded }
        return similar(word, name)
    }

    /// The member of the family (`names`, as listed) an answer names: the name itself (case
    /// ignored), else the one member with its first name; nil for anyone else.
    static func member(_ answer: String, in names: [String]) -> String? {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }
        if let exact = names.first(where: { $0.caseInsensitiveCompare(answer) == .orderedSame }) { return exact }
        guard let first = firstNames([answer]).first.map(folded) else { return nil }
        let matches = names.filter { firstNames([$0]).first.map(folded) == first }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The `known` tag that is `person`'s name or a short form of it, among the `family`'s names.
    static func tag(for person: String, known: [String], family: [String]) -> String? {
        guard let first = firstNames([person]).first else { return nil }
        let firsts = firstNames(family)
        return known.first { isVariant($0, of: first, family: firsts) }
    }

    /// Lowercased, without accents, letters only.
    static func folded(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter))
    }

    /// A short form without its pet ending: "basti" → "bast", "hansi" → "hans", "lenchen" → "len".
    private static func nicknameStem(_ name: String) -> String {
        for ending in ["chen", "ie", "i", "y"] where name.hasSuffix(ending) && name.count - ending.count >= 3 {
            return String(name.dropLast(ending.count))
        }
        return name
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

    /// `known`: the existing tags, the only ones it may suggest.
    static func suggest(_ text: String, names: [String], known: [String]) async -> LetterSuggestion? {
        #if canImport(FoundationModels)
        guard isAvailable else { return nil }
        let prompt = Self.prompt(text, names: names, known: known)
        return await withTaskGroup(of: LetterSuggestion?.self) { group in
            group.addTask { await ask(prompt, names: names) }
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

    /// The model's context is small: the latest of the known tags.
    static let maxKnown = 100

    static func prompt(_ text: String, names: [String], known: [String]) -> String {
        var prompt = "The scanned letter:\n\n\(text.prefix(maxText))"
        if !names.isEmpty {
            prompt += "\n\nThe family's members: \(names.joined(separator: ", ")). Whoever scans the letter (often "
                + "a parent) isn't necessarily who it's for: decide whom it is about (the child it's about, the "
                + "patient, the addressee) and give that member as the person, written exactly as listed; an "
                + "empty person when it's for the whole family or unclear."
        }
        if known.isEmpty {
            prompt += "\n\nThere are no tags yet: answer with no tags."
        } else {
            prompt += "\n\nThe existing tags: \(known.prefix(maxKnown).joined(separator: ", ")). "
                + "Choose the tags only from these, those that fit the letter (a name when it's about that "
                + "person; a tag may be a short form of a name, e.g. \"Michi\" for Michael); none when none "
                + "fits. Never make up a tag."
        }
        return prompt
    }

    #if canImport(FoundationModels)
    private static func ask(_ prompt: String, names: [String]) async -> LetterSuggestion? {
        let session = LanguageModelSession(instructions: """
            You name scanned letters (from a school, a daycare, a club, a doctor, an office) so a \
            family can file them as PDFs, and say which family member each is about. Write the title \
            and the tags in the letter's language.
            """)
        guard let answer = try? await session.respond(to: prompt, generating: LetterModelAnswer.self).content
        else { return nil }
        return LetterSuggestion(title: answer.title, date: Day(answer.date), tags: answer.tags,
                                person: NameMatch.member(answer.person, in: names)).cleaned()
    }
    #endif
}

#if canImport(FoundationModels)
@Generable
nonisolated struct LetterModelAnswer {
    @Guide(description: "The family member the letter is about, exactly as listed; an empty string when it's for the whole family or unclear")
    var person: String
    @Guide(description: "A short title for the letter, at most 60 characters, in the letter's language, naming the sender or kind and the topic, without the date and the person's name, e.g. \"Elternbrief Klasse 3b – Laternenfest\" or \"Invitation – birthday party\"")
    var title: String
    @Guide(description: "The date the letter was written, as YYYY-MM-DD; an empty string when it shows none")
    var date: String
    @Guide(description: "0 to 5 tags for filing it, each one of the existing tags given", .count(0...5))
    var tags: [String]
}
#endif

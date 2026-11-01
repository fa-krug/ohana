import Foundation

/// A duration in a step's text ("simmer for 20 minutes", "1 Std. 30 Min.", "10–15 min"): where it
/// is and how long its timer runs. A range counts from its lower end, the first time to check.
struct StepDuration: Hashable {
    let range: Range<String.Index>
    let seconds: Int
}

/// Finds the durations in a recipe step, in English and German (recipes are in either): digits,
/// fractions ("1½", "1 1/2"), small number words ("a minute", "eine halbe Stunde"), ranges
/// ("10-15", "5 to 6", "5 bis 6") and compounds ("1 hour 30 minutes", "1 Std. und 20 Min.").
nonisolated enum StepDurations {
    static func find(in text: String) -> [StepDuration] {
        let ns = NSRange(text.startIndex..., in: text)
        var found: [(range: Range<String.Index>, seconds: Int, unit: Int)] = []
        for match in pattern.matches(in: text, range: ns) {
            guard let range = Range(match.range, in: text),
                  let numRange = Range(match.range(withName: "num"), in: text),
                  let value = number(text[numRange]) else { continue }
            let unit = ["h", "m", "s"].firstIndex { match.range(withName: $0).location != NSNotFound } ?? 1
            let seconds = Int((value * [3600, 60, 1][unit]).rounded())
            // "1 hour 30 minutes": a smaller unit right after a larger one adds to it.
            if let last = found.last, last.unit < unit,
               gap.firstMatch(in: text, range: NSRange(last.range.upperBound..<range.lowerBound, in: text)) != nil {
                found[found.count - 1] = (last.range.lowerBound..<range.upperBound, last.seconds + seconds, unit)
            } else {
                found.append((range, seconds, unit))
            }
        }
        return found
            .filter { (1...maxSeconds).contains($0.seconds) }
            .map { StepDuration(range: $0.range, seconds: $0.seconds) }
    }

    /// Two days: anything longer isn't a kitchen timer.
    static let maxSeconds = 48 * 3600

    private static let words: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
        "thirty": 30, "forty": 40, "sixty": 60,
        "ein": 1, "eine": 1, "einer": 1, "einem": 1, "einen": 1, "zwei": 2, "drei": 3, "vier": 4,
        "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12,
        "fünfzehn": 15, "zwanzig": 20, "dreißig": 30, "vierzig": 40, "sechzig": 60,
        "anderthalb": 1.5, "eineinhalb": 1.5,
    ]

    private static let fractions: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75]

    private static let pattern: NSRegularExpression = {
        let word = words.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let num = #"(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:[.,]\d+)?(?:\s*[½¼¾])?|[½¼¾]|half\s+an?|(?:eine[rnm]?\s+)?halbe[nr]?|"#
            + word + #")(?:\s+and\s+a\s+half)?"#
        let unit = #"(?<h>hours?|hrs?|h|stunden?|std)|(?<m>minutes?|minuten?|mins?)|(?<s>seconds?|sekunden?|secs?|sek)"#
        let range = #"(?:\s*(?:-|–|—|to|bis|or|oder)\s*"# + num + ")?"
        let full = #"(?<![\p{L}\p{N}])(?<num>"# + num + ")" + range + #"\s*-?\s*(?:"# + unit + #")(?![\p{L}])"#
        return try! NSRegularExpression(pattern: full, options: [.caseInsensitive])
    }()

    /// What may stand between the parts of a compound: "1 Std. 30 Min.", "1 hour, 30 minutes",
    /// "1 hour and 30 minutes".
    private static let gap = try! NSRegularExpression(pattern: #"^\.?\s*,?\s*(?:(?:and|und)\s+)?$"#, options: [.caseInsensitive])

    /// The value of the number part: "20", "1,5", "1½", "1 1/2", "a", "eine halbe", "two and a half".
    static func number(_ raw: Substring) -> Double? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        var extra = 0.0
        if let half = text.range(of: #"\s+and\s+a\s+half$"#, options: .regularExpression) {
            text.removeSubrange(half)
            extra = 0.5
        }
        if let value = words[text] { return value + extra }
        if text.hasPrefix("half") || text.contains("halb") { return 0.5 + extra }
        if text.contains("/") {
            let parts = text.split(whereSeparator: \.isWhitespace)
            let fraction = parts.last!.split(separator: "/").compactMap { Double($0) }
            guard fraction.count == 2, fraction[1] > 0 else { return nil }
            let whole = parts.count > 1 ? Double(parts[0]) ?? 0 : 0
            return whole + fraction[0] / fraction[1] + extra
        }
        var fraction = 0.0
        if let last = text.last, let value = fractions[last] {
            fraction = value
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return fraction + extra }
        }
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return value + fraction + extra
    }

    /// The step's text with each duration as a link `ohana-timer:<index>` (an index into `durations`).
    static func linked(_ text: String, durations: [StepDuration]) -> AttributedString {
        var out = AttributedString()
        var position = text.startIndex
        for (index, duration) in durations.enumerated() {
            out += AttributedString(String(text[position..<duration.range.lowerBound]))
            var part = AttributedString(String(text[duration.range]))
            part.link = URL(string: "\(linkScheme):\(index)")
            part.underlineStyle = .single
            out += part
            position = duration.range.upperBound
        }
        out += AttributedString(String(text[position...]))
        return out
    }

    static let linkScheme = "ohana-timer"

    /// The duration index of a link made by `linked`.
    static func index(of url: URL) -> Int? {
        url.scheme == linkScheme ? Int(url.absoluteString.dropFirst(linkScheme.count + 1)) : nil
    }
}

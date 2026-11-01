import Foundation

/// How an event repeats: an RFC 5545 RRULE value as the server stores it (events.ts `rrule`, e.g.
/// "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20270101"), parsed. `string` writes it in one fixed
/// order, so two rules that say the same compare equal. Weekdays are numbered like `Calendar` and
/// EventKit: 1 Sunday … 7 Saturday.
struct RepeatRule: Hashable, Codable {
    enum Frequency: String, Codable, CaseIterable {
        case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
    }

    /// A BYDAY entry: a weekday, for monthly and yearly rules optionally the nth of it (-1: the last).
    struct WeekdayEntry: Hashable, Codable {
        var weekday: Int
        var ordinal: Int?

        init(_ weekday: Int, ordinal: Int? = nil) {
            self.weekday = weekday
            self.ordinal = ordinal
        }
    }

    enum End: Hashable, Codable {
        case never
        /// The last day it may happen on (inclusive).
        case until(Day)
        /// How many times it happens in all.
        case count(Int)
    }

    var frequency: Frequency
    var interval = 1
    var weekdays: [WeekdayEntry] = []
    var monthDays: [Int] = []
    var months: [Int] = []
    var yearDays: [Int] = []
    var weekNumbers: [Int] = []
    var setPositions: [Int] = []
    /// WKST: the weekday weeks start on (1 Sunday … 7 Saturday); nil: Monday, as in iCalendar.
    var weekStart: Int?
    var end: End = .never

    init(_ frequency: Frequency, interval: Int = 1, weekdays: [WeekdayEntry] = [], monthDays: [Int] = [],
         months: [Int] = [], yearDays: [Int] = [], weekNumbers: [Int] = [], setPositions: [Int] = [],
         weekStart: Int? = nil, end: End = .never) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.months = months
        self.yearDays = yearDays
        self.weekNumbers = weekNumbers
        self.setPositions = setPositions
        self.weekStart = weekStart
        self.end = end
    }

    static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// Parses an RRULE value (with or without "RRULE:"); nil when it isn't one the server takes.
    init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("RRULE:") { value.removeFirst(6) }
        var parts: [String: String] = [:]
        for part in value.split(separator: ";") where !part.isEmpty {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, parts[pair[0]] == nil else { return nil }
            parts[pair[0]] = pair[1]
        }
        guard let freq = parts.removeValue(forKey: "FREQ").flatMap(Frequency.init(rawValue:)) else { return nil }
        self.init(freq)
        func ints(_ key: String, _ range: ClosedRange<Int>) -> [Int]? {
            guard let raw = parts.removeValue(forKey: key) else { return [] }
            let list = raw.split(separator: ",").map { Int($0) }
            guard !list.isEmpty, list.allSatisfy({ $0.map { range.contains($0) && $0 != 0 } ?? false }) else { return nil }
            return list.compactMap { $0 }
        }
        if let raw = parts.removeValue(forKey: "INTERVAL") {
            guard let n = Int(raw), n >= 1 else { return nil }
            interval = n
        }
        guard let monthDays = ints("BYMONTHDAY", -31...31), let months = ints("BYMONTH", 1...12),
              let yearDays = ints("BYYEARDAY", -366...366), let weekNumbers = ints("BYWEEKNO", -53...53),
              let setPositions = ints("BYSETPOS", -366...366) else { return nil }
        self.monthDays = monthDays
        self.months = months
        self.yearDays = yearDays
        self.weekNumbers = weekNumbers
        self.setPositions = setPositions
        if let raw = parts.removeValue(forKey: "BYDAY") {
            for item in raw.split(separator: ",") {
                let code = String(item.suffix(2))
                guard let index = Self.codes.firstIndex(of: code) else { return nil }
                let prefix = item.dropLast(2)
                var ordinal: Int?
                if !prefix.isEmpty {
                    guard let n = Int(prefix), n != 0, (-53...53).contains(n) else { return nil }
                    ordinal = n
                }
                weekdays.append(WeekdayEntry(index + 1, ordinal: ordinal))
            }
        }
        if let raw = parts.removeValue(forKey: "WKST") {
            guard let index = Self.codes.firstIndex(of: raw) else { return nil }
            weekStart = index + 1
        }
        let count = parts.removeValue(forKey: "COUNT")
        let until = parts.removeValue(forKey: "UNTIL")
        switch (count, until) {
        case (nil, nil): end = .never
        case let (count?, nil):
            guard let n = Int(count), n >= 1 else { return nil }
            end = .count(n)
        case let (nil, until?):
            // A date; a date-time (from elsewhere) counts by its day.
            let digits = until.prefix(8)
            guard digits.count == 8, digits.allSatisfy(\.isNumber),
                  let day = Day("\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))") else { return nil }
            end = .until(day)
        default: return nil
        }
        guard parts.isEmpty else { return nil }
    }

    /// The rule as the server stores it, its parts in a fixed order.
    var string: String {
        var out = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 { out.append("INTERVAL=\(interval)") }
        if !weekdays.isEmpty {
            out.append("BYDAY=" + weekdays.map { ($0.ordinal.map(String.init) ?? "") + Self.codes[$0.weekday - 1] }.joined(separator: ","))
        }
        func list(_ key: String, _ values: [Int]) {
            if !values.isEmpty { out.append("\(key)=" + values.map(String.init).joined(separator: ",")) }
        }
        list("BYMONTHDAY", monthDays)
        list("BYMONTH", months)
        list("BYYEARDAY", yearDays)
        list("BYWEEKNO", weekNumbers)
        list("BYSETPOS", setPositions)
        if let weekStart, weekStart != 2 { out.append("WKST=\(Self.codes[weekStart - 1])") }
        switch end {
        case .never: break
        case let .until(day): out.append(String(format: "UNTIL=%04d%02d%02d", day.year, day.month, day.day))
        case let .count(n): out.append("COUNT=\(n)")
        }
        return out.joined(separator: ";")
    }

    /// The same rule written the server's way (nil for nil or a rule that isn't one).
    static func canonical(_ text: String?) -> String? {
        text.flatMap(RepeatRule.init).map(\.string)
    }

    /// Only frequency, interval, the weekdays of a weekly rule and the end: what the editor's own
    /// controls make. Other rules (from Apple Calendar or the assistant) show as they are.
    var isSimple: Bool {
        monthDays.isEmpty && months.isEmpty && yearDays.isEmpty && weekNumbers.isEmpty && setPositions.isEmpty
            && weekStart == nil && (weekdays.isEmpty || (frequency == .weekly && weekdays.allSatisfy { $0.ordinal == nil }))
    }
}

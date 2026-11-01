import Foundation

// How a repeating event's rule reads ("Every 2 weeks on Monday and Wednesday, until 1 Jan 2027")
// and the choices of the event editor's Repeat menu, like Apple Calendar's.

extension RepeatRule {
    /// The rule in words. Weekday and month names, ordinals, lists and dates follow `locale`.
    func summary(locale: Locale = .current) -> String {
        var text = Self.frequencyText(frequency, interval: interval)
        for part in parts(locale: locale) { text += " " + part }
        switch end {
        case .never: break
        case let .until(day):
            text += ", " + String(localized: "until \(day.date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale)))")
        case let .count(n):
            text += ", " + String(localized: "\(n) times")
        }
        return text
    }

    /// "Daily", "Every 2 weeks", …
    static func frequencyText(_ frequency: Frequency, interval: Int) -> String {
        switch (frequency, interval) {
        case (.daily, 1): String(localized: "Daily")
        case (.weekly, 1): String(localized: "Weekly")
        case (.monthly, 1): String(localized: "Monthly")
        case (.yearly, 1): String(localized: "Yearly")
        case (.daily, _): String(localized: "Every \(interval) days")
        case (.weekly, _): String(localized: "Every \(interval) weeks")
        case (.monthly, _): String(localized: "Every \(interval) months")
        case (.yearly, _): String(localized: "Every \(interval) years")
        }
    }

    /// What follows the frequency: on which days, in which months.
    private func parts(locale: Locale) -> [String] {
        var out: [String] = []
        let and = { (items: [String]) in items.formatted(.list(type: .and).locale(locale)) }
        if !months.isEmpty {
            out.append(String(localized: "in \(and(months.map { Self.monthName($0, locale: locale) }))"))
        }
        if !weekNumbers.isEmpty {
            out.append(String(localized: "in week \(and(weekNumbers.map(String.init)))"))
        }
        if !yearDays.isEmpty {
            out.append(String(localized: "on day \(and(yearDays.map { Self.ordinal($0, locale: locale) })) of the year"))
        }
        if !monthDays.isEmpty {
            out.append(contentsOf: Self.groupedMonthDays(monthDays, locale: locale))
        }
        let plain = weekdays.filter { $0.ordinal == nil }.map(\.weekday)
        let numbered = weekdays.filter { $0.ordinal != nil }
        if !plain.isEmpty {
            if let position = setPositions.first, setPositions.count == 1 {
                // BYSETPOS picks one of the days: "on the first weekday", "on the last Saturday or Sunday".
                out.append(Self.onThe(position, Self.dayGroup(plain, locale: locale)))
            } else {
                out.append(String(localized: "on \(and(Self.sortedWeekdays(plain).map { Self.weekdayName($0, locale: locale) }))"))
                if !setPositions.isEmpty {
                    out.append(String(localized: "(positions \(and(setPositions.map(String.init))))"))
                }
            }
        }
        out.append(contentsOf: numbered.map { Self.onThe($0.ordinal ?? 1, Self.weekdayName($0.weekday, locale: locale)) })
        return out
    }

    /// Days of the month: "on the 1st and 15th", "on the last day".
    private static func groupedMonthDays(_ days: [Int], locale: Locale) -> [String] {
        var out: [String] = []
        let positive = days.filter { $0 > 0 }.sorted()
        if !positive.isEmpty {
            let list = positive.map { ordinal($0, locale: locale) }.formatted(.list(type: .and).locale(locale))
            out.append(String(localized: "on the \(list)"))
        }
        for day in days where day < 0 {
            out.append(day == -1 ? String(localized: "on the last day") : String(localized: "on day \(-day) before the end"))
        }
        return out
    }

    /// "on the first Monday", "on the last Friday".
    static func onThe(_ ordinal: Int, _ what: String) -> String {
        switch ordinal {
        case 1: String(localized: "on the first \(what)")
        case 2: String(localized: "on the second \(what)")
        case 3: String(localized: "on the third \(what)")
        case 4: String(localized: "on the fourth \(what)")
        case 5: String(localized: "on the fifth \(what)")
        case -1: String(localized: "on the last \(what)")
        case -2: String(localized: "on the second to last \(what)")
        default: String(localized: "on \(what) number \(ordinal)")
        }
    }

    /// Weekdays BYSETPOS picks from: "weekday" for Monday to Friday, "weekend day", "day" for all
    /// seven, else their names ("Saturday or Sunday").
    private static func dayGroup(_ days: [Int], locale: Locale) -> String {
        switch Set(days) {
        case Set(2...6): String(localized: "weekday")
        case [1, 7]: String(localized: "weekend day")
        case Set(1...7): String(localized: "day")
        default: sortedWeekdays(days).map { weekdayName($0, locale: locale) }.formatted(.list(type: .or).locale(locale))
        }
    }

    /// Monday first, Sunday last.
    static func sortedWeekdays(_ days: [Int]) -> [Int] {
        days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }
    }

    static func weekdayName(_ weekday: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.standaloneWeekdaySymbols[(weekday - 1 + 7) % 7]
    }

    static func monthName(_ month: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar.standaloneMonthSymbols[(month - 1 + 12) % 12]
    }

    /// "1st", "15th" (English), "1.", "15." (German).
    static func ordinal(_ n: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    // MARK: Editing

    /// What the editor's own controls make: `isSimple`, or a monthly rule on one day of the month
    /// ("on the 15th") or on one weekday of it ("on the last Friday"). Other rules show as their
    /// summary and stay as they are unless changed.
    var isEditable: Bool {
        if isSimple { return true }
        guard frequency == .monthly, months.isEmpty, yearDays.isEmpty, weekNumbers.isEmpty, setPositions.isEmpty,
              weekStart == nil else { return false }
        if weekdays.isEmpty { return monthDays.count == 1 && monthDays[0] > 0 }
        guard monthDays.isEmpty, weekdays.count == 1, let ordinal = weekdays[0].ordinal else { return false }
        return (1...5).contains(ordinal) || ordinal == -1
    }

    /// The rule for a series moved by `days`: its weekdays (BYDAY) moved along, so they stay the
    /// days it falls on (the server moves the series, not the days its rule names).
    func shiftingWeekdays(by days: Int) -> RepeatRule {
        guard !weekdays.isEmpty, days % 7 != 0 else { return self }
        var rule = self
        rule.weekdays = weekdays.map { RepeatRule.WeekdayEntry((($0.weekday - 1 + days) % 7 + 7) % 7 + 1, ordinal: $0.ordinal) }
        if frequency == .weekly, weekdays.allSatisfy({ $0.ordinal == nil }) {
            rule.weekdays = RepeatRule.sortedWeekdays(rule.weekdays.map(\.weekday)).map { RepeatRule.WeekdayEntry($0) }
        }
        return rule
    }

    /// The rule without its end, to compare it with the presets.
    var withoutEnd: RepeatRule {
        var rule = self
        rule.end = .never
        return rule
    }
}

/// The Repeat menu of the event editor, like Apple Calendar's.
enum CalendarRepeatChoice: String, CaseIterable, Identifiable {
    case never, daily, weekly, biweekly, monthly, yearly, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: String(localized: "Never")
        case .daily: String(localized: "Every Day")
        case .weekly: String(localized: "Every Week")
        case .biweekly: String(localized: "Every 2 Weeks")
        case .monthly: String(localized: "Every Month")
        case .yearly: String(localized: "Every Year")
        case .custom: String(localized: "Custom…")
        }
    }

    /// The preset's rule (without an end); nil for Never and Custom.
    var rule: RepeatRule? {
        switch self {
        case .never, .custom: nil
        case .daily: RepeatRule(.daily)
        case .weekly: RepeatRule(.weekly)
        case .biweekly: RepeatRule(.weekly, interval: 2)
        case .monthly: RepeatRule(.monthly)
        case .yearly: RepeatRule(.yearly)
        }
    }

    /// The choice a rule shows as: a preset when it is one (whatever its end), else Custom.
    init(_ rule: RepeatRule?) {
        guard let rule else { self = .never; return }
        let plain = rule.withoutEnd
        self = Self.allCases.first { $0.rule == plain } ?? .custom
    }
}

/// How a monthly rule picks its day in the custom editor.
enum CalendarMonthlyRepeat: Hashable {
    /// On this day of the month (1…31).
    case day(Int)
    /// On the nth (1…5, -1 the last) weekday (1 Sunday … 7 Saturday).
    case weekday(ordinal: Int, weekday: Int)

    /// What a monthly rule does; nil when it isn't one the editor makes. A rule without days
    /// repeats on the event's own day of the month (`start`).
    init?(_ rule: RepeatRule, start: Day) {
        guard rule.frequency == .monthly, rule.isEditable else { return nil }
        if let entry = rule.weekdays.first, let ordinal = entry.ordinal {
            self = .weekday(ordinal: ordinal, weekday: entry.weekday)
        } else {
            self = .day(rule.monthDays.first ?? start.day)
        }
    }

    /// The day's position in its month as the editor offers it: the first to fourth, or the last
    /// when it is in the month's last seven days ("on the last Friday").
    static func position(of day: Day) -> (ordinal: Int, weekday: Int) {
        let weekday = CalendarMath.weekday(day) + 1
        let last = CalendarMath.daysInMonth(year: day.year, month: day.month)
        return (day.day + 7 > last ? -1 : (day.day - 1) / 7 + 1, weekday)
    }

    /// Writes it into a monthly rule (the event's own day leaves BYMONTHDAY out).
    func apply(to rule: inout RepeatRule, start: Day) {
        switch self {
        case let .day(n):
            rule.weekdays = []
            rule.monthDays = n == start.day ? [] : [n]
        case let .weekday(ordinal, weekday):
            rule.monthDays = []
            rule.weekdays = [RepeatRule.WeekdayEntry(weekday, ordinal: ordinal)]
        }
    }
}

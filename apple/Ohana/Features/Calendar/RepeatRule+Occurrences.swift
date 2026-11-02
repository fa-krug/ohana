import Foundation

// The days a rule repeats on, as the server expands it (server/lib/calendar/rrule.ts
// `expandRule`): plain days, the first occurrence always the start (it counts for COUNT), UNTIL
// inclusive, and bounded, so a rule that seldom or never matches can't run away.
extension RepeatRule {
    /// The occurrences from `from` to `to` (inclusive) of the rule starting on `start`, sorted, at
    /// most `limit`.
    func occurrences(start: Day, from: Day, to: Day, limit: Int = 5000) -> [Day] {
        let x = RepeatExpansion(self, start: start)
        let lo = CalendarMath.ordinal(from)
        var hi = CalendarMath.ordinal(to)
        if case let .until(last) = end { hi = min(hi, CalendarMath.ordinal(last)) }
        var out: [Day] = []
        guard hi >= x.start, hi >= lo, limit > 0 else { return out }
        if x.start >= lo { out.append(start) }
        var produced = 1
        let count: Int? = if case let .count(n) = end { n } else { nil }
        if count == 1 || out.count >= limit { return out }
        // Without COUNT nothing before `from` matters: start a period early to be safe.
        var k = count == nil ? max(0, x.periodsBefore(lo) - 1) : 0
        var work = 0
        while work < RepeatExpansion.maxWork {
            guard let period = x.period(k), period.first <= hi else { break }
            let step = switch frequency {
            case .yearly: 366
            case .monthly: 31
            case .weekly: 7
            case .daily: 1
            }
            work += step
            for n in period.days {
                if n <= x.start { continue }
                if n > hi { return out }
                produced += 1
                if n >= lo {
                    out.append(CalendarMath.day(ordinal: n))
                    if out.count >= limit { return out }
                }
                if let count, produced >= count { return out }
            }
            k += 1
        }
        return out
    }

    /// Whether `day` is an occurrence of the rule starting on `start`.
    func occurs(on day: Day, start: Day) -> Bool {
        occurrences(start: start, from: day, to: day, limit: 1).count == 1
    }
}

/// A rule ready to expand: days as numbers (`CalendarMath.ordinal`), weekdays 0 = Sunday … 6 =
/// Saturday, and the day parts a rule without any takes from its start.
private struct RepeatExpansion {
    /// Candidate days looked at per expansion at most.
    static let maxWork = 1_000_000
    static let maxYear = 9999

    let rule: RepeatRule
    let start: Int
    let startDay: Day
    /// (weekday 0 = Sunday, ordinal; nil: every such weekday)
    let weekdays: [(weekday: Int, ordinal: Int?)]
    let monthDays: [Int]
    let months: [Int]
    let weekStart: Int

    init(_ rule: RepeatRule, start: Day) {
        self.rule = rule
        self.start = CalendarMath.ordinal(start)
        startDay = start
        var weekdays = rule.weekdays.map { (weekday: $0.weekday - 1, ordinal: $0.ordinal) }
        var monthDays = rule.monthDays, months = rule.months
        // Without a day part the rule repeats its start's day (RFC 5545, as python-dateutil does).
        if rule.weekNumbers.isEmpty && rule.yearDays.isEmpty && monthDays.isEmpty && weekdays.isEmpty {
            switch rule.frequency {
            case .yearly:
                if months.isEmpty { months = [start.month] }
                monthDays = [start.day]
            case .monthly: monthDays = [start.day]
            case .weekly: weekdays = [(CalendarMath.weekday(start), nil)]
            case .daily: break
            }
        }
        self.weekdays = weekdays
        self.monthDays = monthDays
        self.months = months
        // WKST: Monday unless the rule says otherwise.
        weekStart = (rule.weekStart ?? 2) - 1
    }

    private static func ordinal(_ y: Int, _ m: Int, _ d: Int) -> Int {
        CalendarMath.ordinal(Day(year: y, month: m, day: d))
    }

    private static func weekday(_ n: Int) -> Int { ((n % 7) + 7 + 4) % 7 }

    /// The days of period `k` (0: the one the start is in) that the rule picks, sorted, and the
    /// period's first day.
    func period(_ k: Int) -> (first: Int, days: [Int])? {
        let interval = rule.interval
        let first: Int, candidates: [Int]
        switch rule.frequency {
        case .daily:
            first = start + k * interval
            candidates = [first]
        case .weekly:
            let week0 = start - ((Self.weekday(start) - weekStart + 7) % 7)
            first = week0 + 7 * k * interval
            candidates = Array(first..<first + 7)
        case .monthly:
            let index = startDay.year * 12 + (startDay.month - 1) + k * interval
            let y = index / 12, m = index % 12 + 1
            if y > Self.maxYear { return nil }
            first = Self.ordinal(y, m, 1)
            candidates = Array(first..<first + CalendarMath.daysInMonth(year: y, month: m))
        case .yearly:
            let y = startDay.year + k * interval
            if y > Self.maxYear { return nil }
            first = Self.ordinal(y, 1, 1)
            candidates = Array(first..<first + (CalendarMath.isLeap(y) ? 366 : 365))
        }
        if CalendarMath.day(ordinal: first).year > Self.maxYear { return nil }
        var days = candidates.filter(matches)
        if !rule.setPositions.isEmpty {
            var picked = Set<Int>()
            for p in rule.setPositions {
                let i = p > 0 ? p - 1 : days.count + p
                if i >= 0 && i < days.count { picked.insert(days[i]) }
            }
            days = picked.sorted()
        }
        return (first, days)
    }

    private func matches(_ n: Int) -> Bool {
        let day = CalendarMath.day(ordinal: n)
        let (y, m, d) = (day.year, day.month, day.day)
        if !months.isEmpty && !months.contains(m) { return false }
        if !rule.weekNumbers.isEmpty && !inWeeks(n, year: y) { return false }
        if !rule.yearDays.isEmpty {
            let yd = n - Self.ordinal(y, 1, 1) + 1
            let neg = yd - (CalendarMath.isLeap(y) ? 366 : 365) - 1
            if !rule.yearDays.contains(yd) && !rule.yearDays.contains(neg) { return false }
        }
        let monthLength = CalendarMath.daysInMonth(year: y, month: m)
        if !monthDays.isEmpty {
            let neg = d - monthLength - 1
            if !monthDays.contains(d) && !monthDays.contains(neg) { return false }
        }
        if !weekdays.isEmpty {
            let wd = Self.weekday(n)
            // Ordinals count within the month (monthly, or yearly with BYMONTH), else the year.
            let inMonth = rule.frequency == .monthly || (rule.frequency == .yearly && !rule.months.isEmpty)
            let scopeFirst = inMonth ? Self.ordinal(y, m, 1) : Self.ordinal(y, 1, 1)
            let scopeLast = inMonth ? Self.ordinal(y, m, monthLength) : Self.ordinal(y, 12, 31)
            let pos = (n - scopeFirst) / 7 + 1
            let neg = -((scopeLast - n) / 7 + 1)
            if !weekdays.contains(where: { $0.weekday == wd && ($0.ordinal == nil || $0.ordinal == pos || $0.ordinal == neg) }) {
                return false
            }
        }
        return true
    }

    /// The first day of week 1 of year `y` (the first week with at least 4 days in the year).
    private func week1Start(_ y: Int) -> Int {
        let jan1 = Self.ordinal(y, 1, 1)
        let off = (Self.weekday(jan1) - weekStart + 7) % 7
        return off <= 3 ? jan1 - off : jan1 + (7 - off)
    }

    /// Whether day `n` of year `y` is in one of the rule's weeks (positive or negative numbers).
    private func inWeeks(_ n: Int, year y: Int) -> Bool {
        let start = week1Start(y), next = week1Start(y + 1)
        let no: Int, neg: Int
        if n < start {
            // The last week of the year before.
            no = (start - week1Start(y - 1)) / 7
            neg = -1
        } else if n >= next {
            // Week 1 of the next year.
            no = 1
            neg = -((week1Start(y + 2) - next) / 7)
        } else {
            no = (n - start) / 7 + 1
            neg = no - (next - start) / 7 - 1
        }
        return rule.weekNumbers.contains(no) || rule.weekNumbers.contains(neg)
    }

    /// How many periods lie between the start's and day `n`'s (to skip ahead without COUNT).
    func periodsBefore(_ n: Int) -> Int {
        guard n > start else { return 0 }
        let b = CalendarMath.day(ordinal: n)
        switch rule.frequency {
        case .daily: return (n - start) / rule.interval
        case .weekly: return (n - start) / 7 / rule.interval
        case .monthly: return (b.year * 12 + b.month - (startDay.year * 12 + startDay.month)) / rule.interval
        case .yearly: return (b.year - startDay.year) / rule.interval
        }
    }
}

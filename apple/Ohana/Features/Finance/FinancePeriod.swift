import Foundation

/// The period the finance page shows: a month, a year, or all time (web finance-store.ts Period).
struct FinancePeriod: Hashable {
    enum Mode: String, CaseIterable, Hashable, Identifiable {
        case month, year, all
        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: String(localized: "Month")
            case .year: String(localized: "Year")
            case .all: String(localized: "All time")
            }
        }
    }

    var mode: Mode
    var year: Int
    /// 1 … 12
    var month: Int

    static func current(_ today: Day = .today) -> FinancePeriod {
        FinancePeriod(mode: .month, year: today.year, month: today.month)
    }

    /// The period as a date range (none for all time).
    var range: (from: String?, to: String?) {
        switch mode {
        case .all: (nil, nil)
        case .year: (String(format: "%04d-01-01", year), String(format: "%04d-12-31", year))
        case .month:
            (String(format: "%04d-%02d-01", year, month),
             String(format: "%04d-%02d-%02d", year, month, FinanceDates.daysIn(year: year, month: month)))
        }
    }

    var query: [String: String?] {
        let (from, to) = range
        return ["from": from, "to": to]
    }

    /// The day whose balances the period shows: its last day, or today while it runs (none for
    /// all time, which shows them now).
    func balanceDay(today: Day = .today) -> String? {
        let (from, to) = range
        guard let from, let to else { return nil }
        let now = today.description
        return from <= now && now <= to ? now : to
    }

    /// The previous / next month or year.
    func stepped(_ step: Int) -> FinancePeriod {
        var next = self
        switch mode {
        case .all: break
        case .year: next.year += step
        case .month:
            let m = month - 1 + step
            next.year += Int((Double(m) / 12).rounded(.down))
            next.month = ((m % 12) + 12) % 12 + 1
        }
        return next
    }

    /// "October 2026", "2026", "All time".
    var title: String {
        switch mode {
        case .all: String(localized: "All time")
        case .year: String(year)
        case .month:
            (Day(year: year, month: month, day: 1).date).formatted(.dateTime.month(.wide).year())
        }
    }

    // MARK: Comparison

    /// What the period is compared with: a month with itself and the month before; a year by
    /// its average month with the year before's; all time by its average month. Averages count
    /// only completed months (not the running one).
    func comparisonRanges(today: Day = .today) -> [FinanceComparisonRange] {
        // The last completed day: the end of last month.
        let done = Day(year: today.year, month: today.month, day: 1).adding(days: -1).description
        func average(_ key: FinanceComparisonKey, _ range: (from: String?, to: String?)) -> FinanceComparisonRange {
            FinanceComparisonRange(key: key, average: true, from: range.from,
                                   to: range.to.map { $0 < done ? $0 : done } ?? done)
        }
        switch mode {
        case .month:
            var previous = self
            previous = previous.stepped(-1)
            let (from, to) = range
            let (pFrom, pTo) = previous.range
            return [
                FinanceComparisonRange(key: .month, average: false, from: from, to: to!),
                FinanceComparisonRange(key: .lastMonth, average: false, from: pFrom, to: pTo!),
            ]
        case .year:
            var last = self
            last.year -= 1
            return [average(.year, range), average(.lastYear, last.range)]
        case .all:
            return [average(.all, (nil, nil))]
        }
    }
}

/// The months from `a` to `b` (YYYY-MM), both counted.
func financeMonthsBetween(_ a: String, _ b: String) -> Int {
    func parts(_ m: String) -> (Int, Int) {
        let p = m.split(separator: "-").compactMap { Int($0) }
        return (p.first ?? 0, p.count > 1 ? p[1] : 1)
    }
    let (ay, am) = parts(a), (by, bm) = parts(b)
    return (by - ay) * 12 + (bm - am) + 1
}

enum FinanceComparisonKey: String, Hashable {
    case month, lastMonth, year, lastYear, all

    var title: String {
        switch self {
        case .month: String(localized: "This month")
        case .lastMonth: String(localized: "Last month")
        case .year: String(localized: "This year")
        case .lastYear: String(localized: "Last year")
        case .all: String(localized: "All time")
        }
    }
}

struct FinanceComparisonRange: Hashable {
    var key: FinanceComparisonKey
    var average: Bool
    var from: String?
    var to: String
}

/// One column of the comparison: income, expenses and per category, per month. An average is
/// over the range's completed months, from the first one with transactions on.
struct FinanceComparison: Hashable {
    var key: FinanceComparisonKey
    var average: Bool
    var first: String?
    var last: String?
    var months: Int
    var incomeCents: Int
    var expenseCents: Int
    /// By category id ("" for none).
    var categories: [String: (income: Int, expense: Int)]

    static func == (a: FinanceComparison, b: FinanceComparison) -> Bool {
        a.key == b.key && a.first == b.first && a.last == b.last && a.months == b.months
            && a.incomeCents == b.incomeCents && a.expenseCents == b.expenseCents
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(first)
        hasher.combine(months)
    }

    static func none(_ range: FinanceComparisonRange, last: String? = nil) -> FinanceComparison {
        FinanceComparison(key: range.key, average: range.average, first: nil, last: last, months: 0,
                          incomeCents: 0, expenseCents: 0, categories: [:])
    }

    /// The column from the summary of its range (finance-store.ts loadComparisons).
    static func from(_ summary: FinanceSummary, range: FinanceComparisonRange) -> FinanceComparison {
        let last = String(range.to.prefix(7))
        guard let first = range.average ? summary.months.first?.month : last else {
            return .none(range, last: last)
        }
        let months = max(1, financeMonthsBetween(first, last))
        func per(_ cents: Int) -> Int { Int((Double(cents) / Double(months)).rounded()) }
        var categories: [String: (income: Int, expense: Int)] = [:]
        for c in summary.categories {
            categories[c.categoryId ?? ""] = (per(c.incomeCents), per(c.expenseCents))
        }
        return FinanceComparison(key: range.key, average: range.average, first: first, last: last, months: months,
                                 incomeCents: per(summary.incomeCents), expenseCents: per(summary.expenseCents),
                                 categories: categories)
    }

    /// Amounts per top-level category ("" = uncategorized), with their subcategories.
    func byTop(_ tree: FinanceCategoryTree) -> (income: [String: Int], expense: [String: Int]) {
        var income: [String: Int] = [:], expense: [String: Int] = [:]
        for (id, cents) in categories {
            let top = tree.top(of: id.isEmpty ? nil : id)
            if cents.income != 0 { income[top, default: 0] += cents.income }
            if cents.expense != 0 { expense[top, default: 0] += cents.expense }
        }
        return (income, expense)
    }

    /// "Ø Jan – Sep 2026 · 9 months", or the month; nil when there is nothing yet.
    var detail: String? {
        guard months > 0, let first, let last else { return nil }
        let format = Date.FormatStyle.dateTime.month(.abbreviated).year()
        if average {
            let span = first == last
                ? FinanceDates.monthDate(first).formatted(format)
                : "\(FinanceDates.monthDate(first).formatted(format)) – \(FinanceDates.monthDate(last).formatted(format))"
            return "Ø \(span) · " + String(localized: "\(months) months")
        }
        return FinanceDates.monthDate(first).formatted(.dateTime.month(.wide).year())
    }
}

/// Where a value is against a benchmark range (benchmark-view.tsx standing).
enum FinanceStanding: Equatable {
    case above(Int), aboveZero, below(Int), on, lowerHalf, upperHalf

    /// `higherIsGood`: income; expenses are better lower.
    static func of(_ cents: Int, range: FinanceCentsRange) -> FinanceStanding {
        let low = range.lowCents, high = range.highCents
        let off: Int? = cents < low
            ? -Int((Double(low - cents) / Double(low) * 100).rounded())
            : cents > high ? (high != 0 ? Int((Double(cents - high) / Double(high) * 100).rounded()) : nil) : 0
        guard let off else { return .aboveZero }
        if off > 0 { return .above(off) }
        if off < 0 { return .below(-off) }
        if low == high || cents < low || cents > high { return .on }
        return Double(cents - low) / Double(high - low) >= 0.5 ? .upperHalf : .lowerHalf
    }

    /// True: good, false: bad, nil: neither.
    func tone(higherIsGood: Bool) -> Bool? {
        switch self {
        case .above, .aboveZero: higherIsGood
        case .below: !higherIsGood
        default: nil
        }
    }

    var text: String {
        switch self {
        case let .above(n): String(localized: "\(n) % above")
        case .aboveZero: String(localized: "above")
        case let .below(n): String(localized: "\(n) % below")
        case .on: String(localized: "on average")
        case .lowerHalf: String(localized: "in the range, lower half")
        case .upperHalf: String(localized: "in the range, upper half")
        }
    }
}

import SwiftUI

/// GET /api/v1/families/{id}/overview (web/lib/families/dashboard.ts `Dashboard`).
struct OverviewDashboard: Codable, Hashable {
    let today: Day
    let calendar: OverviewCalendarSummary
    /// Names of today's "away" types (no meal is planned then).
    let awayToday: [String]
    let todayEvents: [OverviewEvent]
    let upcoming: [OverviewUpcomingItem]
    let meals: OverviewMealsSummary
    let finance: OverviewMonthSummary
    let searches: [OverviewSearchFind]
    /// Birthdays from today to 29 days on, by day.
    let birthdays: [OverviewBirthday]
}

/// web/lib/calendar/summary.ts `CalendarSummary`.
struct OverviewCalendarSummary: Codable, Hashable {
    /// The first uncovered weekday from today on, if any.
    let nextGap: Day?
    let upcoming: [OverviewEntryRun]
}

struct OverviewEntryRun: Codable, Hashable {
    let name: String
    let color: String
    let from: Day
    let to: Day
}

/// web/lib/calendar/events.ts `PublicEvent`.
struct OverviewEvent: Codable, Hashable, Identifiable {
    let id: String
    let date: Day
    /// "HH:MM", or nil for all day.
    let start: String?
    let end: String?
    let title: String
    let location: String
    let person: String
    let note: String
    let url: String
    /// "manual" | "appointment"
    let source: String
    /// The appointment search it came from.
    let searchId: String?

    /// "Title · Person", like the web's overview.
    var label: String { person.isEmpty ? title : "\(title) · \(person)" }
}

/// One line of "coming up": a run of a calendar type, or a timed event.
enum OverviewUpcomingItem: Codable, Hashable, Identifiable {
    case entry(date: Day, to: Day, name: String, color: String)
    case event(date: Day, event: OverviewEvent)

    private enum Keys: String, CodingKey { case kind, date, to, name, color, event }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let date = try c.decode(Day.self, forKey: .date)
        switch try c.decode(String.self, forKey: .kind) {
        case "event":
            self = .event(date: date, event: try c.decode(OverviewEvent.self, forKey: .event))
        default:
            self = .entry(date: date, to: try c.decode(Day.self, forKey: .to),
                          name: try c.decode(String.self, forKey: .name),
                          color: try c.decode(String.self, forKey: .color))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .entry(date, to, name, color):
            try c.encode("entry", forKey: .kind)
            try c.encode(date, forKey: .date)
            try c.encode(to, forKey: .to)
            try c.encode(name, forKey: .name)
            try c.encode(color, forKey: .color)
        case let .event(date, event):
            try c.encode("event", forKey: .kind)
            try c.encode(date, forKey: .date)
            try c.encode(event, forKey: .event)
        }
    }

    var id: String {
        switch self {
        case let .entry(date, _, name, _): "entry|\(name)|\(date)"
        case let .event(_, event): "event|\(event.id)"
        }
    }

    var date: Day {
        switch self {
        case let .entry(date, _, _, _), let .event(date, _): date
        }
    }
}

/// web/lib/meals/queries/meal-plan.ts `MealsSummary`.
struct OverviewMealsSummary: Codable, Hashable {
    struct Today: Codable, Hashable {
        let recipeId: String
        let recipeTitle: String
        let isLeftover: Bool
    }

    struct Shopping: Codable, Hashable {
        let id: String
        let shoppingDate: Day?
        let open: Int
        let total: Int

        /// The share already bought, 0…1.
        var progress: Double { total > 0 ? Double(total - open) / Double(total) : 0 }
    }

    let today: Today?
    let shopping: Shopping?
}

/// web/lib/finance/summary.ts `MonthSummary`.
struct OverviewMonthSummary: Codable, Hashable {
    struct TopExpense: Codable, Hashable {
        let categoryId: String
        let name: String
        let icon: String
        let color: String
        let expenseCents: Int
    }

    let currency: String
    /// "YYYY-MM"
    let month: String
    let incomeCents: Int
    let expenseCents: Int
    let count: Int
    let topExpense: TopExpense?
    let balanceCents: Int?

    var netCents: Int { incomeCents - expenseCents }

    /// The first day of the month, for its name.
    var monthDay: Day? { Day("\(month)-01") }
}

/// web/lib/families/dashboard.ts `SearchFind`.
struct OverviewSearchFind: Codable, Hashable, Identifiable {
    struct First: Codable, Hashable {
        let resultId: Int
        let doctorName: String
        /// ISO 8601
        let slot: String

        var date: Date? { Date.server(slot) }
    }

    let id: String
    let name: String
    let enabled: Bool
    let lastStatus: String
    let first: First?
    /// How many doctors the latest run found.
    let doctors: Int
}

/// web/lib/families/birthdays.ts `BirthdayDay`.
struct OverviewBirthday: Codable, Hashable, Identifiable {
    let day: Day
    let name: String
    /// The age they turn that day.
    let age: Int

    var id: String { "\(name)|\(day)" }
}

enum OverviewFormat {
    /// Cents as money in the family's currency.
    static func money(_ cents: Int, currency: String) -> String {
        Money.format(Decimal(cents) / 100, currency: currency)
    }

    /// "+12,00 €" / "−3,50 €": with a sign, like the web's balance.
    static func signedMoney(_ cents: Int, currency: String) -> String {
        let text = money(abs(cents), currency: currency)
        return cents > 0 ? "+" + text : cents < 0 ? "−" + text : text
    }

    /// "3 Nov" or "3 Nov – 7 Nov" for a run of days.
    static func range(_ from: Day, _ to: Day) -> String {
        from == to ? from.formatted() : "\(from.formatted()) – \(to.formatted())"
    }

    /// A greeting by the time of day.
    static func greeting(hour: Int, name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch hour {
        case 5..<12:
            return trimmed.isEmpty ? String(localized: "Good morning") : String(localized: "Good morning, \(trimmed)")
        case 12..<18:
            return trimmed.isEmpty ? String(localized: "Good afternoon") : String(localized: "Good afternoon, \(trimmed)")
        default:
            return trimmed.isEmpty ? String(localized: "Good evening") : String(localized: "Good evening, \(trimmed)")
        }
    }
}

extension Color {
    /// A color from the server's "#rrggbb" (calendar types, categories); gray when unreadable.
    init(overviewHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            self = .gray
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

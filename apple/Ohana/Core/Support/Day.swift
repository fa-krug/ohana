import Foundation

/// A calendar day as the server writes it: "YYYY-MM-DD", in the user's own calendar (no time
/// zone: a day is the same day everywhere, like the web app's lib/calendar/dates.ts).
struct Day: Hashable, Comparable, Codable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(_ string: String) {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    static var today: Day { Day(Date()) }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = Day(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a day: \(text)"))
        }
        self = day
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Noon of the day in the current time zone (safe from daylight-saving edges).
    var date: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func adding(days: Int) -> Day { Day(Calendar.current.date(byAdding: .day, value: days, to: date)!) }
    func adding(months: Int) -> Day { Day(Calendar.current.date(byAdding: .month, value: months, to: date)!) }

    var weekday: Int { Calendar.current.component(.weekday, from: date) }

    static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    func formatted(_ style: Date.FormatStyle = .dateTime.weekday(.abbreviated).day().month(.abbreviated)) -> String {
        date.formatted(style)
    }
}

extension Date {
    /// Parses the server's timestamps: ISO 8601 with or without fractional seconds, or epoch ms.
    static func server(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractional.parse(text) { return date }
        if let ms = Double(text) { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }
}

/// Amounts of money: the server sends decimal strings or numbers; shown in the family's currency.
enum Money {
    static func format(_ amount: Double, currency: String) -> String {
        amount.formatted(.currency(code: currency.isEmpty ? "EUR" : currency))
    }

    static func format(_ amount: Decimal, currency: String) -> String {
        amount.formatted(.currency(code: currency.isEmpty ? "EUR" : currency))
    }
}

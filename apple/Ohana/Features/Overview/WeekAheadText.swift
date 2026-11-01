import Foundation

/// What a week-ahead issue says, in the app's language: one sentence from its `kind`, `data`
/// and events ("Dentist and Swimming lesson overlap by 30 min"). The server sends only the
/// facts, so the sentence follows the device's language. A kind the app doesn't know (a newer
/// server's) lists its events.
enum WeekAheadText {
    static func sentence(_ issue: WeekAheadIssue) -> String {
        specific(issue) ?? generic(issue)
    }

    /// A short name for the kind ("Overlap"), for the rows' caption.
    static func title(kind: String) -> String {
        switch kind {
        case "overlap": String(localized: "Overlap")
        case "tight_transfer": String(localized: "Tight transfer")
        case "during_trip": String(localized: "During a trip")
        case "packed_day": String(localized: "Packed day")
        case "long_travel_day": String(localized: "Long day on the road")
        case "travel_week": String(localized: "Lots of travel")
        case "short_night": String(localized: "Short night")
        case "away_clash": String(localized: "While away")
        case "drivers_needed": String(localized: "Drivers needed")
        case "birthday_away": String(localized: "Birthday")
        case "unassigned_overlap": String(localized: "Who goes?")
        default: String(localized: "Worth a look")
        }
    }

    // MARK: Kinds

    private static func specific(_ issue: WeekAheadIssue) -> String? {
        let data = issue.data
        let titles = issue.events.map(\.title)
        func event(_ i: Int) -> String? {
            titles.indices.contains(i) && !titles[i].isEmpty ? titles[i] : nil
        }
        switch issue.kind {
        case "overlap":
            guard let a = event(0), let b = event(1) else { return nil }
            if let minutes = int(data["minutes"]), minutes > 0 {
                let by = duration(minutes)
                return String(localized: "\(a) and \(b) overlap by \(by)")
            }
            return String(localized: "\(a) and \(b) overlap")

        case "unassigned_overlap":
            guard let a = event(0), let b = event(1) else { return nil }
            if let minutes = int(data["minutes"]), minutes > 0 {
                let by = duration(minutes)
                return String(localized: "\(a) and \(b) overlap by \(by): who goes?")
            }
            return String(localized: "\(a) and \(b) overlap: who goes?")

        case "tight_transfer":
            guard let a = event(0), let b = event(1) else { return nil }
            let gap = int(data["gapMinutes"]) ?? 0
            let lead: String
            if gap > 0 {
                let time = duration(gap)
                lead = String(localized: "Only \(time) from \(a) to \(b)")
            } else {
                lead = String(localized: "No time between \(a) and \(b)")
            }
            let tail: String
            if let travel = int(data["travelMinutes"]), travel > 0 {
                let time = duration(about(travel))
                if let km = double(data["km"]), km > 0 {
                    let distance = kilometers(km)
                    tail = String(localized: "about \(time) on the road (\(distance) km)")
                } else {
                    tail = String(localized: "about \(time) on the road")
                }
            } else {
                tail = String(localized: "somewhere else")
            }
            return "\(lead) — \(tail)"

        case "during_trip":
            // The trip first, then the timed event elsewhere.
            guard let trip = event(0), let other = event(1) else { return nil }
            return String(localized: "\(other) during \(trip)")

        case "packed_day":
            let count = int(data["events"]) ?? issue.events.count
            let events = String(localized: "\(count) events")
            if let hours = double(data["hours"]), hours > 0 {
                let booked = number(hours)
                return String(localized: "\(events), \(booked) hours booked")
            }
            return String(localized: "\(events) in one day")

        case "long_travel_day":
            let minutes = int(data["minutes"]).flatMap { $0 > 0 ? $0 : nil }
            let km = double(data["km"]).flatMap { $0 > 0 ? $0 : nil }
            switch (minutes, km) {
            case let (minutes?, km?):
                let time = duration(about(minutes)), distance = kilometers(km)
                return String(localized: "About \(time) on the road (\(distance) km)")
            case let (minutes?, nil):
                let time = duration(about(minutes))
                return String(localized: "About \(time) on the road")
            case let (nil, km?):
                let distance = kilometers(km)
                return String(localized: "About \(distance) km on the road")
            case (nil, nil):
                return nil
            }

        case "travel_week":
            guard let count = int(data["days"]), count > 0 else { return nil }
            let days = String(localized: "\(count) days")
            if let week = data["weekStart"]?.stringValue.flatMap(Day.init) {
                let start = week.formatted(.dateTime.day().month(.abbreviated))
                return String(localized: "Far from home on \(days) in the week of \(start)")
            }
            return String(localized: "Far from home on \(days) in one week")

        case "short_night":
            guard let hours = double(data["hours"]) else { return nil }
            let night = number(hours)
            if let a = event(0), let b = event(1) {
                return String(localized: "Only \(night) hours between \(a) and \(b)")
            }
            return String(localized: "Only \(night) hours of night")

        case "away_clash":
            guard let a = event(0) else { return nil }
            let name = data["away"]?.stringValue ?? ""
            let away = name.isEmpty ? String(localized: "Away") : String(localized: "Away (\(name))")
            let count = data["dates"]?.arrayValue?.count ?? 0
            if count > 1 {
                let days = String(localized: "\(count) days")
                return String(localized: "\(away) — \(a) on \(days)")
            }
            return "\(away) — \(a)"

        case "drivers_needed":
            guard let count = int(data["children"]) else { return nil }
            let children = String(localized: "\(count) children at once")
            let free = int(data["adults"]) ?? 0
            let adults = free > 0 ? String(localized: "\(free) adults free") : String(localized: "no adult free")
            return "\(children), \(adults)"

        case "birthday_away":
            guard let name = data["name"]?.stringValue, !name.isEmpty else { return nil }
            if let age = int(data["age"]) {
                return String(localized: "Away when \(name) turns \(age)")
            }
            return String(localized: "Away on \(name)’s birthday")

        default:
            return nil
        }
    }

    /// A kind the app doesn't know, or one whose data is missing: its events.
    private static func generic(_ issue: WeekAheadIssue) -> String {
        let titles = issue.events.map(\.title).filter { !$0.isEmpty }
        guard !titles.isEmpty else { return String(localized: "Worth a look") }
        let list = titles.formatted(.list(type: .and))
        return String(localized: "Worth a look: \(list)")
    }

    // MARK: Numbers

    /// "25 min", "2 h", "3 h 35 min".
    static func duration(_ minutes: Int) -> String {
        let total = max(0, minutes)
        if total < 60 { return String(localized: "\(total) min") }
        let hours = total / 60, rest = total % 60
        if rest == 0 { return String(localized: "\(hours) h") }
        return String(localized: "\(hours) h \(rest) min")
    }

    /// An estimate to the nearest 5 minutes (from a quarter of an hour on).
    static func about(_ minutes: Int) -> Int {
        minutes < 15 ? minutes : Int((Double(minutes) / 5).rounded()) * 5
    }

    /// "6.8" below 10 km, whole kilometers beyond.
    static func kilometers(_ km: Double) -> String {
        km < 10 ? number(km) : Int(km.rounded()).formatted()
    }

    /// At most one decimal: "9.5", "7".
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func int(_ value: JSONValue?) -> Int? {
        double(value).map { Int($0.rounded()) }
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case let .number(n)?: n
        case let .string(s)?: Double(s)
        default: nil
        }
    }
}

import Foundation

extension DemoServer {
    /// The demo's calendar routes that depend on the query; the rest are files.
    ///
    /// GET /families/demo?year= (family-routes.ts `familyState`) from `demo-calendar.json`: the
    /// same types in every year, the entries of its spans (`{type, from, to}`), notes and events
    /// that fall in the year (each occurrence of a repeating one under every day it covers), and
    /// the birthdays of its `people` in it. GET /events (`from`/`to`, `year` or `raw=1`) and
    /// /events/{id} answer from the same events.
    static func calendar(_ request: Request) -> JSONValue? {
        if let events = self.events(request) { return events }
        guard request.familyPath == "", let file = request.json("calendar") else { return nil }
        let year = request.query["year"].flatMap { Int($0) } ?? request.today.year
        let inYear = { (key: String) in Day(key)?.year == year }

        let types: [JSONValue] = (file["types"]?.arrayValue ?? []).map { type in
            var type = type.objectValue ?? [:]
            type["year"] = .number(Double(year))
            return .object(type)
        }
        let order = types.compactMap { $0["id"]?.stringValue }

        var entries: [String: [String]] = [:]
        for span in file["spans"]?.arrayValue ?? [] {
            guard let type = span["type"]?.stringValue,
                  var day = span["from"]?.stringValue.flatMap(Day.init),
                  let last = span["to"]?.stringValue.flatMap(Day.init) else { continue }
            while day <= last {
                if day.year == year { entries[day.description, default: []].append(type) }
                day = day.adding(days: 1)
            }
        }
        let rank = { (id: String) in order.firstIndex(of: id) ?? order.count }
        let entriesJSON = entries.mapValues { ids in
            JSONValue.array(Array(Set(ids)).sorted { rank($0) < rank($1) }.map { .string($0) })
        }

        let notes = (file["notes"]?.objectValue ?? [:]).filter { inYear($0.key) }

        var events: [String: [JSONValue]] = [:]
        let first = Day(year: year, month: 1, day: 1), last = Day(year: year, month: 12, day: 31)
        for event in file["events"]?.arrayValue ?? [] {
            for occurrence in occurrences(of: event, from: first, to: last) {
                guard let date = occurrence["date"]?.stringValue.flatMap(Day.init),
                      let end = occurrence["endDate"]?.stringValue.flatMap(Day.init) else { continue }
                for day in CalendarMath.range(max(date, first), min(end, last)) {
                    events[day.description, default: []].append(occurrence)
                }
            }
        }
        // Like the server: all day (and the later days of one that spans days) first, then by start.
        for (key, list) in events {
            let start = { (event: JSONValue) in event["date"]?.stringValue == key ? event["start"]?.stringValue ?? "" : "" }
            events[key] = list.enumerated().sorted { (start($0.element), $0.offset) < (start($1.element), $1.offset) }.map(\.element)
        }

        var birthdays: [String: [JSONValue]] = [:]
        for person in file["people"]?.arrayValue ?? [] {
            guard let name = person["name"]?.stringValue,
                  let born = person["birthday"]?.stringValue.flatMap(Day.init), born.year < year else { continue }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let day = Day(year: year, month: born.month, day: born.month == 2 && born.day == 29 && !leap ? 28 : born.day)
            birthdays[day.description, default: []].append(
                .object(["name": .string(name), "age": .number(Double(year - born.year))]))
        }

        let family = file["family"] ?? .null
        let typeYears = Set([request.today.year - 1, request.today.year, request.today.year + 1, year]).sorted()
        return .object([
            "family": family,
            "session": family,
            "types": .array(types),
            "typeYears": .array(typeYears.map { .number(Double($0)) }),
            "entries": .object(entriesJSON),
            "notes": .object(notes),
            "events": .object(events.mapValues { .array($0) }),
            "birthdays": .object(birthdays.mapValues { .array($0) }),
        ])
    }

    /// GET /events?from=&to= (or `year`): the occurrences in the range; `raw=1`: the events as
    /// stored; GET /events/{id}: one of them.
    private static func events(_ request: Request) -> JSONValue? {
        guard let path = request.familyPath, path == "/events" || path.hasPrefix("/events/"),
              let file = request.json("calendar") else { return nil }
        let stored = (file["events"]?.arrayValue ?? []).map(series)
        if path.hasPrefix("/events/") {
            let id = String(path.dropFirst("/events/".count))
            return stored.first { $0["id"]?.stringValue == id }
        }
        if request.query["raw"] == "1" { return .object(["events": .array(stored)]) }
        let year = request.query["year"].flatMap { Int($0) }
        guard let from = request.query["from"].flatMap(Day.init) ?? year.map({ Day(year: $0, month: 1, day: 1) }),
              let to = request.query["to"].flatMap(Day.init) ?? year.map({ Day(year: $0, month: 12, day: 31) }) else {
            return .object(["events": .array([])])
        }
        let list = (file["events"]?.arrayValue ?? []).flatMap { occurrences(of: $0, from: from, to: to) }
            .sorted { ($0["date"]?.stringValue ?? "", $0["start"]?.stringValue ?? "") < ($1["date"]?.stringValue ?? "", $1["start"]?.stringValue ?? "") }
        return .object(["events": .array(list)])
    }

    /// An event of the file as stored (events.ts `EventSeries`).
    private static func series(_ event: JSONValue) -> JSONValue {
        var object = event.objectValue ?? [:]
        object["endDate"] = object["endDate"] ?? object["date"]
        object["rrule"] = object["rrule"] ?? .null
        object["exdates"] = object["exdates"] ?? .array([])
        object["overrides"] = object["overrides"] ?? .array([])
        return .object(object)
    }

    /// The occurrences of an event of the file that overlap `from`…`to` (events.ts `PublicEvent`):
    /// the event itself when it doesn't repeat, else one per day its rule gives. The demo's rules
    /// only use FREQ, INTERVAL, COUNT and UNTIL.
    static func occurrences(of event: JSONValue, from: Day, to: Day) -> [JSONValue] {
        guard var object = event.objectValue, let date = object["date"]?.stringValue.flatMap(Day.init) else { return [] }
        let end = object["endDate"]?.stringValue.flatMap(Day.init) ?? date
        let length = CalendarMath.ordinal(end) - CalendarMath.ordinal(date)
        object["endDate"] = .string(end.description)
        guard let rrule = object["rrule"]?.stringValue, let rule = RepeatRule(rrule) else {
            object["occurrence"] = .null
            object["rrule"] = .null
            return date <= to && end >= from ? [.object(object)] : []
        }
        var out: [JSONValue] = []
        var n = 0
        while true {
            let day: Day
            switch rule.frequency {
            case .daily: day = CalendarMath.add(date, n * rule.interval)
            case .weekly: day = CalendarMath.add(date, n * rule.interval * 7)
            case .monthly: day = date.adding(months: n * rule.interval)
            case .yearly: day = date.adding(months: n * rule.interval * 12)
            }
            if day > to { break }
            if case let .count(count) = rule.end, n >= count { break }
            if case let .until(last) = rule.end, day > last { break }
            n += 1
            let last = CalendarMath.add(day, length)
            guard last >= from else { continue }
            var occurrence = object
            occurrence["occurrence"] = .string(day.description)
            occurrence["date"] = .string(day.description)
            occurrence["endDate"] = .string(last.description)
            out.append(.object(occurrence))
        }
        return out
    }
}

import Foundation

extension DemoServer {
    /// The demo's calendar routes that depend on the query; the rest are files.
    ///
    /// GET /families/demo?year= (family-routes.ts `familyState`) from `demo-calendar.json`: the
    /// same types in every year, the entries of its spans (`{type, from, to}`), notes and events
    /// that fall in the year, and the birthdays of its `people` in it.
    static func calendar(_ request: Request) -> JSONValue? {
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
        for event in file["events"]?.arrayValue ?? [] {
            guard let date = event["date"]?.stringValue, inYear(date) else { continue }
            events[date, default: []].append(event)
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
}

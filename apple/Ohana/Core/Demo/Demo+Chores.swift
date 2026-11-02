import Foundation

extension DemoServer {
    /// The demo's chores: the list is `demo-chores.json`; one chore (`/chores/{id}`, a link
    /// into the chores) is taken from it, and the agenda (`/chores/agenda?from=&to=`) made of it:
    /// a single chore on its day, a repeating one on each day of its rule (none ticked off),
    /// the open single chores before today overdue.
    static func chores(_ request: Request) -> JSONValue? {
        guard let path = request.familyPath, path.hasPrefix("/chores/"),
              let chores = request.json("chores")?["chores"]?.arrayValue else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        if parts[1] == "agenda" { return choreAgenda(chores, request) }
        guard let chore = chores.first(where: { $0["id"]?.stringValue == String(parts[1]) }) else { return nil }
        return .object(["chore": chore])
    }

    private static func choreAgenda(_ chores: [JSONValue], _ request: Request) -> JSONValue {
        guard let from = request.query["from"].flatMap(Day.init), let to = request.query["to"].flatMap(Day.init), from <= to else {
            return .object(["days": .array([]), "overdue": .array([])])
        }
        let today = request.query["today"].flatMap(Day.init) ?? request.today
        var byDay: [Day: [JSONValue]] = [:]
        var overdue: [(Day, JSONValue)] = []
        for chore in chores {
            guard let day = chore["day"]?.stringValue.flatMap(Day.init) else { continue }
            let repeating = chore["rrule"]?.stringValue != nil
            let days: [Day] = if repeating {
                chore["rrule"]?.stringValue.flatMap(RepeatRule.init)?.occurrences(start: day, from: from, to: to) ?? []
            } else {
                from <= day && day <= to ? [day] : []
            }
            for d in days { byDay[d, default: []].append(choreItem(chore, on: d, repeating: repeating)) }
            if !repeating, chore["done"]?.boolValue != true, day < today {
                overdue.append((day, choreItem(chore, on: day, repeating: false)))
            }
        }
        let order: [String: Int] = ["morning": 0, "day": 1, "evening": 2]
        func sorted(_ items: [JSONValue]) -> [JSONValue] {
            items.sorted {
                (order[$0["part"]?.stringValue ?? ""] ?? 1, $0["time"]?.stringValue ?? "", $0["title"]?.stringValue ?? "")
                    < (order[$1["part"]?.stringValue ?? ""] ?? 1, $1["time"]?.stringValue ?? "", $1["title"]?.stringValue ?? "")
            }
        }
        var days: [JSONValue] = []
        var day = from
        while day <= to {
            days.append(.object(["date": .string(day.description), "items": .array(sorted(byDay[day] ?? []))]))
            day = day.adding(days: 1)
        }
        return .object(["days": .array(days),
                        "overdue": .array(overdue.sorted { $0.0 < $1.0 }.map(\.1))])
    }

    /// A chore of the file on `day`, as the agenda lists it.
    private static func choreItem(_ chore: JSONValue, on day: Day, repeating: Bool) -> JSONValue {
        let done = !repeating && chore["done"]?.boolValue == true
        return .object([
            "choreId": chore["id"] ?? .null, "day": .string(day.description),
            "title": chore["title"] ?? .string(""), "note": chore["note"] ?? .string(""),
            "assignee": chore["assignee"] ?? .null, "part": chore["part"] ?? .string("day"),
            "time": chore["time"] ?? .null, "repeating": .bool(repeating),
            "done": .bool(done), "doneAt": done ? chore["doneAt"] ?? .null : .null,
            "doneBy": done ? chore["doneBy"] ?? .null : .null, "subscribed": chore["subscribed"] ?? .bool(false),
        ])
    }
}

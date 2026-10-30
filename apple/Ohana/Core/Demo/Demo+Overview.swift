import Foundation

extension DemoServer {
    /// The demo's overview (`/overview`): `demo-overview.json` with the birthdays of the next 30
    /// days worked out from the household's members and people (`demo-household.json`), like
    /// the server's `birthdaysIn`, so the ages and the members' fixed birthdays stay right
    /// whatever day it is.
    static func overview(_ request: Request) -> JSONValue? {
        guard request.familyPath == "/overview", case var .object(dashboard)? = request.json("overview") else {
            return nil
        }
        let household = request.json("household")
        let people = (household?["members"]?.arrayValue ?? []) + (household?["people"]?.arrayValue ?? [])
        let named = people.compactMap { person -> (name: String, birthday: Day)? in
            guard let name = person["name"]?.stringValue,
                  let birthday = person["birthday"]?.stringValue.flatMap(Day.init) else { return nil }
            return (name, birthday)
        }
        let days = birthdays(named, from: request.today, to: request.today.adding(days: 29))
        dashboard["birthdays"] = .array(days.map { day in
            .object(["day": .string(day.day.description), "name": .string(day.name), "age": .number(Double(day.age))])
        })
        if let finance = monthSummary(request) { dashboard["finance"] = finance }
        if let searches = searchFinds(request) { dashboard["searches"] = searches }
        return .object(dashboard)
    }

    /// The appointment searches as the appointments page has them (web/lib/families/dashboard.ts):
    /// the last run's status, its first find and how many doctors it found.
    private static func searchFinds(_ request: Request) -> JSONValue? {
        let sub = "/appointments"
        guard let list = DemoServer.appointments(Request(method: .get, path: "/api/v1/families/\(familyID)\(sub)", query: [:],
                                                          familyPath: sub, today: request.today, now: request.now)),
              let searches = list["searches"]?.arrayValue else { return nil }
        return .array(searches.map { search in
            let doctors = search["doctors"]?.arrayValue ?? []
            let first: JSONValue = doctors.first.map { d in
                .object(["resultId": d["resultId"] ?? .null, "doctorName": d["doctorName"] ?? .null, "slot": d["slot"] ?? .null])
            } ?? .null
            return .object([
                "id": search["id"] ?? .null,
                "name": search["name"] ?? .null,
                "enabled": search["enabled"] ?? .bool(false),
                "lastStatus": search["lastStatus"] ?? .null,
                "first": first,
                "doctors": .number(Double(doctors.count)),
            ])
        })
    }

    /// This month's finances from the demo's transactions, so the card matches the finance
    /// page (web/lib/finance/summary.ts `monthSummary`).
    private static func monthSummary(_ request: Request) -> JSONValue? {
        let today = request.today
        let month = String(format: "%04d-%02d", today.year, today.month)
        let last = Day(year: today.year, month: today.month, day: 1).adding(months: 1).adding(days: -1)
        func finance(_ sub: String, _ query: [String: String] = [:]) -> JSONValue? {
            DemoServer.finance(Request(method: .get, path: "/api/v1/families/\(familyID)\(sub)", query: query,
                                       familyPath: sub, today: today, now: request.now))
        }
        guard let overview = finance("/finance"),
              let summary = finance("/finance/summary", ["from": "\(month)-01", "to": last.description]) else { return nil }
        let categories = overview["categories"]?.arrayValue ?? []
        let byID = Dictionary(categories.compactMap { c in c["id"]?.stringValue.map { ($0, c) } }) { a, _ in a }
        func top(_ id: String) -> String {
            var id = id
            while let parent = byID[id]?["parentId"]?.stringValue { id = parent }
            return id
        }
        var byTop: [(id: String, cents: Double)] = []
        for c in summary["categories"]?.arrayValue ?? [] {
            guard let id = c["categoryId"]?.stringValue, byID[id] != nil else { continue }
            let cents = c["expenseCents"]?.doubleValue ?? 0
            let topID = top(id)
            if let i = byTop.firstIndex(where: { $0.id == topID }) { byTop[i].cents += cents } else { byTop.append((topID, cents)) }
        }
        var topExpense: JSONValue = .null
        if let best = byTop.filter({ $0.cents > 0 }).max(by: { $0.cents < $1.cents }), let c = byID[best.id] {
            topExpense = .object(["categoryId": .string(best.id), "name": c["name"] ?? .string(""), "icon": c["icon"] ?? .string(""),
                                  "color": c["color"] ?? .string(""), "expenseCents": .number(best.cents)])
        }
        let accounts = overview["accounts"]?.arrayValue ?? []
        let balance = accounts.reduce(0) { $0 + ($1["balanceCents"]?.doubleValue ?? 0) }
        return .object([
            "currency": summary["currency"] ?? .string("EUR"),
            "month": .string(month),
            "incomeCents": summary["incomeCents"] ?? .number(0),
            "expenseCents": summary["expenseCents"] ?? .number(0),
            "count": summary["count"] ?? .number(0),
            "topExpense": topExpense,
            "balanceCents": accounts.isEmpty ? .null : .number(balance),
        ])
    }

    /// The birthdays from `from` to `to` (inclusive), by day then name; 29 February falls on the
    /// 28th in other years (web/lib/families/birthdays.ts `birthdaysIn`).
    static func birthdays(_ people: [(name: String, birthday: Day)], from: Day, to: Day)
        -> [(day: Day, name: String, age: Int)] {
        var out: [(day: Day, name: String, age: Int)] = []
        for person in people {
            for year in max(from.year, person.birthday.year + 1)...max(to.year, person.birthday.year + 1) {
                let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
                let feb29 = person.birthday.month == 2 && person.birthday.day == 29
                let day = Day(year: year, month: person.birthday.month, day: feb29 && !leap ? 28 : person.birthday.day)
                if day >= from && day <= to { out.append((day, person.name, year - person.birthday.year)) }
            }
        }
        return out.sorted { ($0.day, $0.name) < ($1.day, $1.name) }
    }
}

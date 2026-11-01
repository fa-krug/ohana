import Foundation

extension DemoServer {
    /// The demo's week ahead (`/digest`): `demo-digest.json` with the birthdays of the two weeks
    /// worked out from the household (`demo-household.json`), like the overview's, and their
    /// ages in the "away on a birthday" issues.
    static func digest(_ request: Request) -> JSONValue? {
        guard request.familyPath == "/digest" else { return nil }
        return weekAheadDigest(request)
    }

    static func weekAheadDigest(_ request: Request) -> JSONValue? {
        guard case var .object(digest)? = request.json("digest") else { return nil }
        let days = birthdays(householdBirthdays(request), from: request.today, to: request.today.adding(days: 13))
        digest["birthdays"] = .array(days.map { day in
            .object(["day": .string(day.day.description), "name": .string(day.name), "age": .number(Double(day.age))])
        })
        let ages = Dictionary(days.map { ($0.name, $0.age) }) { first, _ in first }
        digest["issues"] = .array((digest["issues"]?.arrayValue ?? []).map { issue in
            guard issue["kind"]?.stringValue == "birthday_away", case var .object(fields) = issue,
                  case var .object(data)? = fields["data"], let name = data["name"]?.stringValue,
                  let age = ages[name] else { return issue }
            data["age"] = .number(Double(age))
            fields["data"] = .object(data)
            return .object(fields)
        })
        return .object(digest)
    }

    /// The overview's `weekAhead` (server/lib/families/dashboard.ts): the open conflicts and
    /// warnings of the digest, and its first three open issues.
    static func weekAheadSummary(_ request: Request) -> JSONValue? {
        guard let issues = weekAheadDigest(request)?["issues"]?.arrayValue else { return nil }
        let open = issues.filter { $0["dismissed"]?.boolValue != true }
        let count = { (severity: String) in
            JSONValue.number(Double(open.filter { $0["severity"]?.stringValue == severity }.count))
        }
        return .object(["conflicts": count("conflict"), "warnings": count("warning"), "top": .array(Array(open.prefix(3)))])
    }

    /// The household's members and people with a birthday.
    static func householdBirthdays(_ request: Request) -> [(name: String, birthday: Day)] {
        let household = request.json("household")
        let people = (household?["members"]?.arrayValue ?? []) + (household?["people"]?.arrayValue ?? [])
        return people.compactMap { person -> (name: String, birthday: Day)? in
            guard let name = person["name"]?.stringValue,
                  let birthday = person["birthday"]?.stringValue.flatMap(Day.init) else { return nil }
            return (name, birthday)
        }
    }
}

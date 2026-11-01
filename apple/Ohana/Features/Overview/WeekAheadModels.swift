import SwiftUI

/// GET /api/v1/families/{id}/digest?today= (server/lib/digest): the next two weeks for each
/// member, with what doesn't work out. Decoded leniently: what a newer server adds (a kind, a
/// severity, fields in `data`) still shows.
struct WeekAheadDigest: Codable, Hashable {
    let from: Day
    let to: Day
    /// The server looks up the events' places; without, travel is only judged by the place names.
    var geocoding: Bool
    var people: [WeekAheadPerson]
    /// By date, then severity; the dismissed ones too.
    var issues: [WeekAheadIssue]
    /// The runs of days the family is away (an "away" calendar type).
    var away: [WeekAheadAway]
    var birthdays: [OverviewBirthday]
}

extension WeekAheadDigest {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(Day.self, forKey: .from)
        to = try c.decode(Day.self, forKey: .to)
        geocoding = try c.decodeIfPresent(Bool.self, forKey: .geocoding) ?? false
        people = try c.decodeIfPresent([WeekAheadPerson].self, forKey: .people) ?? []
        issues = try c.decodeIfPresent([WeekAheadIssue].self, forKey: .issues) ?? []
        away = try c.decodeIfPresent([WeekAheadAway].self, forKey: .away) ?? []
        birthdays = try c.decodeIfPresent([OverviewBirthday].self, forKey: .birthdays) ?? []
    }
}

/// A member of the family (an account, or a person without one) in the two weeks.
struct WeekAheadPerson: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Has an account (a member who can sign in); false for the family's people.
    var account: Bool
    /// Under 14 on the first day (by birthday).
    var child: Bool
    /// Their events in the two weeks.
    var events: Int
}

extension WeekAheadPerson {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        account = try c.decodeIfPresent(Bool.self, forKey: .account) ?? false
        child = try c.decodeIfPresent(Bool.self, forKey: .child) ?? false
        events = try c.decodeIfPresent(Int.self, forKey: .events) ?? 0
    }
}

/// Days the family is away, and the names of their types ("Vacation").
struct WeekAheadAway: Codable, Hashable, Identifiable {
    let from: Day
    let to: Day
    var names: [String]

    var id: String { "\(from)|\(to)|\(names.joined(separator: ","))" }
}

/// How much an issue matters: a clash (red), something to look at (orange), good to know (gray).
enum WeekAheadSeverity: String, Codable, Hashable, Comparable {
    case conflict, warning, info

    /// An unknown severity (a newer server's) counts as `info`.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WeekAheadSeverity(rawValue: raw) ?? .info
    }

    private var rank: Int {
        switch self {
        case .conflict: 0
        case .warning: 1
        case .info: 2
        }
    }

    static func < (a: WeekAheadSeverity, b: WeekAheadSeverity) -> Bool { a.rank < b.rank }

    var systemImage: String {
        switch self {
        case .conflict: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .conflict: .red
        case .warning: .orange
        case .info: .secondary
        }
    }

    /// For VoiceOver.
    var label: LocalizedStringKey {
        switch self {
        case .conflict: "Conflict"
        case .warning: "Warning"
        case .info: "Good to know"
        }
    }
}

/// One thing that doesn't work out (server/lib/digest/checks.ts `Issue`).
struct WeekAheadIssue: Codable, Hashable, Identifiable {
    /// The kind and the occurrences it's about: what "Looks fine" hides.
    let key: String
    /// overlap, tight_transfer, during_trip, packed_day, long_travel_day, travel_week,
    /// short_night, away_clash, drivers_needed, birthday_away, unassigned_overlap; others
    /// (a newer server's) show generically.
    let kind: String
    var severity: WeekAheadSeverity
    let date: Day
    /// Who it's about; empty: nobody in particular (unassigned events).
    var people: [Person]
    var events: [Event]
    /// The kind's numbers (minutes, km, …), as the server sends them.
    var data: JSONValue
    var dismissed: Bool

    var id: String { key }

    struct Person: Codable, Hashable {
        /// The account's or person's id; nil for a name the family doesn't have.
        var id: String?
        let name: String
    }

    /// An occurrence the issue is about.
    struct Event: Codable, Hashable {
        let id: String
        var occurrence: Day?
        let title: String
        let date: Day
        var endDate: Day?
        /// "HH:MM", or nil for all day.
        var start: String?
        var end: String?
        var location: String

        init(id: String, occurrence: Day? = nil, title: String, date: Day, endDate: Day? = nil,
             start: String? = nil, end: String? = nil, location: String = "") {
            self.id = id
            self.occurrence = occurrence
            self.title = title
            self.date = date
            self.endDate = endDate
            self.start = start
            self.end = end
            self.location = location
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            occurrence = try c.decodeIfPresent(Day.self, forKey: .occurrence)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            date = try c.decode(Day.self, forKey: .date)
            endDate = try c.decodeIfPresent(Day.self, forKey: .endDate)
            start = try c.decodeIfPresent(String.self, forKey: .start)
            end = try c.decodeIfPresent(String.self, forKey: .end)
            location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        }

        /// "16:15–17:30", "from 09:00" on the first day of one over several days; nil all day.
        var time: String? {
            CalendarEventTime.text(date: date, endDate: endDate ?? date, start: start, end: end, on: date)
        }

        /// "16:15–17:30 Football training", or the title alone for an all-day event.
        var line: String {
            time.map { "\($0) \(title)" } ?? title
        }
    }

    init(key: String, kind: String, severity: WeekAheadSeverity, date: Day, people: [Person] = [],
         events: [Event] = [], data: JSONValue = .object([:]), dismissed: Bool = false) {
        self.key = key
        self.kind = kind
        self.severity = severity
        self.date = date
        self.people = people
        self.events = events
        self.data = data
        self.dismissed = dismissed
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decode(String.self, forKey: .kind)
        severity = try c.decodeIfPresent(WeekAheadSeverity.self, forKey: .severity) ?? .info
        date = try c.decode(Day.self, forKey: .date)
        people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data) ?? .object([:])
        dismissed = try c.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
    }

    /// What the issue says, in the app's language (`WeekAheadText`).
    var sentence: String { WeekAheadText.sentence(self) }

    /// "Mia, Leo": who it's about; empty when nobody in particular.
    var names: String { people.map(\.name).formatted(.list(type: .and)) }
}

/// The overview's `weekAhead` (server/lib/families/dashboard.ts): how many open conflicts and
/// warnings the two weeks have, and the first few issues.
struct WeekAheadSummary: Codable, Hashable {
    var conflicts: Int
    var warnings: Int
    var top: [WeekAheadIssue]

    /// Anything worth the overview's card.
    var hasIssues: Bool { conflicts + warnings > 0 }
}

extension WeekAheadSummary {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        warnings = try c.decodeIfPresent(Int.self, forKey: .warnings) ?? 0
        top = try c.decodeIfPresent([WeekAheadIssue].self, forKey: .top) ?? []
    }
}

// MARK: Grouping

/// The page's sections: per person their open issues, the family's (unassigned) ones, who has
/// none, and what was hidden with "Looks fine".
struct WeekAheadGroups: Equatable {
    struct Group: Equatable, Identifiable {
        /// The person's id; "" for the unassigned issues.
        let id: String
        /// The person; nil for the unassigned group.
        let person: WeekAheadPerson?
        /// For a name the family doesn't know (no person).
        let name: String?
        let issues: [WeekAheadIssue]
    }

    /// People with issues (in the family's order), then the unassigned group when it has any.
    var groups: [Group]
    /// People without open issues.
    var clear: [WeekAheadPerson]
    /// Dismissed issues, by date.
    var hidden: [WeekAheadIssue]

    var isClear: Bool { groups.isEmpty }

    init(_ digest: WeekAheadDigest) {
        let open = digest.issues.filter { !$0.dismissed }
        hidden = digest.issues.filter(\.dismissed)

        var byPerson: [String: [WeekAheadIssue]] = [:]
        var strangers: [String] = []
        var unassigned: [WeekAheadIssue] = []
        let ids = Set(digest.people.map(\.id))
        let byName = Dictionary(digest.people.map { ($0.name.lowercased(), $0.id) }) { a, _ in a }
        for issue in open {
            var keys: [String] = []
            for person in issue.people {
                // By id; a person without one by name, else a group of their own.
                let key: String
                if let id = person.id, ids.contains(id) {
                    key = id
                } else if let id = byName[person.name.lowercased()] {
                    key = id
                } else {
                    key = "name:" + person.name
                    if !strangers.contains(key) { strangers.append(key) }
                }
                if !keys.contains(key) { keys.append(key) }
            }
            if keys.isEmpty { unassigned.append(issue) }
            for key in keys { byPerson[key, default: []].append(issue) }
        }

        var groups: [Group] = digest.people.compactMap { person in
            byPerson[person.id].map { Group(id: person.id, person: person, name: nil, issues: $0) }
        }
        groups += strangers.compactMap { key in
            byPerson[key].map { Group(id: key, person: nil, name: String(key.dropFirst("name:".count)), issues: $0) }
        }
        if !unassigned.isEmpty { groups.append(Group(id: "", person: nil, name: nil, issues: unassigned)) }
        self.groups = groups
        clear = digest.people.filter { byPerson[$0.id] == nil }
    }
}

// MARK: Actions

/// "Looks fine" and restoring it (editors): POST /digest/dismiss {key}, DELETE
/// /digest/dismiss/{key}; both answer 204.
enum WeekAheadActions {
    struct DismissBody: Encodable { let key: String }

    static func dismiss(_ family: FamilyContext, key: String) async throws {
        let _: Empty = try await family.api.send(.post, "/digest/dismiss", body: DismissBody(key: key))
        family.didChange(.digest)
    }

    static func restore(_ family: FamilyContext, key: String) async throws {
        let api = family.api
        var request = api.client.request(.delete, api.path("/digest/dismiss"))
        request.url = restoreURL(request.url!, key: key)
        _ = try await api.client.data(for: request)
        family.didChange(.digest)
    }

    /// `base` + "/" + the key as one path segment: a key may hold characters a path can't
    /// (a slash, a question mark), so they're percent-encoded.
    static func restoreURL(_ base: URL, key: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += "/" + (key.addingPercentEncoding(withAllowedCharacters: segment) ?? key)
        return components.url!
    }

    private static let segment = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:@!$&'()*+,;=")
}

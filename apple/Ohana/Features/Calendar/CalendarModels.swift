import Foundation

// The calendar's JSON, as the server writes it (server/lib/calendar/vacation.ts, family-routes.ts,
// events.ts; the web client's components/calendar/api.ts types).

/// What a type does for the coverage check (server/lib/calendar/core.ts `Role`).
enum CalendarRole: String, Codable, CaseIterable, Hashable, Identifiable {
    case none
    case needsCover = "needs_cover"
    case covers
    case dayOff = "day_off"

    var id: String { rawValue }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CalendarRole(rawValue: raw) ?? .none
    }

    var title: String {
        switch self {
        case .none: String(localized: "Normal")
        case .needsCover: String(localized: "Needs cover")
        case .covers: String(localized: "Covers")
        case .dayOff: String(localized: "Day off")
        }
    }

    var help: String {
        switch self {
        case .needsCover:
            String(localized: "E.g. “Day care closed”. A weekday with this entry and nothing that covers it is flagged as a gap.")
        case .covers:
            String(localized: "E.g. “Vacation Dad”. Covers a “needs cover” day.")
        case .dayOff:
            String(localized: "E.g. “Holiday”. Covers everything and doesn’t count as a used vacation day.")
        case .none:
            String(localized: "Just a color, no coverage logic.")
        }
    }
}

/// An entry type of one year (vacation.ts `publicType`).
struct CalendarEntryType: Codable, Hashable, Identifiable {
    var id: String
    var year: Int?
    var name: String
    var color: String
    var role: CalendarRole
    var position: Int?
    /// The whole family is away from home on its days: the meal plan skips them.
    var away: Bool?

    var isAway: Bool { away ?? false }
}

/// Icon and/or comment on a day.
struct CalendarNote: Codable, Hashable {
    var icon: String
    var comment: String

    init(icon: String, comment: String) {
        self.icon = icon
        self.comment = comment
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
    }

    var text: String { [icon, comment].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// A member's birthday on a day: who, and the age they turn.
struct CalendarBirthday: Codable, Hashable {
    let name: String
    let age: Int
}

/// A timed event (events.ts `PublicEvent`): a booked appointment or one added by hand.
struct CalendarEvent: Codable, Hashable, Identifiable {
    let id: String
    let date: Day
    let start: String?
    let end: String?
    let title: String
    let location: String
    let person: String
    let note: String
    let url: String
    let source: String
    /// The appointment search it came from (source "appointment").
    let searchId: String?

    enum CodingKeys: String, CodingKey {
        case id, date, start, end, title, location, person, note, url, source, searchId
    }

    init(id: String, date: Day, start: String?, end: String?, title: String, location: String = "",
         person: String = "", note: String = "", url: String = "", source: String = "manual", searchId: String? = nil) {
        self.id = id
        self.date = date
        self.start = start
        self.end = end
        self.title = title
        self.location = location
        self.person = person
        self.note = note
        self.url = url
        self.source = source
        self.searchId = searchId
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Day.self, forKey: .date)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        person = try c.decodeIfPresent(String.self, forKey: .person) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        searchId = try c.decodeIfPresent(String.self, forKey: .searchId)
    }

    var isAppointment: Bool { source == "appointment" }

    /// "10:30–11:00", "10:30", or nil for an all-day event.
    var timeText: String? {
        guard let start else { return nil }
        if let end { return "\(start)–\(end)" }
        return start
    }

    /// "10:30 Dr. Berg (Mia)": the event in one line (the web grid's `eventText`).
    var line: String {
        let name = person.isEmpty ? title : "\(title) (\(person))"
        return [start, name].compactMap { $0 }.joined(separator: " ")
    }

    /// The event moved to another day, everything else as it is.
    func on(_ day: Day) -> CalendarEvent {
        CalendarEvent(id: id, date: day, start: start, end: end, title: title, location: location, person: person,
                      note: note, url: url, source: source, searchId: searchId)
    }
}

/// The family as GET /families/{id} describes it (family-routes.ts `publicFamily`).
struct CalendarFamilyInfo: Codable, Hashable {
    let id: String
    let feedId: String
    /// family-planner's old feed id; only editors see it.
    let legacyId: String?
    let name: String
    let access: String
    let readOnly: Bool
    let updatedAt: String?
}

/// GET /families/{id}?year=: the family and its calendar of the year (family-routes.ts
/// `familyState`).
struct CalendarState: Codable {
    let family: CalendarFamilyInfo
    let types: [CalendarEntryType]
    let typeYears: [Int]?
    let entries: [String: [String]]
    let notes: [String: CalendarNote]?
    let events: [String: [CalendarEvent]]?
    let birthdays: [String: [CalendarBirthday]]?
}

// MARK: Requests

/// An entry op of POST /entries (core.ts `EntryOp`).
struct CalendarEntryOp: Codable, Hashable {
    enum Action: String, Codable { case add, remove }
    let action: Action
    let type: String
    let dates: [Day]
}

/// A note op of POST /notes (core.ts `NoteOp`).
struct CalendarNoteOp: Codable, Hashable {
    enum Action: String, Codable { case set, clear }
    let action: Action
    let dates: [Day]
    var icon: String?
    var comment: String?
}

struct CalendarOpsBody<Op: Encodable>: Encodable {
    let ops: [Op]
}

/// POST /types and PATCH /types/{id}: only the fields that are set are sent.
struct CalendarTypePatch: Encodable {
    var name: String?
    var color: String?
    var role: CalendarRole?
    var away: Bool?
    var position: Int?
}

struct CalendarCopyTypesBody: Encodable {
    let from: Int
    let to: Int
}

struct CalendarLinkBody: Encodable {
    /// "feed": a new feed address; "legacy": removes the old link.
    let link: String
}

/// POST /events and PATCH /events/{id}. `start` and `end` are always written (null: all day /
/// none), so an edit can clear them.
struct CalendarEventInput: Encodable, Equatable {
    var date: Day
    var start: String?
    var end: String?
    var title: String
    var location: String = ""
    var person: String = ""
    var note: String = ""
    var url: String = ""

    enum CodingKeys: String, CodingKey { case date, start, end, title, location, person, note, url }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(start, forKey: .start)
        try c.encode(start == nil ? nil : end, forKey: .end)
        try c.encode(title, forKey: .title)
        try c.encode(location, forKey: .location)
        try c.encode(person, forKey: .person)
        try c.encode(note, forKey: .note)
        try c.encode(url, forKey: .url)
    }
}

/// PATCH /events/{id} that only moves the event to another day (an event dragged onto it).
struct CalendarEventDateBody: Encodable, Equatable {
    let date: Day
}

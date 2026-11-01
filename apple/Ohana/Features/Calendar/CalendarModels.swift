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

/// An event on the calendar (events.ts `PublicEvent`): a booked appointment, one added by hand or
/// imported from Apple Calendar; one occurrence of it when it repeats. It may span several days
/// (`date` to `endDate`); the lists by day show it on each of them. An occurrence is addressed as
/// (`id`, `occurrence`): `id` is always the series', `occurrence` its original day.
struct CalendarEvent: Codable, Hashable {
    let id: String
    /// The occurrence's original day, for an event that repeats (also when it was moved).
    let occurrence: Day?
    let date: Day
    /// The last day (the same as `date` for a one-day event).
    let endDate: Day
    /// "HH:MM" on `date`; nil: all day.
    let start: String?
    /// "HH:MM" on `endDate`; nil: none given (or all day).
    let end: String?
    let title: String
    let location: String
    let person: String
    let note: String
    let url: String
    let source: String
    /// The appointment search it came from (source "appointment").
    let searchId: String?
    /// The Apple Calendar event it was imported from (source "apple", `AppleCalendarSync`).
    let externalId: String?
    /// How the series repeats (an RRULE value, `RepeatRule`); nil: it doesn't.
    let rrule: String?

    enum CodingKeys: String, CodingKey {
        case id, occurrence, date, endDate, start, end, title, location, person, note, url, source, searchId, externalId, rrule
    }

    init(id: String, occurrence: Day? = nil, date: Day, endDate: Day? = nil, start: String?, end: String?, title: String,
         location: String = "", person: String = "", note: String = "", url: String = "", source: String = "manual",
         searchId: String? = nil, externalId: String? = nil, rrule: String? = nil) {
        self.id = id
        self.occurrence = occurrence
        self.date = date
        self.endDate = max(endDate ?? date, date)
        self.start = start
        self.end = end
        self.title = title
        self.location = location
        self.person = person
        self.note = note
        self.url = url
        self.source = source
        self.searchId = searchId
        self.externalId = externalId
        self.rrule = rrule
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        occurrence = try c.decodeIfPresent(Day.self, forKey: .occurrence)
        date = try c.decode(Day.self, forKey: .date)
        endDate = max(try c.decodeIfPresent(Day.self, forKey: .endDate) ?? date, date)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        person = try c.decodeIfPresent(String.self, forKey: .person) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        searchId = try c.decodeIfPresent(String.self, forKey: .searchId)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        rrule = try c.decodeIfPresent(String.self, forKey: .rrule)
    }

    /// Unique in a list: an occurrence's id with its day.
    var uid: String { occurrence.map { "\(id)@\($0)" } ?? id }

    var isAppointment: Bool { source == "appointment" }
    var repeats: Bool { rrule != nil }
    var isMultiDay: Bool { endDate > date }

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

    /// The event moved to start on another day (its length kept), everything else as it is.
    func on(_ day: Day) -> CalendarEvent {
        let days = CalendarMath.ordinal(endDate) - CalendarMath.ordinal(date)
        return CalendarEvent(id: id, occurrence: occurrence, date: day, endDate: CalendarMath.add(day, days), start: start,
                             end: end, title: title, location: location, person: person, note: note, url: url,
                             source: source, searchId: searchId, externalId: externalId, rrule: rrule)
    }
}

/// One occurrence of a series changed on its own (events.ts overrides): what it is now.
struct CalendarEventOverride: Codable, Hashable {
    /// The original day it replaces.
    var occurrence: Day
    var date: Day
    var endDate: Day
    var start: String?
    var end: String?
    var title: String
    var location: String = ""
    var person: String = ""
    var note: String = ""
    var url: String = ""

    enum CodingKeys: String, CodingKey { case occurrence, date, endDate, start, end, title, location, person, note, url }

    init(occurrence: Day, date: Day, endDate: Day, start: String?, end: String?, title: String, location: String = "",
         person: String = "", note: String = "", url: String = "") {
        self.occurrence = occurrence
        self.date = date
        self.endDate = max(endDate, date)
        self.start = start
        self.end = end
        self.title = title
        self.location = location
        self.person = person
        self.note = note
        self.url = url
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        occurrence = try c.decode(Day.self, forKey: .occurrence)
        date = try c.decode(Day.self, forKey: .date)
        endDate = max(try c.decodeIfPresent(Day.self, forKey: .endDate) ?? date, date)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        person = try c.decodeIfPresent(String.self, forKey: .person) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(occurrence, forKey: .occurrence)
        try c.encode(date, forKey: .date)
        try c.encode(endDate, forKey: .endDate)
        try c.encode(start, forKey: .start)
        try c.encode(start == nil ? nil : end, forKey: .end)
        try c.encode(title, forKey: .title)
        try c.encode(location, forKey: .location)
        try c.encode(person, forKey: .person)
        try c.encode(note, forKey: .note)
        try c.encode(url, forKey: .url)
    }
}

/// An event as stored (events.ts `EventSeries`, GET /events?raw=1 and /events/{id}): a single
/// event, or a series with its rule, the days taken out of it and the occurrences changed on their
/// own. What editors of "all events" and the Apple Calendar sync work with.
struct CalendarEventSeries: Codable, Hashable {
    let id: String
    var date: Day
    var endDate: Day
    var start: String?
    var end: String?
    var title: String
    var location: String
    var person: String
    var note: String
    var url: String
    var source: String
    var searchId: String?
    var externalId: String?
    var rrule: String?
    var exdates: [Day]
    var overrides: [CalendarEventOverride]

    enum CodingKeys: String, CodingKey {
        case id, date, endDate, start, end, title, location, person, note, url, source, searchId, externalId, rrule,
             exdates, overrides
    }

    init(id: String, date: Day, endDate: Day? = nil, start: String?, end: String?, title: String, location: String = "",
         person: String = "", note: String = "", url: String = "", source: String = "manual", searchId: String? = nil,
         externalId: String? = nil, rrule: String? = nil, exdates: [Day] = [], overrides: [CalendarEventOverride] = []) {
        self.id = id
        self.date = date
        self.endDate = max(endDate ?? date, date)
        self.start = start
        self.end = end
        self.title = title
        self.location = location
        self.person = person
        self.note = note
        self.url = url
        self.source = source
        self.searchId = searchId
        self.externalId = externalId
        self.rrule = rrule
        self.exdates = exdates
        self.overrides = overrides
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Day.self, forKey: .date)
        endDate = max(try c.decodeIfPresent(Day.self, forKey: .endDate) ?? date, date)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        title = try c.decode(String.self, forKey: .title)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        person = try c.decodeIfPresent(String.self, forKey: .person) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        searchId = try c.decodeIfPresent(String.self, forKey: .searchId)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        rrule = try c.decodeIfPresent(String.self, forKey: .rrule)
        exdates = try c.decodeIfPresent([Day].self, forKey: .exdates) ?? []
        overrides = try c.decodeIfPresent([CalendarEventOverride].self, forKey: .overrides) ?? []
    }

    var repeats: Bool { rrule != nil }
}

/// GET /events (`from`/`to` or `year`: the occurrences in the range).
struct CalendarEventsResponse: Decodable {
    let events: [CalendarEvent]
}

/// GET /events?raw=1: every event of the family as stored.
struct CalendarEventSeriesResponse: Decodable {
    let events: [CalendarEventSeries]
}

/// Which occurrences a change to a repeating event touches (`?span=`): only this one, or this and
/// the ones after it. Without an occurrence a change is to the whole series.
enum CalendarEventSpan: String, Codable {
    case this, future
}

/// The family as GET /families/{id} describes it (family-routes.ts `publicFamily`).
struct CalendarFamilyInfo: Codable, Hashable {
    let id: String
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

/// POST /events and PATCH /events/{id}. `start`, `end` and `rrule` are always written (null: all
/// day / none / doesn't repeat), so an edit can clear them; the server ignores `rrule` for a change
/// to one occurrence.
struct CalendarEventInput: Encodable, Equatable {
    var date: Day
    var endDate: Day?
    var start: String?
    var end: String?
    var title: String
    var location: String = ""
    var person: String = ""
    var note: String = ""
    var url: String = ""
    var rrule: String?

    init(date: Day, endDate: Day? = nil, start: String?, end: String?, title: String, location: String = "",
         person: String = "", note: String = "", url: String = "", rrule: String? = nil) {
        self.date = date
        self.endDate = endDate
        self.start = start
        self.end = end
        self.title = title
        self.location = location
        self.person = person
        self.note = note
        self.url = url
        self.rrule = rrule
    }

    enum CodingKeys: String, CodingKey { case date, endDate, start, end, title, location, person, note, url, rrule }

    /// The last day as sent: never before the first.
    var lastDay: Day { max(endDate ?? date, date) }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(lastDay, forKey: .endDate)
        try c.encode(start, forKey: .start)
        try c.encode(start == nil ? nil : end, forKey: .end)
        try c.encode(title, forKey: .title)
        try c.encode(location, forKey: .location)
        try c.encode(person, forKey: .person)
        try c.encode(note, forKey: .note)
        try c.encode(url, forKey: .url)
        try c.encode(rrule, forKey: .rrule)
    }
}

/// PATCH /events/{id} that only moves the event to other days (an event dragged onto one).
struct CalendarEventDateBody: Encodable, Equatable {
    let date: Day
    let endDate: Day
}

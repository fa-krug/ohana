import Foundation

// The requests that change events (server/lib/calendar/events.ts): a new one, a change to the whole
// event or series, to one occurrence (`span=this`) or to it and the ones after it (`span=future`),
// the same for deleting, and putting a series back as it was (undo).

/// Which occurrences a change touches: the whole event (a single one, or every occurrence of a
/// series), one occurrence, or one and the ones after it.
enum CalendarEventScope: Equatable {
    case all
    case this(Day)
    case future(Day)

    /// The scope of a change to `event` with the user's choice `span` (nil: the event doesn't
    /// repeat, or no choice was asked). On a series' first occurrence (`seriesStart`) "this and
    /// the ones after it" are all of them.
    init(_ event: CalendarEvent?, span: CalendarEventSpan?, seriesStart: Day?) {
        guard let occurrence = event?.occurrence, let span else {
            self = .all
            return
        }
        switch span {
        case .this: self = .this(occurrence)
        case .future: self = occurrence == seriesStart ? .all : .future(occurrence)
        }
    }

    var query: [String: String?] {
        switch self {
        case .all: [:]
        case let .this(day): ["occurrence": day.description, "span": CalendarEventSpan.this.rawValue]
        case let .future(day): ["occurrence": day.description, "span": CalendarEventSpan.future.rawValue]
        }
    }
}

/// A request on the family API: method, path below the family, query and JSON body.
struct CalendarEventRequest: Equatable {
    let method: HTTPMethod
    let path: String
    var query: [String: String?] = [:]
    var body: Data?

    /// POST /events.
    static func create(_ input: CalendarEventInput) -> CalendarEventRequest {
        CalendarEventRequest(method: .post, path: "/events", body: encode(input))
    }

    /// PATCH /events/{id}[?occurrence=&span=]. A change to the whole event sends the rule too (null:
    /// it stops repeating); one to an occurrence doesn't (the server ignores it); one to the
    /// occurrences from one on sends it only when it changed (`keepRule`), so the new series keeps
    /// the old rule and what is left of a count.
    static func save(_ input: CalendarEventInput, id: String, scope: CalendarEventScope,
                     keepRule: Bool = false) -> CalendarEventRequest {
        let withRule: Bool
        switch scope {
        case .all: withRule = true
        case .this: withRule = false
        case .future: withRule = !keepRule
        }
        return CalendarEventRequest(method: .patch, path: "/events/\(id)", query: scope.query,
                                    body: encode(CalendarEventFieldsBody(input: input, withRule: withRule)))
    }

    /// What a change to `event` sends: with the series (or the ones from an occurrence on) moved
    /// to other weekdays and its rule unchanged, the rule's weekdays move along; it is then sent
    /// (`keepRule` false). Returns the input and whether the rule may be left out.
    static func moved(_ input: CalendarEventInput, from event: CalendarEvent,
                      scope: CalendarEventScope) -> (input: CalendarEventInput, keepRule: Bool) {
        let keepRule = RepeatRule.canonical(input.rrule) == RepeatRule.canonical(event.rrule)
        let days = CalendarMath.ordinal(input.date) - CalendarMath.ordinal(event.date)
        if case .this = scope { return (input, keepRule) }
        guard keepRule, days % 7 != 0,
              let rule = input.rrule.flatMap(RepeatRule.init), !rule.weekdays.isEmpty else { return (input, keepRule) }
        var input = input
        input.rrule = rule.shiftingWeekdays(by: days).string
        return (input, false)
    }

    /// DELETE /events/{id}[?occurrence=&span=].
    static func delete(id: String, scope: CalendarEventScope) -> CalendarEventRequest {
        CalendarEventRequest(method: .delete, path: "/events/\(id)", query: scope.query)
    }

    /// Moves an event to other days (dragged): one occurrence of a series on its own, a single
    /// event as a whole.
    static func move(id: String, occurrence: Day?, date: Day, endDate: Day) -> CalendarEventRequest {
        CalendarEventRequest(method: .patch, path: "/events/\(id)",
                             query: occurrence.map { CalendarEventScope.this($0).query } ?? [:],
                             body: encode(CalendarEventDateBody(date: date, endDate: endDate)))
    }

    /// Puts a series back as it was: PATCH with its whole state (rule, exdates and overrides
    /// replaced), or POST when it is gone (it gets a new id).
    static func restore(_ series: CalendarEventSeries, id: String?) -> CalendarEventRequest {
        if let id {
            return CalendarEventRequest(method: .patch, path: "/events/\(id)", body: encode(CalendarEventSeriesBody(series)))
        }
        return CalendarEventRequest(method: .post, path: "/events", body: encode(CalendarEventSeriesBody(series, create: true)))
    }

    private static func encode(_ value: some Encodable) -> Data? {
        try? APIClient.encoder.encode(value)
    }
}

/// The editor's fields of PATCH /events/{id}, with or without the rule.
struct CalendarEventFieldsBody: Encodable {
    let input: CalendarEventInput
    let withRule: Bool

    private enum CodingKeys: String, CodingKey { case date, endDate, start, end, title, location, person, note, url, rrule }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input.date, forKey: .date)
        try c.encode(input.lastDay, forKey: .endDate)
        try c.encode(input.start, forKey: .start)
        try c.encode(input.start == nil ? nil : input.end, forKey: .end)
        try c.encode(input.title, forKey: .title)
        try c.encode(input.location, forKey: .location)
        try c.encode(input.person, forKey: .person)
        try c.encode(input.note, forKey: .note)
        try c.encode(input.url, forKey: .url)
        if withRule { try c.encode(input.rrule, forKey: .rrule) }
    }
}

/// A series' whole state for PATCH /events/{id} or POST /events: everything, the days taken out
/// and the occurrences changed on their own included. Posted, an Apple Calendar event keeps its
/// link (`externalId`).
struct CalendarEventSeriesBody: Encodable {
    let series: CalendarEventSeries
    var create = false

    init(_ series: CalendarEventSeries, create: Bool = false) {
        self.series = series
        self.create = create
    }

    private enum CodingKeys: String, CodingKey {
        case date, endDate, start, end, title, location, person, note, url, rrule, exdates, overrides, externalId
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(series.date, forKey: .date)
        try c.encode(series.endDate, forKey: .endDate)
        try c.encode(series.start, forKey: .start)
        try c.encode(series.start == nil ? nil : series.end, forKey: .end)
        try c.encode(series.title, forKey: .title)
        try c.encode(series.location, forKey: .location)
        try c.encode(series.person, forKey: .person)
        try c.encode(series.note, forKey: .note)
        try c.encode(series.url, forKey: .url)
        try c.encode(series.rrule, forKey: .rrule)
        try c.encode(series.exdates, forKey: .exdates)
        try c.encode(series.overrides, forKey: .overrides)
        if create, let externalId = series.externalId { try c.encode(externalId, forKey: .externalId) }
    }
}

/// The answer to DELETE /events/{id}: `{deleted: id}` when the event is gone, else the series as
/// it is now (an occurrence or the ones from it on taken out).
struct CalendarEventDeleteAnswer: Decodable {
    let deleted: String?
    let series: CalendarEventSeries?

    private enum CodingKeys: String, CodingKey { case deleted }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let deleted = try c.decodeIfPresent(String.self, forKey: .deleted) {
            self.deleted = deleted
            series = nil
        } else {
            deleted = nil
            series = try CalendarEventSeries(from: decoder)
        }
    }
}

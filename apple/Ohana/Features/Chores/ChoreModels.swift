import Foundation

// The chores of a family (server/lib/chores/routes.ts): GET /chores?today=, the chore the other
// routes answer with and the agenda (GET /chores/agenda?from=&to=&today=).

/// Someone a chore can be for: a member with an account, or one of the family's people without
/// one (`familyNames` on the server).
struct ChorePerson: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// A member with an account (can tick their chores off themselves, can be notified).
    let account: Bool
}

/// The part of the day a chore is for. With a time the time decides (`of(time:)`).
enum ChorePart: String, Codable, CaseIterable, Hashable {
    case morning, day, evening

    /// The part of a time "HH:MM": before 12:00 the morning, before 17:00 the day, else the evening.
    static func of(time: String) -> ChorePart? {
        let parts = time.split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }) else { return nil }
        if hour < 12 { return .morning }
        return hour < 17 ? .day : .evening
    }

    /// Something else (a newer server's): the day.
    init(from decoder: any Decoder) throws {
        self = ChorePart(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .day
    }

    var title: String {
        switch self {
        case .morning: String(localized: "Morning")
        // Its own key: "Day" is a calendar's day elsewhere.
        case .day: String(localized: "chores.part.day", defaultValue: "Day", comment: "The part of the day between morning and evening")
        case .evening: String(localized: "Evening")
        }
    }

    var systemImage: String {
        switch self {
        case .morning: "sunrise"
        case .day: "sun.max"
        case .evening: "moon.stars"
        }
    }
}

/// One chore: once (due on `day`) or repeating (`rrule` from `day` on), maybe for someone.
struct Chore: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let note: String
    let assignee: ChorePerson?
    /// The due day, or a repeating chore's first.
    let day: Day
    /// "HH:MM"; nil: any time of its part of the day.
    let time: String?
    var part: ChorePart = .day
    /// The RRULE value; nil: once.
    let rrule: String?
    /// Done (a chore that's once; a repeating one's occurrences are ticked off in the agenda).
    let done: Bool
    let doneAt: String?
    var doneBy: ChorePerson?
    /// When it's due next: an open single chore's day (also when past: overdue), nil when it's
    /// done; a repeating one's first occurrence from today on, nil once the series ended.
    let next: Day?
    /// The accounts notified when it's due.
    var subscriberIds: [String] = []
    /// The signed-in account is among them.
    var subscribed = false
    let createdAt: String
    let updatedAt: String

    var isRepeating: Bool { rrule != nil }
    var rule: RepeatRule? { rrule.flatMap(RepeatRule.init) }
    var doneDate: Date? { doneAt.flatMap(Date.server) }

    /// The chore with the account (un)subscribed, before the server answers.
    func subscribing(_ on: Bool, me: String?) -> Chore {
        var chore = self
        chore.subscribed = on
        if let me {
            chore.subscriberIds.removeAll { $0 == me }
            if on { chore.subscriberIds.append(me) }
        }
        return chore
    }
}

extension Chore {
    private enum CodingKeys: String, CodingKey {
        case id, title, note, assignee, day, time, part, rrule, done, doneAt, doneBy, next, subscriberIds, subscribed,
             createdAt, updatedAt
    }

    /// What an older server doesn't send: the part (from the time, else the day), who did it, the
    /// subscribers.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let time = try c.decodeIfPresent(String.self, forKey: .time)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  assignee: try c.decodeIfPresent(ChorePerson.self, forKey: .assignee),
                  day: try c.decode(Day.self, forKey: .day), time: time,
                  part: try c.decodeIfPresent(ChorePart.self, forKey: .part) ?? time.flatMap(ChorePart.of) ?? .day,
                  rrule: try c.decodeIfPresent(String.self, forKey: .rrule), done: try c.decode(Bool.self, forKey: .done),
                  doneAt: try c.decodeIfPresent(String.self, forKey: .doneAt),
                  doneBy: try c.decodeIfPresent(ChorePerson.self, forKey: .doneBy),
                  next: try c.decodeIfPresent(Day.self, forKey: .next),
                  subscriberIds: try c.decodeIfPresent([String].self, forKey: .subscriberIds) ?? [],
                  subscribed: try c.decodeIfPresent(Bool.self, forKey: .subscribed) ?? false,
                  createdAt: try c.decode(String.self, forKey: .createdAt),
                  updatedAt: try c.decode(String.self, forKey: .updatedAt))
    }
}

/// One chore on one day: a single chore on its day, or an occurrence of a repeating one.
struct ChoreItem: Codable, Hashable, Identifiable {
    let choreId: String
    /// The occurrence (a single chore's day).
    let day: Day
    let title: String
    var note: String = ""
    let assignee: ChorePerson?
    var part: ChorePart = .day
    let time: String?
    let repeating: Bool
    var done: Bool
    var doneAt: String?
    var doneBy: ChorePerson?
    var subscribed = false

    var id: String { "\(choreId)@\(day)" }

    private enum CodingKeys: String, CodingKey {
        case choreId, day, title, note, assignee, part, time, repeating, done, doneAt, doneBy, subscribed
    }

    init(choreId: String, day: Day, title: String, note: String = "", assignee: ChorePerson? = nil,
         part: ChorePart = .day, time: String? = nil, repeating: Bool = false, done: Bool = false,
         doneAt: String? = nil, doneBy: ChorePerson? = nil, subscribed: Bool = false) {
        self.choreId = choreId
        self.day = day
        self.title = title
        self.note = note
        self.assignee = assignee
        self.part = part
        self.time = time
        self.repeating = repeating
        self.done = done
        self.doneAt = doneAt
        self.doneBy = doneBy
        self.subscribed = subscribed
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let time = try c.decodeIfPresent(String.self, forKey: .time)
        self.init(choreId: try c.decode(String.self, forKey: .choreId), day: try c.decode(Day.self, forKey: .day),
                  title: try c.decode(String.self, forKey: .title),
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  assignee: try c.decodeIfPresent(ChorePerson.self, forKey: .assignee),
                  part: try c.decodeIfPresent(ChorePart.self, forKey: .part) ?? time.flatMap(ChorePart.of) ?? .day,
                  time: time, repeating: try c.decodeIfPresent(Bool.self, forKey: .repeating) ?? false,
                  done: try c.decodeIfPresent(Bool.self, forKey: .done) ?? false,
                  doneAt: try c.decodeIfPresent(String.self, forKey: .doneAt),
                  doneBy: try c.decodeIfPresent(ChorePerson.self, forKey: .doneBy),
                  subscribed: try c.decodeIfPresent(Bool.self, forKey: .subscribed) ?? false)
    }
}

/// GET /chores/agenda?from=&to=&today=: every day of the range with its chores, and the open
/// single chores whose day passed.
struct ChoreAgenda: Codable, Equatable {
    struct DayItems: Codable, Equatable {
        let date: Day
        var items: [ChoreItem]
    }

    var days: [DayItems]
    var overdue: [ChoreItem] = []

    /// The chores of `day`; nil when the range doesn't hold it.
    func items(on day: Day) -> [ChoreItem]? {
        days.first { $0.date == day }?.items
    }

    /// The range holds `day`.
    func covers(_ day: Day) -> Bool {
        guard let first = days.first?.date, let last = days.last?.date else { return false }
        return first <= day && day <= last
    }

    /// Every item of a chore (a tick or a subscription changed it) changed by `change`.
    mutating func update(choreID: String, day: Day? = nil, _ change: (inout ChoreItem) -> Void) {
        func apply(_ items: inout [ChoreItem]) {
            for i in items.indices where items[i].choreId == choreID && (day == nil || items[i].day == day) {
                change(&items[i])
            }
        }
        for i in days.indices { apply(&days[i].items) }
        apply(&overdue)
    }

    /// The days the agenda loads around `day`: blocks of two weeks from three days before today,
    /// so stepping through a block asks nothing new.
    static func window(around day: Day, today: Day) -> (from: Day, to: Day) {
        let length = 14
        let start = today.adding(days: -3)
        let offset = CalendarMath.ordinal(day) - CalendarMath.ordinal(start)
        let block = offset >= 0 ? offset / length : -((-offset + length - 1) / length)
        let from = start.adding(days: block * length)
        return (from, from.adding(days: length - 1))
    }
}

/// GET /chores?today=
struct ChoresPage: Codable, Equatable {
    var chores: [Chore]
    /// Whom chores can be for.
    var people: [ChorePerson]
    /// The account is an editor of the family.
    var canEdit: Bool
}

/// The answer of POST, PATCH, GET /chores/{id}, POST /chores/{id}/done and …/subscribe.
struct ChoreResponse: Codable {
    let chore: Chore
}

/// What POST /chores takes (and PATCH /chores/{id}, which gets it whole). `assigneeId`, `time`
/// and `rrule` are sent as null when empty, so an edit clears them.
struct ChoreInput: Encodable, Equatable {
    var title: String
    var note: String = ""
    /// A member's account id or a person's id; nil: nobody.
    var assigneeId: String?
    var day: Day
    var time: String?
    /// With a time, the time's (`effectivePart`).
    var part: ChorePart = .day
    var rrule: String?
    /// The accounts notified when it's due.
    var subscriberIds: [String] = []

    init(title: String, note: String = "", assigneeId: String? = nil, day: Day, time: String? = nil,
         part: ChorePart = .day, rrule: String? = nil, subscriberIds: [String] = []) {
        self.title = title
        self.note = note
        self.assigneeId = assigneeId
        self.day = day
        self.time = time
        self.part = part
        self.rrule = rrule
        self.subscriberIds = subscriberIds
    }

    init(_ chore: Chore) {
        self.init(title: chore.title, note: chore.note, assigneeId: chore.assignee?.id, day: chore.day,
                  time: chore.time, part: chore.part, rrule: chore.rrule, subscriberIds: chore.subscriberIds)
    }

    /// The part sent: the time's when there is one.
    var effectivePart: ChorePart { time.flatMap(ChorePart.of) ?? part }

    private enum CodingKeys: String, CodingKey {
        case title, note, assigneeId, day, time, part, rrule, subscriberIds
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(note, forKey: .note)
        try c.encode(assigneeId, forKey: .assigneeId)
        try c.encode(day, forKey: .day)
        try c.encode(time, forKey: .time)
        try c.encode(effectivePart, forKey: .part)
        try c.encode(rrule, forKey: .rrule)
        try c.encode(subscriberIds, forKey: .subscriberIds)
    }
}

/// POST /chores/{id}/done: a single chore, or a repeating one's occurrence `day`.
struct ChoreDoneBody: Encodable, Equatable {
    var done: Bool
    var day: Day?

    private enum CodingKeys: String, CodingKey { case done, day }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(day, forKey: .day)
    }

    /// Ticks `item` off (or opens it again): a repeating chore's names its occurrence.
    init(toggling item: ChoreItem) {
        self.init(done: !item.done, day: item.repeating ? item.day : nil)
    }

    init(done: Bool, day: Day? = nil) {
        self.done = done
        self.day = day
    }
}

/// POST /chores/{id}/subscribe: the signed-in account notified or not.
struct ChoreSubscribeBody: Encodable, Equatable {
    var subscribed: Bool
}

/// Whose chores the list shows.
enum ChoreFilter: Hashable {
    case everyone
    /// Those for this person (`ChorePerson.id`).
    case person(String)
    /// Those for nobody in particular.
    case nobody

    func matches(_ assignee: ChorePerson?) -> Bool {
        switch self {
        case .everyone: true
        case let .person(id): assignee?.id == id
        case .nobody: assignee == nil
        }
    }
}

/// Chores by part of the day, each part by time (none first), then title.
enum ChoreParts {
    static func make<Item>(_ items: [Item], part: (Item) -> ChorePart, time: (Item) -> String?,
                           title: (Item) -> String) -> [(part: ChorePart, items: [Item])] {
        ChorePart.allCases.compactMap { p in
            let list = items.filter { part($0) == p }.sorted { a, b in
                let (ta, tb) = (time(a) ?? "", time(b) ?? "")
                if ta != tb { return ta < tb }
                return title(a).localizedStandardCompare(title(b)) == .orderedAscending
            }
            return list.isEmpty ? nil : (p, list)
        }
    }

    /// A day's chores for `filter`.
    static func items(_ items: [ChoreItem], filter: ChoreFilter = .everyone) -> [(part: ChorePart, items: [ChoreItem])] {
        make(items.filter { filter.matches($0.assignee) }, part: \.part, time: \.time, title: \.title)
    }

    /// All chores for `filter`.
    static func chores(_ chores: [Chore], filter: ChoreFilter = .everyone) -> [(part: ChorePart, items: [Chore])] {
        make(chores.filter { filter.matches($0.assignee) }, part: \.part, time: \.time, title: \.title)
    }
}

/// How a chore reads in the lists.
enum ChoreText {
    /// "Today", "Tomorrow", "Mon 3 Nov", with the time: "Today, 18:00". A repeating chore: its
    /// rule ("Every Week, next Mon 3 Nov").
    static func schedule(_ chore: Chore, today: Day, locale: Locale = .current) -> String {
        if let rule = chore.rule {
            guard let next = chore.next else {
                return String(localized: "\(rule.summary(locale: locale)), ended")
            }
            return String(localized: "\(rule.summary(locale: locale)), next \(when(next, time: chore.time, today: today, locale: locale))")
        }
        return when(chore.day, time: chore.time, today: today, locale: locale)
    }

    /// A day (relative near today) and the time.
    static func when(_ day: Day, time: String?, today: Day, locale: Locale = .current) -> String {
        let name = dayName(day, today: today, locale: locale)
        guard let time else { return name }
        return "\(name), \(time)"
    }

    /// "Today", "Tomorrow", "Yesterday", else "Mon 3 Nov" (with the year when it's another).
    static func dayName(_ day: Day, today: Day, locale: Locale = .current) -> String {
        switch day {
        case today: String(localized: "Today")
        case today.adding(days: 1): String(localized: "Tomorrow")
        case today.adding(days: -1): String(localized: "Yesterday")
        default:
            day.year == today.year
                ? day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
                : day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().locale(locale))
        }
    }
}

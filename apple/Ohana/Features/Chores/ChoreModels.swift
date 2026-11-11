import Foundation

// The chores of a family (server/lib/chores/routes.ts): GET /chores?today=, the chore the other
// routes answer with and the agenda (GET /chores/agenda?from=&to=&today=).

/// Someone a chore can be for: a member with an account, or one of the family's people without
/// one (`familyNames` on the server).
nonisolated struct ChorePerson: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    /// A member with an account (can tick their chores off themselves, can be notified).
    let account: Bool
}

/// The part of the day a chore is for. With a time the time decides (`of(time:in:)`).
nonisolated enum ChorePart: String, Codable, CaseIterable, Hashable, Sendable {
    case morning, day, evening

    /// The part of a time "HH:MM" by the family's day parts: before the day starts the morning,
    /// before the evening starts the day, else the evening.
    static func of(time: String, in parts: ChoreDayParts = .standard) -> ChorePart? {
        guard let time = ChoreDayParts.normalized(time) else { return nil }
        return parts.part(of: time)
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

/// When the family's parts of the day start ("HH:MM", in order): GET /chores' `dayParts`, changed
/// with PATCH /chores/day-parts (editors). A chore without a time is due when its part starts.
nonisolated struct ChoreDayParts: Codable, Hashable, Sendable {
    var morning: String
    var day: String
    var evening: String

    /// The server's defaults (and an older server's, which doesn't send them).
    static let standard = ChoreDayParts(morning: "07:00", day: "12:00", evening: "18:00")

    /// The part a normalized "HH:MM" falls in (before the morning's start: still the morning).
    func part(of time: String) -> ChorePart {
        time < day ? .morning : time < evening ? .day : .evening
    }

    /// When `part` starts.
    subscript(part: ChorePart) -> String {
        get {
            switch part {
            case .morning: morning
            case .day: day
            case .evening: evening
            }
        }
        set {
            switch part {
            case .morning: morning = newValue
            case .day: day = newValue
            case .evening: evening = newValue
            }
        }
    }

    /// The morning starts before the day, the day before the evening (else the server refuses).
    var isOrdered: Bool { morning < day && day < evening }

    /// "H:MM" or "HH:MM" as "HH:MM"; nil for anything else.
    static func normalized(_ time: String) -> String? {
        let parts = time.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1],
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }
}

/// GET /chores/day-parts, PATCH /chores/day-parts.
nonisolated struct ChoreDayPartsResponse: Codable, OffMainDecodable {
    let dayParts: ChoreDayParts
}

/// One chore: once (due on `day`) or repeating (`rrule` from `day` on), maybe for someone.
nonisolated struct Chore: Codable, Hashable, Identifiable, Sendable {
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
    var done: Bool
    var doneAt: String?
    var doneBy: ChorePerson?
    /// When it's due next: an open single chore's day (also when past: overdue), nil when it's
    /// done; a repeating one's first occurrence from today on, nil once the series ended.
    var next: Day?
    /// The accounts notified when it's due.
    var subscriberIds: [String] = []
    /// The signed-in account is among them.
    var subscribed = false
    let createdAt: String
    let updatedAt: String

    var isRepeating: Bool { rrule != nil }

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

@MainActor
extension Chore {
    var rule: RepeatRule? { rrule.flatMap(RepeatRule.init) }
    var doneDate: Date? { doneAt.flatMap(Date.server) }
}

nonisolated extension Chore {
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
                  part: try c.decodeIfPresent(ChorePart.self, forKey: .part) ?? time.flatMap { ChorePart.of(time: $0) } ?? .day,
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
nonisolated struct ChoreItem: Codable, Hashable, Identifiable, Sendable {
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
                  part: try c.decodeIfPresent(ChorePart.self, forKey: .part) ?? time.flatMap { ChorePart.of(time: $0) } ?? .day,
                  time: time, repeating: try c.decodeIfPresent(Bool.self, forKey: .repeating) ?? false,
                  done: try c.decodeIfPresent(Bool.self, forKey: .done) ?? false,
                  doneAt: try c.decodeIfPresent(String.self, forKey: .doneAt),
                  doneBy: try c.decodeIfPresent(ChorePerson.self, forKey: .doneBy),
                  subscribed: try c.decodeIfPresent(Bool.self, forKey: .subscribed) ?? false)
    }
}

/// GET /chores/agenda?from=&to=&today=: every day of the range with its chores, and the open
/// single chores whose day passed. Decoded off the main thread (as the chores' page).
nonisolated struct ChoreAgenda: Codable, Equatable, OffMainDecodable {
    nonisolated struct DayItems: Codable, Equatable, Sendable {
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

    /// The days the agenda loads around `day`: blocks of 62 days (the most the server answers)
    /// from 30 days before today, so stepping through a block asks nothing new.
    static func window(around day: Day, today: Day) -> (from: Day, to: Day) {
        let length = 62
        let start = today.adding(days: -30)
        let offset = CalendarMath.ordinal(day) - CalendarMath.ordinal(start)
        let block = offset >= 0 ? offset / length : -((-offset + length - 1) / length)
        let from = start.adding(days: block * length)
        return (from, from.adding(days: length - 1))
    }
}

/// GET /chores?today=
nonisolated struct ChoresPage: Codable, Equatable, OffMainDecodable {
    var chores: [Chore]
    /// Whom chores can be for.
    var people: [ChorePerson]
    /// The account is an editor of the family.
    var canEdit: Bool
    /// When the family's parts of the day start; nil from an older server (`.standard`).
    var dayParts: ChoreDayParts? = nil
}

/// The answer of POST, PATCH, GET /chores/{id}, POST /chores/{id}/done and …/subscribe.
nonisolated struct ChoreResponse: Codable, OffMainDecodable {
    let chore: Chore
}

/// What POST /chores takes (and PATCH /chores/{id}, which gets it whole). `assigneeId`, `time`
/// and `rrule` are sent as null when empty, so an edit clears them. A new chore carries the id the
/// app made for it (`id`), so sending it again can't add it twice.
struct ChoreInput: Codable, Equatable {
    /// A new chore's id (POST only).
    var id: String?
    var title: String
    var note: String = ""
    /// A member's account id or a person's id; nil: nobody.
    var assigneeId: String?
    var day: Day
    var time: String?
    /// With a time, the time's (`effectivePart(_:)`).
    var part: ChorePart = .day
    var rrule: String?
    /// The accounts notified when it's due.
    var subscriberIds: [String] = []

    init(id: String? = nil, title: String, note: String = "", assigneeId: String? = nil, day: Day, time: String? = nil,
         part: ChorePart = .day, rrule: String? = nil, subscriberIds: [String] = []) {
        self.id = id
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

    /// The part sent: the time's when there is one (the server works it out again by the
    /// family's day parts).
    func effectivePart(_ parts: ChoreDayParts = .standard) -> ChorePart {
        time.flatMap { ChorePart.of(time: $0, in: parts) } ?? part
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, note, assigneeId, day, time, part, rrule, subscriberIds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "",
                  assigneeId: try c.decodeIfPresent(String.self, forKey: .assigneeId),
                  day: try c.decode(Day.self, forKey: .day), time: try c.decodeIfPresent(String.self, forKey: .time),
                  part: try c.decodeIfPresent(ChorePart.self, forKey: .part) ?? .day,
                  rrule: try c.decodeIfPresent(String.self, forKey: .rrule),
                  subscriberIds: try c.decodeIfPresent([String].self, forKey: .subscriberIds) ?? [])
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(note, forKey: .note)
        try c.encode(assigneeId, forKey: .assigneeId)
        try c.encode(day, forKey: .day)
        try c.encode(time, forKey: .time)
        try c.encode(effectivePart(), forKey: .part)
        try c.encode(rrule, forKey: .rrule)
        try c.encode(subscriberIds, forKey: .subscriberIds)
    }
}

/// POST /chores/{id}/done: a single chore, or a repeating one's occurrence `day`.
struct ChoreDoneBody: Codable, Equatable {
    var done: Bool
    var day: Day?

    private enum CodingKeys: String, CodingKey { case done, day }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(done: try c.decode(Bool.self, forKey: .done), day: try c.decodeIfPresent(Day.self, forKey: .day))
    }

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
struct ChoreSubscribeBody: Codable, Equatable {
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

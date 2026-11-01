import Foundation

// The chores of a family (server/lib/chores/routes.ts): GET /chores?today= and the chore the
// other routes answer with.

/// Someone a chore can be for: a member with an account, or one of the family's people without
/// one (`familyNames` on the server).
struct ChorePerson: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// A member with an account (can tick their chores off themselves).
    let account: Bool
}

/// One chore: once (due on `day`) or repeating (`rrule` from `day` on), maybe for someone.
struct Chore: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let note: String
    let assignee: ChorePerson?
    /// The due day, or a repeating chore's first.
    let day: Day
    /// "HH:MM"; nil: any time of the day.
    let time: String?
    /// The RRULE value; nil: once.
    let rrule: String?
    /// Done (a chore that's once; a repeating one never is).
    let done: Bool
    let doneAt: String?
    /// When it's due next: an open single chore's day (also when past: overdue), nil when it's
    /// done; a repeating one's first occurrence from today on, nil once the series ended.
    let next: Day?
    let createdAt: String
    let updatedAt: String
    /// A repeating chore's occurrences around today, ascending: the last one before today, today's
    /// and the first after today (each if there is one); empty for a single chore. Older servers
    /// don't send it.
    var occurrences: [Day] = []

    var isRepeating: Bool { rrule != nil }
    var rule: RepeatRule? { rrule.flatMap(RepeatRule.init) }
    var doneDate: Date? { doneAt.flatMap(Date.server) }

    /// Open and its day passed.
    func isOverdue(today: Day) -> Bool {
        !isRepeating && !done && day < today
    }
}

extension Chore {
    private enum CodingKeys: String, CodingKey {
        case id, title, note, assignee, day, time, rrule, done, doneAt, next, createdAt, updatedAt, occurrences
    }

    /// `occurrences` may be missing (an older server): none then.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  note: try c.decode(String.self, forKey: .note),
                  assignee: try c.decodeIfPresent(ChorePerson.self, forKey: .assignee),
                  day: try c.decode(Day.self, forKey: .day), time: try c.decodeIfPresent(String.self, forKey: .time),
                  rrule: try c.decodeIfPresent(String.self, forKey: .rrule), done: try c.decode(Bool.self, forKey: .done),
                  doneAt: try c.decodeIfPresent(String.self, forKey: .doneAt),
                  next: try c.decodeIfPresent(Day.self, forKey: .next),
                  createdAt: try c.decode(String.self, forKey: .createdAt),
                  updatedAt: try c.decode(String.self, forKey: .updatedAt),
                  occurrences: try c.decodeIfPresent([Day].self, forKey: .occurrences) ?? [])
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

/// The answer of POST, PATCH, GET /chores/{id} and POST /chores/{id}/done.
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
    var rrule: String?

    init(title: String, note: String = "", assigneeId: String? = nil, day: Day, time: String? = nil,
         rrule: String? = nil) {
        self.title = title
        self.note = note
        self.assigneeId = assigneeId
        self.day = day
        self.time = time
        self.rrule = rrule
    }

    init(_ chore: Chore) {
        self.init(title: chore.title, note: chore.note, assigneeId: chore.assignee?.id, day: chore.day,
                  time: chore.time, rrule: chore.rrule)
    }

    private enum CodingKeys: String, CodingKey {
        case title, note, assigneeId, day, time, rrule
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(note, forKey: .note)
        try c.encode(assigneeId, forKey: .assigneeId)
        try c.encode(day, forKey: .day)
        try c.encode(time, forKey: .time)
        try c.encode(rrule, forKey: .rrule)
    }
}

/// Whose chores the list shows.
enum ChoreFilter: Hashable {
    case everyone
    /// Those for this person (`ChorePerson.id`).
    case person(String)
    /// Those for nobody in particular.
    case nobody

    func matches(_ chore: Chore) -> Bool {
        switch self {
        case .everyone: true
        case let .person(id): chore.assignee?.id == id
        case .nobody: chore.assignee == nil
        }
    }
}

/// The chores list's sections, in order.
struct ChoreSections: Equatable {
    enum Kind: String, CaseIterable {
        /// Open single chores whose day passed.
        case overdue
        /// Due today, once or repeating.
        case today
        /// Single chores due later.
        case upcoming
        /// Repeating chores not due today (also those whose series ended).
        case repeating
        /// Single chores done lately, the latest first.
        case done
    }

    var overdue: [Chore] = []
    var today: [Chore] = []
    var upcoming: [Chore] = []
    var repeating: [Chore] = []
    var done: [Chore] = []

    /// How long a done chore stays in the list.
    static let doneDays = 14

    /// The sections of `chores` (in the server's order: by `next`, then title), for `filter`.
    static func make(_ chores: [Chore], today: Day, filter: ChoreFilter = .everyone, now: Date = Date()) -> ChoreSections {
        var sections = ChoreSections()
        let since = now.addingTimeInterval(-TimeInterval(doneDays * 24 * 3600))
        for chore in chores where filter.matches(chore) {
            if chore.isRepeating {
                if chore.next == today { sections.today.append(chore) } else { sections.repeating.append(chore) }
            } else if chore.done {
                if (chore.doneDate ?? now) >= since { sections.done.append(chore) }
            } else if chore.day < today {
                sections.overdue.append(chore)
            } else if chore.day == today {
                sections.today.append(chore)
            } else {
                sections.upcoming.append(chore)
            }
        }
        sections.done.sort { ($0.doneDate ?? .distantPast) > ($1.doneDate ?? .distantPast) }
        return sections
    }

    func chores(_ kind: Kind) -> [Chore] {
        switch kind {
        case .overdue: overdue
        case .today: today
        case .upcoming: upcoming
        case .repeating: repeating
        case .done: done
        }
    }

    var isEmpty: Bool { Kind.allCases.allSatisfy { chores($0).isEmpty } }
}

/// How a chore reads in the list.
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
        let name: String
        switch day {
        case today: name = String(localized: "Today")
        case today.adding(days: 1): name = String(localized: "Tomorrow")
        case today.adding(days: -1): name = String(localized: "Yesterday")
        default:
            name = day.year == today.year
                ? day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
                : day.date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
        }
        guard let time else { return name }
        return "\(name), \(time)"
    }
}

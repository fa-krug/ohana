import Foundation

// What the assistant found to add, e.g. in a scanned letter (server: the suggest_items tool):
// events for the family's calendar, tasks and deadlines for the user's Reminders. Like a Reminders
// edit nothing is added until the user picks which ones on the card (`AssistantSuggestionsCard`)
// and taps Add; the app adds them (`AssistantSuggestionsApply`: events through the family API,
// tasks and deadlines through EventKit) and answers with one result per suggestion, the ones left
// out `{ok: false, declined: true}`.

/// The suggestions of one tool call (`kind: "suggestions"`).
struct AssistantSuggestions: Equatable {
    var id: String
    /// What it found, e.g. "3 dates from the school letter".
    var summary: String
    /// Where they come from (e.g. the letter's sender), when the assistant said.
    var source: String?
    var ops: [AssistantSuggestionOp]
    /// Added (with each suggestion's result) or none of them.
    var answer: Answer?
    /// The user wrote a new message instead.
    var skipped: Bool

    typealias Answer = AssistantRemindersEdit.Answer

    /// Ticked at first: every suggestion this app can add.
    var initialPicks: Set<Int> {
        Set(ops.indices.filter { ops[$0].kind != .unknown })
    }

    /// Any of `picks` goes into Reminders.
    func needsReminders(_ picks: Set<Int>) -> Bool {
        picks.contains { $0 < ops.count && ops[$0].kind.isReminder }
    }

    /// How it ended, in a few words ("Added 3 of 4"); nil while it waits.
    var outcome: String? {
        guard let answer else { return skipped ? String(localized: "Not answered") : nil }
        let results = answer.applied ? answer.results ?? [] : []
        let added = results.filter(\.ok).count
        let failed = results.filter(\.failed).count
        let total = ops.count
        var text = added == 0 ? String(localized: "Nothing added") : String(localized: "Added \(added) of \(total)")
        if failed > 0 { text += ", " + String(localized: "\(failed) failed") }
        return text
    }
}

/// One suggestion: an event (`date`, `endDate`?, `start`?/`end`? "HH:MM", `location`?, `person`?,
/// `note`?), a task (`due`? "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM") or a deadline (`due` always), the
/// last two with the Reminders list they go into (`list`, `listTitle`; null: the device's default
/// list). Decoded leniently: a kind this app doesn't know keeps its `op` (and can't be added).
struct AssistantSuggestionOp: Decodable, Equatable {
    enum Kind: Equatable {
        case event, task, deadline, unknown

        init(_ op: String) {
            switch op {
            case "event": self = .event
            case "task": self = .task
            case "deadline": self = .deadline
            default: self = .unknown
            }
        }

        var isReminder: Bool { self == .task || self == .deadline }
    }

    /// event | task | deadline
    var op: String
    var title: String
    var date: String?
    var endDate: String?
    var start: String?
    var end: String?
    var location: String?
    var person: String?
    var note: String?
    var due: String?
    var list: String?
    var listTitle: String?

    var kind: Kind { Kind(op) }

    init(op: String, title: String, date: String? = nil, endDate: String? = nil, start: String? = nil,
         end: String? = nil, location: String? = nil, person: String? = nil, note: String? = nil, due: String? = nil,
         list: String? = nil, listTitle: String? = nil) {
        self.op = op
        self.title = title
        self.date = date
        self.endDate = endDate
        self.start = start
        self.end = end
        self.location = location
        self.person = person
        self.note = note
        self.due = due
        self.list = list
        self.listTitle = listTitle
    }

    private enum Keys: String, CodingKey {
        case op, title, date, endDate, start, end, location, person, note, due, list, listTitle
    }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            self.init(op: "", title: "")
            return
        }
        func opt(_ key: Keys) -> String? {
            guard let text = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init(op: opt(.op) ?? "", title: opt(.title) ?? "", date: opt(.date), endDate: opt(.endDate),
                  start: opt(.start), end: opt(.end), location: opt(.location), person: opt(.person), note: opt(.note),
                  due: opt(.due), list: opt(.list), listTitle: opt(.listTitle))
    }

    // MARK: Reading the values

    /// "HH:MM" as hour and minute; nil for anything else.
    static func clock(_ text: String?) -> ReminderDue.Time? {
        guard let text, text.count == 5 else { return nil }
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1],
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return .init(hour: hour, minute: minute)
    }

    /// "YYYY-MM-DD" as a day; nil for anything else.
    static func day(_ text: String?) -> Day? {
        guard let text, text.count == 10 else { return nil }
        return Day(text)
    }

    /// The event for POST /events (a suggestion of another kind, or one that can't be read, throws).
    func eventInput() throws -> CalendarEventInput {
        guard kind == .event, !title.isEmpty else { throw AssistantSuggestionsApply.ApplyError.unsupported }
        guard let first = Self.day(date) else { throw DeviceCalendarError.invalidTime }
        var last: Day?
        if let endDate {
            guard let day = Self.day(endDate) else { throw DeviceCalendarError.invalidTime }
            last = max(day, first)
        }
        var from: String?
        var until: String?
        if let start {
            guard Self.clock(start) != nil else { throw DeviceCalendarError.invalidTime }
            from = start
            if let end {
                guard Self.clock(end) != nil else { throw DeviceCalendarError.invalidTime }
                until = end
            }
        }
        return CalendarEventInput(date: first, endDate: last, start: from, end: until, title: title,
                                  location: location ?? "", person: person ?? "", note: note ?? "")
    }

    /// The reminder for a task or deadline (a deadline needs its day).
    func reminderDraft() throws -> ReminderDraft {
        guard kind.isReminder, !title.isEmpty else { throw AssistantSuggestionsApply.ApplyError.unsupported }
        var when: ReminderDue?
        if let due {
            guard let value = ReminderDue(due) else { throw DeviceCalendarError.invalidTime }
            when = value
        }
        if kind == .deadline, when == nil { throw DeviceCalendarError.invalidTime }
        return ReminderDraft(title: title, notes: note, due: when)
    }
}

/// One suggestion in plain words: an icon by kind, the title, when (an event's day(s) and times,
/// "by …" for a deadline, "due …" for a task) and a fainter detail (where, who, the list, the note).
struct AssistantSuggestionLine: Equatable {
    var icon: String
    var title: String
    var when: String?
    var detail: String?

    static func make(_ op: AssistantSuggestionOp, locale: Locale = .current) -> Self {
        switch op.kind {
        case .event:
            let detail = [op.location, op.person, op.note].compactMap { $0 }
            return Self(icon: "calendar", title: op.title, when: eventWhen(op, locale: locale),
                        detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
        case .task, .deadline:
            let due = op.due.flatMap(ReminderDue.init).map { AssistantReminderOpLine.dueText($0, locale: locale) }
            let when = due.map { op.kind == .deadline ? String(localized: "by \($0)") : String(localized: "due \($0)") }
            let list = op.listTitle ?? String(localized: "Reminders")
            let detail = [list, op.note].compactMap { $0 }
            return Self(icon: op.kind == .deadline ? "flag" : "checklist", title: op.title, when: when,
                        detail: detail.joined(separator: " · "))
        case .unknown:
            return Self(icon: "questionmark.circle", title: op.title.isEmpty ? op.op : op.title,
                        detail: String(localized: "This version of Ohana can’t add this."))
        }
    }

    /// "Fri 13 Nov", "Fri 13 – Sun 15 Nov", "Fri 13 Nov, 15:00 – 17:00" (in the user's language).
    static func eventWhen(_ op: AssistantSuggestionOp, locale: Locale = .current) -> String? {
        guard let first = AssistantSuggestionOp.day(op.date) else { return nil }
        let last = AssistantSuggestionOp.day(op.endDate).flatMap { $0 > first ? $0 : nil }
        guard let start = AssistantSuggestionOp.clock(op.start) else {
            return AssistantCalendarOpLine.whenText(start: ReminderDue(day: first), end: last.map { ReminderDue(day: $0) },
                                                    allDay: true, locale: locale)
        }
        let from = ReminderDue(day: first, time: start)
        if let end = AssistantSuggestionOp.clock(op.end) {
            return AssistantCalendarOpLine.whenText(start: from, end: ReminderDue(day: last ?? first, time: end),
                                                    allDay: false, locale: locale)
        }
        let text = AssistantReminderOpLine.dueText(from, locale: locale)
        guard let last else { return text }
        return "\(text) – \(AssistantReminderOpLine.dueText(ReminderDue(day: last), locale: locale))"
    }
}

/// Adds an event to the family's calendar (tests fake it); its id.
protocol AssistantEventCreating {
    func createEvent(_ input: CalendarEventInput) async throws -> String
}

/// POST /events on the family API.
struct FamilyEventCreator: AssistantEventCreating {
    let api: FamilyAPI

    func createEvent(_ input: CalendarEventInput) async throws -> String {
        struct Created: Decodable { let id: String }
        let request = CalendarEventRequest.create(input)
        let client = api.client
        let (data, _) = try await client.data(for: client.request(request.method, api.path(request.path),
                                                                  query: request.query, body: request.body))
        return try client.decode(Created.self, from: data).id
    }
}

/// Adds the picked suggestions, in order, and says how each went.
enum AssistantSuggestionsApply {
    /// Every picked suggestion is tried (one that fails doesn't stop the others); the ones left
    /// out are `declined`. Events are added one by one; the reminders that went through are saved
    /// together at the end, and if that fails none of them is. `reminders` is needed only with a
    /// picked task or deadline; `defaultListID` is where those without a list go.
    static func perform(_ ops: [AssistantSuggestionOp], picks: Set<Int>, events: any AssistantEventCreating,
                        reminders: (any RemindersWriting)?, defaultListID: String?) async -> [AssistantReminderResult] {
        var results: [AssistantReminderResult] = []
        var added: [Int] = []
        for (index, op) in ops.enumerated() {
            guard picks.contains(index) else {
                results.append(.declined)
                continue
            }
            do {
                switch op.kind {
                case .event:
                    let input = try op.eventInput()
                    results.append(.done(try await events.createEvent(input)))
                case .task, .deadline:
                    let draft = try op.reminderDraft()
                    guard let reminders else { throw RemindersError.noAccess }
                    guard let list = op.list ?? defaultListID else { throw ApplyError.noDefaultList }
                    results.append(.done(try reminders.add(draft, to: list, commit: false)))
                    added.append(index)
                case .unknown:
                    throw ApplyError.unsupported
                }
            } catch {
                results.append(.failed(error.localizedDescription))
            }
        }
        guard !added.isEmpty, let reminders else { return results }
        do {
            try reminders.commit()
        } catch {
            reminders.reset()
            for index in added { results[index] = .failed(error.localizedDescription) }
        }
        return results
    }

    enum ApplyError: LocalizedError {
        case unsupported
        case noDefaultList

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "This version of Ohana can’t add this.")
            case .noDefaultList: String(localized: "There’s no default Reminders list on this device.")
            }
        }
    }
}

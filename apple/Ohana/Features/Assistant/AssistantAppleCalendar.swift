import Foundation

// The assistant's Apple Calendar tools on the device (server: lib/assistant/tools/apple-calendar.ts),
// like its Reminders tools (AssistantReminders.swift). The device's calendars never live on the
// server: every message carries what the assistant may know of them (`AssistantCalendarContext`,
// only with full access and never in the demo), and the changes it suggests
// (`AssistantCalendarEdit`) are applied here, once the user says so (`AssistantCalendarApply`),
// then answered with each op's result.

/// What the app tells the assistant about the device's calendars (`appleCalendar` in a chat
/// request): the calendars (which may be changed, which one the family syncs with) and their
/// events from a week back to 90 days ahead, sorted by start. Capped like the server caps it
/// (`cleanAppleCalendar`).
struct AssistantCalendarContext: Encodable, Equatable {
    static let maxCalendars = 100
    static let maxEvents = 1000
    static let maxTitle = 200
    static let maxNotes = 1000
    static let maxLocation = 300
    static let maxID = 300
    /// The days it covers, around today.
    static let daysBack = 7
    static let daysAhead = 90

    var from: String
    var to: String
    var calendars: [CalendarEntry]
    var events: [Event]

    struct CalendarEntry: Encodable, Equatable {
        var id: String
        var title: String
        var account: String
        var writable: Bool
        /// The calendar this family syncs with on this device.
        var ohana: Bool
    }

    struct Event: Encodable, Equatable {
        /// The event's id; "@YYYY-MM-DD" (its original day) added for an occurrence of a series.
        var id: String
        /// The calendar's id.
        var calendar: String
        var title: String
        var allDay: Bool
        var start: String
        /// The last day for an all-day event.
        var end: String
        var location: String?
        var notes: String?
        var rrule: String?
    }

    /// The snapshot of what `DeviceCalendarStore` read: the calendars (at most 100) and their
    /// events by start (at most 1000), texts cut short; entries with overlong ids are left out.
    static func build(calendars all: [DeviceCalendar], events: [DeviceEvent], from: Day, to: Day,
                      ohanaCalendarID: String?) -> Self {
        let calendars = all.filter { $0.id.count <= maxID }.prefix(maxCalendars).map {
            CalendarEntry(id: $0.id, title: cut($0.title, maxTitle), account: cut($0.account, maxTitle),
                     writable: $0.isWritable, ohana: $0.id == ohanaCalendarID)
        }
        let ids = Set(calendars.map(\.id))
        let list = events
            .filter { ids.contains($0.calendarID) && $0.ref.description.count <= maxID }
            .sorted { ($0.start.description, $0.title) < ($1.start.description, $1.title) }
            .prefix(maxEvents)
            .map { e in
                Event(id: e.ref.description, calendar: e.calendarID, title: cut(e.title, maxTitle), allDay: e.allDay,
                      start: e.start.description, end: e.end.description,
                      location: e.location.flatMap { nonEmpty(cut($0, maxLocation)) },
                      notes: e.notes.flatMap { nonEmpty(cut($0, maxNotes)) }, rrule: e.rrule)
            }
        return Self(from: from.description, to: to.description, calendars: Array(calendars), events: Array(list))
    }

    private static func cut(_ text: String, _ max: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// The device's calendars now, for the family of `api`; nil in the demo and without full
    /// access (then the server offers no Apple Calendar tools). The access is never asked for here.
    static func current(for api: FamilyAPI, store: DeviceCalendarStore = .shared, today: Day = .today) async -> Self? {
        guard !api.client.isDemo else { return nil }
        store.refreshAccess()
        guard store.hasAccess else { return nil }
        let from = today.adding(days: -daysBack)
        let to = today.adding(days: daysAhead)
        return build(calendars: store.calendars(), events: store.events(from: from, to: to), from: from, to: to,
                     ohanaCalendarID: AppleCalendarSync.shared.state(for: api)?.calendarID)
    }
}

/// What applying an edit needs of `DeviceCalendarStore` (tests fake it).
protocol DeviceCalendarWriting {
    func calendar(_ id: String) -> DeviceCalendar?
    func add(_ draft: DeviceEventDraft, commit: Bool) throws -> () -> String?
    func update(_ ref: DeviceEventRef, near: Day?, span: DeviceEventSpan, _ change: DeviceEventChange, commit: Bool) throws
    func delete(_ ref: DeviceEventRef, near: Day?, span: DeviceEventSpan, commit: Bool) throws
    func commit() throws
    func reset()
}

extension DeviceCalendarStore: DeviceCalendarWriting {}

/// Applies the ops of a calendar edit, in order, and says how each went.
enum AssistantCalendarApply {
    /// Every op is tried (one that fails doesn't stop the others) and the ones that went through
    /// are saved together at the end; if that fails, nothing is saved and every op failed.
    static func perform(_ ops: [AssistantCalendarOp], on store: some DeviceCalendarWriting) -> [AssistantReminderResult] {
        var added: [Int: () -> String?] = [:]
        var results = ops.enumerated().map { index, op -> AssistantReminderResult in
            do {
                switch try apply(op, store) {
                case let .added(id): added[index] = id
                case .changed: break
                }
                return .done(op.op == "add" ? nil : op.id)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard results.contains(where: \.ok) else { return results }
        do {
            try store.commit()
        } catch {
            store.reset()
            let message = error.localizedDescription
            return results.map { $0.ok ? .failed(message) : $0 }
        }
        // A new event has its id once saved.
        for (index, id) in added { results[index].id = id() }
        return results
    }

    private enum Applied {
        case added(() -> String?)
        case changed
    }

    /// One op (not saved yet).
    private static func apply(_ op: AssistantCalendarOp, _ store: some DeviceCalendarWriting) throws -> Applied {
        let span: DeviceEventSpan = op.span == "future" ? .future : .this
        switch op.op {
        case "add":
            let title = op.title ?? ""
            guard !title.isEmpty, !op.calendar.isEmpty else { throw ApplyError.unsupported }
            guard let start = op.start.flatMap(ReminderDue.init) else { throw DeviceCalendarError.invalidTime }
            let end = try op.end.map { text in
                guard let end = ReminderDue(text) else { throw DeviceCalendarError.invalidTime }
                return end
            }
            let rule = try op.rrule.map { text in
                guard let rule = RepeatRule(text) else { throw DeviceCalendarError.invalidRule }
                return rule
            }
            let draft = DeviceEventDraft(
                calendarID: op.calendar, title: title, times: .new(start: start, end: end, allDay: op.allDay),
                location: op.location.flatMap { $0.isEmpty ? nil : $0 }, notes: op.notes.flatMap { $0.isEmpty ? nil : $0 },
                rule: rule
            )
            return .added(try store.add(draft, commit: false))
        case "update":
            let ref = try eventRef(op)
            // Checked first: a change half made to an event that can't move would be saved later.
            if !op.calendar.isEmpty {
                guard let calendar = store.calendar(op.calendar) else { throw DeviceCalendarError.calendarNotFound }
                guard calendar.isWritable else { throw DeviceCalendarError.readOnlyCalendar }
            }
            var change = DeviceEventChange(calendarID: op.calendar.isEmpty ? nil : op.calendar)
            if let title = op.title, !title.isEmpty { change.title = title }
            if let text = op.start {
                guard let start = ReminderDue(text) else { throw DeviceCalendarError.invalidTime }
                change.start = start
            }
            if let text = op.end {
                guard let end = ReminderDue(text) else { throw DeviceCalendarError.invalidTime }
                change.end = end
            }
            change.allDay = op.allDay
            if let location = op.location { change.location = .some(location.isEmpty ? nil : location) }
            if let notes = op.notes { change.notes = .some(notes.isEmpty ? nil : notes) }
            try store.update(ref, near: op.near, span: span, change, commit: false)
            return .changed
        case "delete":
            try store.delete(try eventRef(op), near: op.near, span: span, commit: false)
            return .changed
        default:
            throw ApplyError.unsupported
        }
    }

    private static func eventRef(_ op: AssistantCalendarOp) throws -> DeviceEventRef {
        guard let id = op.id, !id.isEmpty else { throw DeviceCalendarError.eventNotFound }
        return DeviceEventRef(id)
    }

    typealias ApplyError = AssistantRemindersApply.ApplyError
}

/// One op of a calendar edit in plain words, e.g. "Add “Dentist” to Family" with "Thu 5 Nov,
/// 09:00 – 10:00" below it, with an icon (deletes in red).
struct AssistantCalendarOpLine: Equatable {
    var icon: String
    var text: String
    var detail: String?
    /// It deletes an event.
    var destructive = false

    /// `currentCalendarID`: the calendar the event is in now, when known (an update to another
    /// calendar moves it).
    static func make(_ op: AssistantCalendarOp, currentCalendarID: String? = nil, locale: Locale = .current) -> Self {
        let subject = op.subject
        let was = op.eventStart.flatMap(ReminderDue.init).map {
            whenText(start: $0, end: op.eventEnd.flatMap(ReminderDue.init), allDay: op.eventAllDay ?? ($0.time == nil),
                     locale: locale)
        }
        func on(_ text: String) -> String { was.map { text + " · " + $0 } ?? text }
        switch op.op {
        case "add":
            var parts: [String] = []
            if let start = op.start.flatMap(ReminderDue.init) {
                parts.append(whenText(start: start, end: op.end.flatMap(ReminderDue.init),
                                      allDay: op.allDay ?? (start.time == nil), locale: locale))
            }
            if let rule = op.rrule.flatMap(RepeatRule.init) { parts.append(rule.summary(locale: locale)) }
            if let location = op.location, !location.isEmpty { parts.append(location) }
            return Self(icon: "calendar.badge.plus", text: String(localized: "Add “\(subject)” to \(op.calendarTitle)"),
                        detail: parts.joined(separator: " · "))
        case "update":
            let start = op.start.flatMap(ReminderDue.init)
            let end = op.end.flatMap(ReminderDue.init)
            let changes = op.title != nil || start != nil || end != nil || op.allDay != nil || op.location != nil
                || op.notes != nil
            let moves = !changes || (currentCalendarID.map { !op.calendar.isEmpty && $0 != op.calendar } ?? false)
            var parts: [String] = []
            if let title = op.title { parts.append(String(localized: "rename to “\(title)”")) }
            if let start {
                let when = whenText(start: start, end: end, allDay: op.allDay ?? (start.time == nil), locale: locale)
                parts.append(String(localized: "to \(when)"))
            } else if let end {
                let when = AssistantReminderOpLine.dueText(end, locale: locale)
                parts.append(String(localized: "until \(when)"))
            } else if let allDay = op.allDay {
                parts.append(allDay ? String(localized: "all day") : String(localized: "at a set time"))
            }
            if let location = op.location {
                parts.append(location.isEmpty ? String(localized: "remove the location")
                                              : String(localized: "location: \(location)"))
            }
            if let notes = op.notes {
                parts.append(notes.isEmpty ? String(localized: "remove the notes") : String(localized: "notes: \(notes)"))
            }
            if moves { parts.append(String(localized: "move to \(op.calendarTitle)")) }
            if let span = spanText(op) { parts.append(span) }
            let text = changes ? String(localized: "Change “\(subject)”")
                               : String(localized: "Move “\(subject)” to \(op.calendarTitle)")
            return Self(icon: changes ? "pencil.circle" : "arrow.right.circle", text: on(text),
                        detail: parts.joined(separator: ", "))
        case "delete":
            let detail = [op.calendarTitle, spanText(op)].compactMap { $0 }.filter { !$0.isEmpty }
            return Self(icon: "trash", text: on(String(localized: "Delete “\(subject)”")),
                        detail: detail.joined(separator: " · "), destructive: true)
        default:
            return Self(icon: "questionmark.circle", text: subject.isEmpty ? op.op : "\(op.op) “\(subject)”",
                        detail: op.calendarTitle.isEmpty ? nil : op.calendarTitle)
        }
    }

    /// For an occurrence of a repeating event: which of them it is for.
    private static func spanText(_ op: AssistantCalendarOp) -> String? {
        guard let id = op.id, DeviceEventRef(id).occurrence != nil else { return nil }
        return op.span == "future" ? String(localized: "this and all following") : String(localized: "only this one")
    }

    /// "Thu 5 Nov", "Thu 5 – Sat 7 Nov" (all day), "Thu 5 Nov, 09:00 – 10:00" or
    /// "Thu 5 Nov, 22:00 – Fri 6 Nov, 01:00" (in the user's language).
    static func whenText(start: ReminderDue, end: ReminderDue?, allDay: Bool, locale: Locale = .current) -> String {
        let day = { (d: Day) in AssistantReminderOpLine.dueText(ReminderDue(day: d), locale: locale) }
        if allDay || start.time == nil {
            guard let last = end?.day, last > start.day else { return day(start.day) }
            return "\(day(start.day)) – \(day(last))"
        }
        let from = AssistantReminderOpLine.dueText(start, locale: locale)
        guard let end, let time = end.time else { return from }
        if end.day == start.day {
            var calendar = Day.calendar
            calendar.locale = locale
            let date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: end.day.date) ?? end.day.date
            let clock = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .hour().minute())
            return "\(from) – \(clock)"
        }
        return "\(from) – \(AssistantReminderOpLine.dueText(end, locale: locale))"
    }
}

extension AssistantCalendarEdit {
    /// How it ended, in a few words; nil while it waits.
    var outcome: String? {
        AssistantRemindersEdit.outcome(answer: answer, skipped: skipped, count: ops.count)
    }
}

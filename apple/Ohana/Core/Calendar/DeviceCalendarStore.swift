import EventKit
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

// The calendars of the device (Apple Calendar) as the assistant reads and changes them, as plain
// values (no EventKit types) so the logic over them is pure and testable: what
// `DeviceCalendarStore` reads (`DeviceCalendar`, `DeviceEvent`) and what it writes
// (`DeviceEventDraft`, `DeviceEventChange`). Times are wall-clock in the device's time zone, as
// text like a reminder's due date (`ReminderDue`: "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM").

/// A calendar of the device that holds events.
struct DeviceCalendar: Hashable, Identifiable {
    /// `calendarIdentifier`.
    var id: String
    var title: String
    /// The account it lives in ("iCloud", "On My iPhone", "Google").
    var account: String
    /// Events can be added and changed in it (not a subscription, the birthdays or read-only).
    var isWritable: Bool
}

/// One event as read; an occurrence of a repeating event has the day it was made for
/// (`occurrence`, its original day, also when it was moved).
struct DeviceEvent: Hashable {
    /// `eventIdentifier`; the same for every occurrence of a series.
    var id: String
    var calendarID: String
    var title: String
    var allDay: Bool
    var start: ReminderDue
    /// The last day for an all-day event.
    var end: ReminderDue
    var location: String?
    var notes: String?
    /// The series' rule (`RepeatRule.string`), on every occurrence.
    var rrule: String?
    var occurrence: Day?

    /// The id the assistant knows it by: the event's, "@YYYY-MM-DD" added for an occurrence.
    var ref: DeviceEventRef { DeviceEventRef(id: id, occurrence: occurrence) }
}

/// An event by the id the assistant knows it by: "<eventIdentifier>" or, for one occurrence of a
/// repeating event, "<eventIdentifier>@<original day>".
struct DeviceEventRef: Hashable, CustomStringConvertible {
    var id: String
    var occurrence: Day?

    init(id: String, occurrence: Day? = nil) {
        self.id = id
        self.occurrence = occurrence
    }

    init(_ text: String) {
        if let match = text.wholeMatch(of: /(.+)@(\d{4}-\d{2}-\d{2})/), let day = Day(String(match.2)) {
            self.init(id: String(match.1), occurrence: day)
        } else {
            self.init(id: text)
        }
    }

    var description: String { occurrence.map { "\(id)@\($0)" } ?? id }
}

/// Which occurrences of a repeating event a change is for.
enum DeviceEventSpan: Equatable {
    /// Only this one.
    case this
    /// This one and the ones after it.
    case future
}

/// An event to add.
struct DeviceEventDraft: Hashable {
    var calendarID: String
    var title: String
    var times: DeviceEventTimes
    var location: String?
    var notes: String?
    var rule: RepeatRule?
}

/// A change to an event: each field nil leaves it as it is; `.some(nil)` clears an optional one.
struct DeviceEventChange: Hashable {
    var title: String?
    var start: ReminderDue?
    var end: ReminderDue?
    var allDay: Bool?
    var location: String??
    var notes: String??
    /// The calendar it moves to (the one it is in leaves it there).
    var calendarID: String?

    var changesTimes: Bool { start != nil || end != nil || allDay != nil }
}

/// When an event is, as EventKit keeps it: a timed event from `start` to `end`; an all-day one
/// from the start of its first day to noon of its last (read back as that day however the
/// account stores the end, like the calendar sync).
struct DeviceEventTimes: Hashable {
    var start: Date
    var end: Date
    var allDay: Bool

    /// An hour, for a timed event without an end.
    static let defaultLength: TimeInterval = 3600

    /// A new event's: all day when `allDay` says so or `start` has no time; a timed one without
    /// an end lasts an hour; an all-day `end` is its last day.
    static func new(start: ReminderDue, end: ReminderDue?, allDay: Bool?) -> Self {
        if allDay ?? (start.time == nil) {
            return allDayTimes(start.day, max(end?.day ?? start.day, start.day))
        }
        let begin = date(start.day, start.time ?? morning)
        var finish = begin.addingTimeInterval(defaultLength)
        if let end { finish = date(end.day, end.time ?? start.time ?? morning) }
        return Self(start: begin, end: finish > begin ? finish : begin.addingTimeInterval(defaultLength), allDay: false)
    }

    /// `self` with a change's times: what isn't given stays; a changed start without an end keeps
    /// the length (in days for an all-day event).
    func changed(start newStart: ReminderDue?, end newEnd: ReminderDue?, allDay newAllDay: Bool?) -> Self {
        let first = Day(start)
        let last = lastDay
        let allDay = newAllDay ?? newStart.map { $0.time == nil } ?? self.allDay
        if allDay {
            let from = newStart?.day ?? first
            var to = newEnd?.day ?? last
            if newEnd == nil, newStart != nil { to = from.adding(days: Self.days(first, last)) }
            return Self.allDayTimes(from, max(to, from))
        }
        let length = self.allDay ? Self.defaultLength : max(end.timeIntervalSince(start), 0)
        let startTime = newStart?.time ?? (self.allDay ? Self.morning : Self.time(start))
        let begin = Self.date(newStart?.day ?? first, startTime)
        var finish: Date
        if let newEnd {
            finish = Self.date(newEnd.day, newEnd.time ?? startTime)
        } else if newStart != nil || self.allDay != allDay {
            finish = begin.addingTimeInterval(length > 0 ? length : Self.defaultLength)
        } else {
            finish = end
        }
        if finish < begin { finish = begin.addingTimeInterval(length > 0 ? length : Self.defaultLength) }
        return Self(start: begin, end: finish, allDay: false)
    }

    /// The day it ends on (an end at midnight ends the day before).
    var lastDay: Day {
        max(Day(end.addingTimeInterval(end > start ? -1 : 0)), Day(start))
    }

    /// As the assistant reads it: "YYYY-MM-DDTHH:MM" both, or the first and the last day.
    var text: (start: ReminderDue, end: ReminderDue) {
        if allDay { return (ReminderDue(day: Day(start)), ReminderDue(day: lastDay)) }
        let begin = Self.time(start)
        let finish = Self.time(max(end, start))
        return (ReminderDue(day: Day(start), time: begin), ReminderDue(day: Day(max(end, start)), time: finish))
    }

    /// 09:00, for a timed event that has no time yet.
    private static let morning = ReminderDue.Time(hour: 9, minute: 0)

    private static func allDayTimes(_ first: Day, _ last: Day) -> Self {
        Self(start: Day.calendar.startOfDay(for: first.date), end: last.date, allDay: true)
    }

    private static func date(_ day: Day, _ time: ReminderDue.Time) -> Date {
        Day.calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day.date) ?? day.date
    }

    private static func time(_ date: Date) -> ReminderDue.Time {
        let c = Day.calendar.dateComponents([.hour, .minute], from: date)
        return ReminderDue.Time(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    private static func days(_ a: Day, _ b: Day) -> Int {
        Day.calendar.dateComponents([.day], from: a.date, to: b.date).day ?? 0
    }
}

enum DeviceCalendarError: LocalizedError, Equatable {
    case noAccess
    case calendarNotFound
    case readOnlyCalendar
    case eventNotFound
    case invalidTime
    case invalidRule

    var errorDescription: String? {
        switch self {
        case .noAccess: String(localized: "Ohana has no access to your calendars.")
        case .calendarNotFound: String(localized: "The calendar is gone.")
        case .readOnlyCalendar: String(localized: "This calendar can’t be changed.")
        case .eventNotFound: String(localized: "The event is gone.")
        case .invalidTime: String(localized: "The time isn’t valid.")
        case .invalidRule: String(localized: "The repeat rule isn’t valid.")
        }
    }
}

/// The device's calendars through EventKit, for the assistant's Apple Calendar tools: one
/// `EKEventStore`, the access (only read here: it is given in the calendar settings' Apple
/// Calendar section, or the system's), the calendars, the events of a range, and changing events
/// by the assistant's ids (`DeviceEventRef`). Views reload on `revision`, which grows whenever the
/// calendars change.
@Observable
final class DeviceCalendarStore {
    static let shared = DeviceCalendarStore()

    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    private(set) var revision = 0

    @ObservationIgnored private var store = EKEventStore()
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    var hasAccess: Bool { access == .fullAccess }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAccess()
                self?.revision += 1
            }
        }
    }

    /// Reads the access again (it may have changed in the settings).
    func refreshAccess() {
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now != access else { return }
        access = now
        // A store made before access was given doesn't see the calendars.
        if hasAccess { store = EKEventStore() }
    }

    // MARK: Reading

    /// The calendars that hold events (not the birthdays), by account then title; empty without
    /// access.
    func calendars() -> [DeviceCalendar] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter { $0.type != .birthday }.map(Self.calendar)
            .sorted { ($0.account, $0.title.lowercased()) < ($1.account, $1.title.lowercased()) }
    }

    func calendar(_ id: String) -> DeviceCalendar? {
        ekCalendar(id).map(Self.calendar)
    }

    /// The events from the start of `from` to the end of `to` in every calendar, an occurrence of
    /// a repeating event each on its own.
    func events(from: Day, to: Day) -> [DeviceEvent] {
        guard hasAccess else { return [] }
        let found = fetch(from: from, to: to, calendars: nil)
        // A changed occurrence may not carry the series' rule.
        var rules: [String: String] = [:]
        for e in found {
            if let rule = e.recurrenceRules?.first.flatMap(RepeatRule.init(eventKit:)) {
                rules[Self.id(e)] = rules[Self.id(e)] ?? rule.string
            }
        }
        return found.compactMap { e in
            guard let calendar = e.calendar, e.startDate != nil else { return nil }
            let id = Self.id(e)
            let repeats = e.hasRecurrenceRules || e.isDetached
            let times = Self.times(e)
            let text = times.text
            return DeviceEvent(
                id: id, calendarID: calendar.calendarIdentifier, title: e.title ?? "", allDay: times.allDay,
                start: text.start, end: text.end, location: e.location, notes: e.notes,
                rrule: repeats ? rules[id] : nil,
                occurrence: repeats ? Day(e.occurrenceDate ?? e.startDate) : nil
            )
        }
    }

    /// The calendar an event is in now; nil when it isn't found.
    func calendarID(of ref: DeviceEventRef) -> String? {
        guard hasAccess else { return nil }
        return (store.event(withIdentifier: ref.id) ?? store.calendarItem(withIdentifier: ref.id) as? EKEvent)?
            .calendar?.calendarIdentifier
    }

    // MARK: Changing

    // Each change is saved at once unless `commit` is false: then `commit()` saves them together
    // (`reset()` drops them).

    /// Adds an event; its id, once saved.
    func add(_ draft: DeviceEventDraft, commit: Bool = true) throws -> () -> String? {
        try requireAccess()
        let calendar = try writableCalendar(draft.calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        Self.write(draft.times, to: event)
        event.location = draft.location
        event.notes = draft.notes
        event.recurrenceRules = draft.rule.map { [$0.ekRule] }
        try store.save(event, span: .thisEvent, commit: commit)
        return { event.eventIdentifier ?? event.calendarItemIdentifier }
    }

    /// Changes an event: an occurrence (`span`: only it or it and the ones after), or a single
    /// event or a whole series (an id without a day). `near`: the day it shows on now, where an
    /// occurrence moved away from its own day is found.
    func update(_ ref: DeviceEventRef, near: Day?, span: DeviceEventSpan, _ change: DeviceEventChange,
                commit: Bool = true) throws {
        let event = try writable(ref, near: near)
        if let title = change.title { event.title = title }
        if let location = change.location { event.location = location }
        if let notes = change.notes { event.notes = notes }
        if change.changesTimes {
            Self.write(Self.times(event).changed(start: change.start, end: change.end, allDay: change.allDay), to: event)
        }
        if let id = change.calendarID, id != event.calendar?.calendarIdentifier {
            event.calendar = try writableCalendar(id)
        }
        try store.save(event, span: ekSpan(ref, event, span), commit: commit)
    }

    func delete(_ ref: DeviceEventRef, near: Day?, span: DeviceEventSpan, commit: Bool = true) throws {
        let event = try writable(ref, near: near)
        try store.remove(event, span: ekSpan(ref, event, span), commit: commit)
    }

    /// Saves the changes made with `commit: false`.
    func commit() throws {
        try store.commit()
    }

    /// Drops the changes not committed yet.
    func reset() {
        store.reset()
    }

    // MARK: EventKit

    private func requireAccess() throws {
        refreshAccess()
        guard hasAccess else { throw DeviceCalendarError.noAccess }
    }

    private func ekCalendar(_ id: String) -> EKCalendar? {
        guard hasAccess, let calendar = store.calendar(withIdentifier: id),
              calendar.allowedEntityTypes.contains(.event) else { return nil }
        return calendar
    }

    private func writableCalendar(_ id: String) throws -> EKCalendar {
        guard let calendar = ekCalendar(id) else { throw DeviceCalendarError.calendarNotFound }
        guard Self.isWritable(calendar) else { throw DeviceCalendarError.readOnlyCalendar }
        return calendar
    }

    private func writable(_ ref: DeviceEventRef, near: Day?) throws -> EKEvent {
        try requireAccess()
        guard let event = find(ref, near: near) else { throw DeviceCalendarError.eventNotFound }
        guard let calendar = event.calendar, Self.isWritable(calendar) else { throw DeviceCalendarError.readOnlyCalendar }
        return event
    }

    /// A single event or a series' first occurrence by its id; an occurrence among the events
    /// of its own day (and of `near`, where it shows when it was moved).
    private func find(_ ref: DeviceEventRef, near: Day?) -> EKEvent? {
        guard let day = ref.occurrence else {
            return store.event(withIdentifier: ref.id) ?? store.calendarItem(withIdentifier: ref.id) as? EKEvent
        }
        let days = [day, near].compactMap { $0 }
        return fetch(from: days.min() ?? day, to: days.max() ?? day, calendars: nil).first { e in
            (e.eventIdentifier == ref.id || e.calendarItemIdentifier == ref.id)
                && Day(e.occurrenceDate ?? e.startDate) == day
        }
    }

    /// An occurrence: as asked; an id without a day: the whole series (from its first occurrence)
    /// or the single event.
    private func ekSpan(_ ref: DeviceEventRef, _ event: EKEvent, _ span: DeviceEventSpan) -> EKSpan {
        if ref.occurrence != nil { return span == .future ? .futureEvents : .thisEvent }
        return event.hasRecurrenceRules ? .futureEvents : .thisEvent
    }

    private func fetch(from: Day, to: Day, calendars: [EKCalendar]?) -> [EKEvent] {
        let start = Day.calendar.startOfDay(for: from.date)
        let end = Day.calendar.startOfDay(for: to.adding(days: 1).date)
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    private static func id(_ event: EKEvent) -> String {
        event.eventIdentifier ?? event.calendarItemIdentifier
    }

    private static func times(_ event: EKEvent) -> DeviceEventTimes {
        let start: Date = event.startDate ?? Date()
        return DeviceEventTimes(start: start, end: max(event.endDate ?? start, start), allDay: event.isAllDay)
    }

    private static func write(_ times: DeviceEventTimes, to event: EKEvent) {
        event.isAllDay = times.allDay
        event.startDate = times.start
        event.endDate = times.end
    }

    private static func isWritable(_ calendar: EKCalendar) -> Bool {
        calendar.allowsContentModifications && calendar.type != .birthday && calendar.type != .subscription
    }

    private static func calendar(_ calendar: EKCalendar) -> DeviceCalendar {
        DeviceCalendar(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                       isWritable: isWritable(calendar))
    }

    // MARK: Elsewhere

    /// Where the user allows the access: the app's page in Settings (iOS), Privacy & Security →
    /// Calendars (Mac).
    static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #endif
    }
}

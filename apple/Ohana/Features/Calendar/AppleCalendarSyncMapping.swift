import EventKit
import Foundation

// One sync's two sides in the planner's terms (`AppleCalendarSync`): the family's events and the
// Apple events as `OhanaSyncItem` and `AppleSyncEvent`, the links between them, and Ohana's event
// written back into an `EKEvent`.

extension AppleCalendarSync {
    /// A link's occurrences after its series changed as a whole: kept while the rule stays.
    static func kept(_ link: AppleSyncLink?, rule: String?) -> [Day: AppleSyncException] {
        guard let link, link.ohana.rrule == RepeatRule.canonical(rule) else { return [:] }
        return link.exceptions
    }

    static func occurrenceQuery(_ day: Day) -> [String: String?] {
        ["occurrence": day.description, "span": CalendarEventSpan.this.rawValue]
    }

    static func link(_ id: String, _ fields: OhanaSyncFields, _ event: EKEvent,
                             exceptions: [Day: AppleSyncException] = [:]) -> AppleSyncLink {
        let apple = Self.event(event)
        return AppleSyncLink(ohanaID: id, appleID: apple.localID, appleKey: apple.key, ohana: fields,
                             apple: apple.fields, exceptions: exceptions)
    }

    // MARK: Ohana ↔ the planner

    /// The family's events for the planner: a series with its occurrences around the window by their
    /// original day (as the rule makes them, changed on their own, taken out).
    static func items(_ series: [CalendarEventSeries], occurrences: [CalendarEvent], window: ClosedRange<Day>,
                      reach: ClosedRange<Day>) -> [OhanaSyncItem] {
        let byID = Dictionary(grouping: occurrences, by: \.id)
        return series.map { stored in
            let listed = byID[stored.id] ?? []
            var item = OhanaSyncItem(
                id: stored.id, externalId: stored.externalId, fields: OhanaSyncFields(stored),
                inWindow: listed.contains { $0.date <= window.upperBound && $0.endDate >= window.lowerBound }
                    || (stored.date <= window.upperBound && stored.endDate >= window.lowerBound)
            )
            guard stored.repeats else { return item }
            let overrides = Dictionary(stored.overrides.map { ($0.occurrence, $0) },
                                       uniquingKeysWith: { first, _ in first })
            for occurrence in listed {
                guard let day = occurrence.occurrence else { continue }
                let fields = OhanaSyncFields(occurrence: occurrence)
                item.occurrenceFields[day] = fields
                item.occurrences[day] = overrides[day] == nil ? .normal : .changed(fields)
            }
            // Changed ones moved far away still count on their own day.
            for override in stored.overrides where reach.contains(override.occurrence)
                && item.occurrences[override.occurrence] == nil {
                let fields = OhanaSyncFields(date: override.date, endDate: override.endDate, start: override.start,
                                             end: override.end, title: override.title, location: override.location,
                                             person: override.person, note: override.note, url: override.url)
                item.occurrenceFields[override.occurrence] = fields
                item.occurrences[override.occurrence] = .changed(fields)
            }
            for day in stored.exdates where reach.contains(day) { item.occurrences[day] = .deleted }
            return item
        }
    }

    // MARK: EventKit ↔ the planner

    /// The Apple events a pass works with: a series' or single event's own (`master`), and a series'
    /// occurrences by "id@day".
    struct AppleEvents {
        var masters: [String: EKEvent] = [:]
        var occurrences: [String: EKEvent] = [:]

        static func occurrenceKey(_ id: String, _ day: Day) -> String { "\(id)@\(day)" }
    }

    /// The fetched events for the planner: single events as they are, a series once (its first
    /// occurrence, `master`) with its occurrences by their original day.
    static func appleItems(_ fetched: [EKEvent], window: ClosedRange<Day>, events: inout AppleEvents,
                                   master: (String) -> EKEvent?) -> [AppleSyncEvent] {
        var order: [String] = []
        var groups: [String: [EKEvent]] = [:]
        for event in fetched {
            let id = event.calendarItemIdentifier
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(event)
        }
        return order.compactMap { id in
            let list = groups[id]!
            let inWindow = list.contains { each in
                let compared = event(each).fields
                return compared.day <= window.upperBound && compared.lastDay >= window.lowerBound
            }
            guard list.contains(where: { $0.hasRecurrenceRules || $0.isDetached }) else {
                events.masters[id] = list[0]
                let single = event(list[0])
                return AppleSyncEvent(localID: single.localID, key: single.key, url: list[0].url, fields: single.fields,
                                      inWindow: inWindow)
            }
            guard let first = master(id) else { return nil }
            events.masters[id] = first
            var occurrences: [Day: AppleOccurrence] = [:]
            for event in list {
                let day = Day(event.occurrenceDate ?? event.startDate)
                events.occurrences[AppleCalendarSync.AppleEvents.occurrenceKey(id, day)] = event
                occurrences[day] = event.isDetached ? .changed(fields(event, rule: false)) : .normal
            }
            let series = event(first)
            return AppleSyncEvent(localID: series.localID, key: series.key, url: first.url, fields: series.fields,
                                  inWindow: inWindow, occurrences: occurrences)
        }
    }

    /// An event's ids and what the planner compares of it (a series' first occurrence with its rule).
    static func event(_ event: EKEvent) -> (localID: String, key: String, fields: AppleSyncFields) {
        let id = event.calendarItemIdentifier
        let external = event.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? id
        return (id, external, fields(event, rule: true))
    }

    /// The event in Ohana's terms, in the device's time zone.
    static func fields(_ event: EKEvent, rule: Bool) -> AppleSyncFields {
        let start: Date = event.startDate ?? Date()
        let end: Date = max(event.endDate ?? start, start)
        let day = Day(start)
        // An all-day event's end is the end of its last day; one ending at midnight ends the day before.
        let lastDay = max(Day(end.addingTimeInterval(end > start ? -1 : 0)), day)
        var startTime: String?
        var endTime: String?
        if !event.isAllDay {
            let from = time(start)
            let to = time(end)
            startTime = from
            if end > start, to != "00:00", lastDay > day || to >= from { endTime = to }
        }
        return AppleSyncFields(
            day: day, lastDay: lastDay, start: startTime, end: endTime,
            title: event.title ?? "", location: event.location ?? "", notes: event.notes ?? "",
            rrule: rule ? event.recurrenceRules?.first.flatMap(RepeatRule.init(eventKit:)).map(\.string) : nil
        )
    }

    /// Writes Ohana's event into the Apple event: the days and times, the texts and (`rule`, a series
    /// or a single event as a whole) the rule. A timed event without an end keeps its length; a text
    /// that only reads the same as Ohana keeps it stays as Apple has it (a long note isn't cut).
    static func write(_ ohana: OhanaSyncFields, to event: EKEvent, isNew: Bool, rule: Bool) {
        writeTexts(ohana, to: event, isNew: isNew)
        writeTimes(ohana, to: event, isNew: isNew)
        if rule {
            event.recurrenceRules = ohana.rrule.flatMap(RepeatRule.init).map { [$0.ekRule] }
        }
    }

    /// The texts of Ohana's event; one that only reads the same as Ohana keeps what Apple has.
    static func writeTexts(_ ohana: OhanaSyncFields, to event: EKEvent, isNew: Bool) {
        let apple = AppleSyncMapping.apple(ohana)
        let same = isNew ? (title: false, location: false, notes: false)
            : AppleSyncMapping.unchangedTexts(ohana, over: fields(event, rule: false))
        if !same.title { event.title = apple.title }
        if !same.location { event.location = apple.location.isEmpty ? nil : apple.location }
        if !same.notes { event.notes = apple.notes.isEmpty ? nil : apple.notes }
    }

    /// The days and times of Ohana's event; a timed event without an end keeps its length.
    static func writeTimes(_ ohana: OhanaSyncFields, to event: EKEvent, isNew: Bool) {
        let calendar = Day.calendar
        let midnight = calendar.startOfDay(for: ohana.date.date)
        let oldStart: Date? = isNew ? nil : event.startDate
        let oldEnd: Date? = isNew ? nil : event.endDate
        guard let start = ohana.start, let begin = date(start, on: midnight) else {
            event.isAllDay = true
            event.startDate = midnight
            // Noon of the last day: read back as that day however the account stores the end.
            event.endDate = ohana.endDate.date
            return
        }
        let lastMidnight = calendar.startOfDay(for: ohana.endDate.date)
        var length: TimeInterval = 3600
        if !event.isAllDay, let oldStart, let oldEnd, oldEnd > oldStart { length = oldEnd.timeIntervalSince(oldStart) }
        event.isAllDay = false
        event.startDate = begin
        if let end = ohana.end.flatMap({ date($0, on: lastMidnight) }) {
            event.endDate = max(end, begin)
        } else if ohana.endDate > ohana.date {
            event.endDate = calendar.startOfDay(for: ohana.endDate.adding(days: 1).date)
        } else {
            event.endDate = begin.addingTimeInterval(length)
        }
    }

    static func time(_ date: Date) -> String {
        let parts = Day.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func date(_ time: String, on midnight: Date) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Day.calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: midnight)
    }
}

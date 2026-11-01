import Foundation

// How an event reads on each of its days. An event that spans days shows on each of them: its
// start on the first, "until 17:00" on the last, nothing (like all day) in between.

enum CalendarEventTime {
    /// The time shown on `day`: "10:30–11:00" (or "10:30") on a one-day event; for one that spans
    /// days its start on the first ("from 10:30"), its end on the last ("until 17:00"), nil in
    /// between; nil for an all-day event.
    static func text(date: Day, endDate: Day, start: String?, end: String?, on day: Day) -> String? {
        guard let start else { return nil }
        guard endDate > date else { return end.map { "\(start)–\($0)" } ?? start }
        if day == date { return String(localized: "from \(start)") }
        if day == endDate, let end { return String(localized: "until \(end)") }
        return nil
    }

    /// The start shown before a title on `day` ("10:30 Dentist"): the start on the first day,
    /// "until 17:00" on the last day of a timed event that spans days.
    static func lead(date: Day, endDate: Day, start: String?, end: String?, on day: Day) -> String? {
        guard start != nil else { return nil }
        guard endDate > date else { return start }
        if day == date { return start }
        if day == endDate, let end { return String(localized: "until \(end)") }
        return nil
    }
}

extension CalendarEvent {
    /// The time shown on `day` (`CalendarEventTime.text`).
    func timeText(on day: Day) -> String? {
        CalendarEventTime.text(date: date, endDate: endDate, start: start, end: end, on: day)
    }

    /// "10:30 Dr. Berg (Mia)" on `day`: the event in one line (`line` on its first day).
    func line(on day: Day) -> String {
        let name = person.isEmpty ? title : "\(title) (\(person))"
        return [CalendarEventTime.lead(date: date, endDate: endDate, start: start, end: end, on: day), name]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// Where it sorts among the events of `day`: all day (and the middle days of one that spans
    /// days) first, then by the time it starts that day.
    func sortKey(on day: Day) -> String {
        day == date ? (start ?? "") : ""
    }

    /// When it is, for its details: "10:30–11:00" or "All day" on one day; "Tue 3 Nov – Thu 5 Nov"
    /// or "Tue 3 Nov, 09:00 – Thu 5 Nov, 17:00" over several.
    var whenText: String {
        guard isMultiDay else { return timeText ?? String(localized: "All day") }
        let first = [date.formatted(), start].compactMap { $0 }.joined(separator: ", ")
        let last = [endDate.formatted(), start == nil ? nil : end].compactMap { $0 }.joined(separator: ", ")
        return "\(first) – \(last)"
    }

    /// How it repeats in words; nil when it doesn't.
    var repeatText: String? {
        rrule.map { RepeatRule($0)?.summary() ?? $0 }
    }
}

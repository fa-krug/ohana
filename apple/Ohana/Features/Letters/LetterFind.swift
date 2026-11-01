import Foundation

// What a scanned letter asks of the family: once its text is read, the review sheet sends only
// the text to the server (`POST /ai/letter`, the family's assistant model), which answers with
// the events, tasks and deadlines it found, in the shape of the assistant's suggestions
// (`AssistantSuggestionOp`). The review lists them, ticked; each can be edited
// (`LetterItemEditor`, over a `LetterItemDraft`), and Done adds the ticked ones like the
// assistant's suggestions card does (`AssistantSuggestionsApply`: events through the family API,
// tasks and deadlines into the user's Reminders).

/// The server's answer: `ai` false when the family hasn't set up the assistant (then no items).
struct LetterFindings: Decodable, Equatable {
    var ai: Bool
    /// Who the letter is from, when the model said.
    var source: String?
    var items: [AssistantSuggestionOp]

    init(ai: Bool, source: String? = nil, items: [AssistantSuggestionOp] = []) {
        self.ai = ai
        self.source = source
        self.items = items
    }

    private enum Keys: String, CodingKey { case ai, source, items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ai = try c.decodeIfPresent(Bool.self, forKey: .ai) ?? true
        source = (try? c.decodeIfPresent(String.self, forKey: .source))?.flatMap { $0.isEmpty ? nil : $0 }
        items = (try? c.decodeIfPresent([AssistantSuggestionOp].self, forKey: .items)) ?? []
    }
}

/// Looks for what to add in a letter's text (tests fake it).
protocol LetterItemFinding {
    func find(_ text: String, today: Day) async throws -> LetterFindings
}

/// POST /ai/letter on the family API (editors; the assistant's model).
struct FamilyLetterFinder: LetterItemFinding {
    let api: FamilyAPI

    struct Body: Encodable, Equatable {
        let text: String
        let today: String
        let lang: String
    }

    /// The most text the server takes (`MAX_LETTER_TEXT`).
    static let maxText = LetterScan.maxText

    static func body(_ text: String, today: Day, lang: String = MealPlanLanguage.current) -> Body {
        Body(text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxText)),
             today: today.description, lang: lang)
    }

    func find(_ text: String, today: Day) async throws -> LetterFindings {
        try await api.send(.post, "/ai/letter", body: Self.body(text, today: today))
    }
}

/// One thing found in the letter, as the review lists it.
struct LetterFoundItem: Identifiable, Equatable {
    let id = UUID()
    var op: AssistantSuggestionOp
    /// Added on Done.
    var picked = true
    /// It went through on an earlier Done: not added again.
    var added = false
    /// Why adding it didn't go through.
    var error: String?

    /// Ticked and not added yet: Done adds it.
    var pending: Bool { picked && !added }
}

/// The editor's fields for a found item. An event's day and start time and a reminder's due day
/// and time are the same fields, so changing the kind carries them over.
struct LetterItemDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case event, task, deadline
        var id: Self { self }
    }

    var kind: Kind
    var title: String
    /// An event's first day; a task's or deadline's due day (nil: none).
    var day: Day?
    /// An event's last day, when it lasts several.
    var endDay: Day?
    /// "HH:MM": an event's start, a reminder's due time; nil: all day.
    var time: String?
    /// "HH:MM": a timed event's end.
    var endTime: String?
    var location: String
    var person: String
    var note: String
    /// The Reminders list (nil: the device's default list).
    var list: String?
    var listTitle: String?
    let today: Day

    init(_ op: AssistantSuggestionOp, today: Day) {
        self.today = today
        title = op.title
        location = op.location ?? ""
        person = op.person ?? ""
        note = op.note ?? ""
        list = op.list
        listTitle = op.listTitle
        switch op.kind {
        case .task, .deadline:
            kind = op.kind == .task ? .task : .deadline
            let due = op.due.flatMap(ReminderDue.init)
            day = due?.day
            time = due?.time.map { String(format: "%02d:%02d", $0.hour, $0.minute) }
        case .event, .unknown:
            kind = .event
            let first = AssistantSuggestionOp.day(op.date) ?? today
            day = first
            endDay = AssistantSuggestionOp.day(op.endDate).flatMap { $0 > first ? $0 : nil }
            time = AssistantSuggestionOp.clock(op.start) != nil ? op.start : nil
            endTime = time != nil && AssistantSuggestionOp.clock(op.end) != nil ? op.end : nil
        }
    }

    /// A new kind keeps the day and time; an event needs a day (today when there was none).
    mutating func setKind(_ kind: Kind) {
        self.kind = kind
        if kind == .event, day == nil { day = today }
    }

    var isAllDay: Bool { time == nil }

    /// All day: no times. Timed: from 9:00 (an event: no end time yet).
    mutating func setAllDay(_ allDay: Bool) {
        time = allDay ? nil : "09:00"
        endTime = nil
    }

    /// A timed event's end time on or off (an hour after the start, on the first day).
    mutating func setHasEndTime(_ on: Bool) {
        endTime = on ? CalendarEventSheet.later(time ?? "09:00") : nil
        endDay = nil
    }

    /// An event's last day (the first or one before it: a single day).
    mutating func setEndDay(_ last: Day) {
        endDay = last > (day ?? today) ? last : nil
    }

    /// A reminder's due day on or off.
    mutating func setHasDue(_ on: Bool) {
        if on {
            day = day ?? today
        } else {
            day = nil
            time = nil
        }
    }

    /// A new first day: the last moves along, so it keeps its length.
    mutating func setDay(_ new: Day) {
        if let endDay, let day {
            let length = CalendarMath.ordinal(endDay) - CalendarMath.ordinal(day)
            self.endDay = CalendarMath.add(new, max(length, 1))
        }
        day = new
    }

    /// What keeps it from being saved; nil when it can be.
    var problem: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Give it a title.") }
        if kind == .deadline, day == nil { return String(localized: "A deadline needs a date.") }
        return timeProblem
    }

    /// A timed event ending before it starts on the same day.
    var timeProblem: String? {
        guard kind == .event, endDay == nil, let time, let endTime, endTime < time else { return nil }
        return String(localized: "The end must be after the start.")
    }

    /// The item as the review keeps it (and `AssistantSuggestionsApply` adds it).
    var op: AssistantSuggestionOp {
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .event:
            let first = day ?? today
            return AssistantSuggestionOp(
                op: "event", title: title, date: first.description,
                endDate: endDay.flatMap { $0 > first ? $0.description : nil },
                start: time, end: time == nil ? nil : endTime,
                location: text(location), person: text(person), note: text(note))
        case .task, .deadline:
            let due = day.map { day -> ReminderDue in
                guard let clock = AssistantSuggestionOp.clock(time) else { return ReminderDue(day: day) }
                return ReminderDue(day: day, time: clock)
            }
            return AssistantSuggestionOp(op: kind.rawValue, title: title, note: text(note), due: due?.description,
                                         list: list, listTitle: list == nil ? nil : listTitle)
        }
    }
}

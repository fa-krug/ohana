import Foundation

// The user's Reminders as plain values (no EventKit types), so the logic over them is pure and
// testable: what `RemindersStore` reads (`ReminderList`, `ReminderSnapshot`) and what it writes
// (`ReminderDraft`, `ReminderChange`). The shopping list's and the chores' syncs
// (`ShoppingReminderPlan`, `ChoreReminderPlan`) and the assistant's Reminders tools work on these.

/// Whether the app may use the user's Reminders (EventKit's authorization, for reminders).
enum RemindersAccess: Equatable {
    /// Not asked yet: `RemindersStore.requestAccess()` asks.
    case notDetermined
    /// Full access: read and write every list.
    case granted
    /// Only adding (iOS 17's write-only access); the sync needs to read, so it counts as no.
    case writeOnly
    /// The user said no (Settings changes it).
    case denied
    /// Not allowed on this device (parental controls, a profile).
    case restricted

    var isGranted: Bool { self == .granted }
}

/// A Reminders list (an `EKCalendar` for reminders).
struct ReminderList: Hashable, Identifiable {
    /// `calendarIdentifier`.
    var id: String
    var title: String
    /// The list's color as "#rrggbb", when it has one.
    var color: String?
    /// The account it lives in ("iCloud", "On My iPhone").
    var source: String
    /// Reminders can be added to it (not a read-only subscription).
    var isWritable: Bool
}

/// When a reminder is due: a day, or a day and a wall-clock time. As text "YYYY-MM-DD" or
/// "YYYY-MM-DDTHH:MM" (the assistant's Reminders tools).
struct ReminderDue: Hashable, Codable, CustomStringConvertible {
    var day: Day
    /// Hour and minute; nil for the whole day.
    var time: Time?

    struct Time: Hashable {
        var hour: Int
        var minute: Int
    }

    init(day: Day, time: Time? = nil) {
        self.day = day
        self.time = time
    }

    init(day: Day, hour: Int, minute: Int) {
        self.init(day: day, time: Time(hour: hour, minute: minute))
    }

    /// "2026-11-07" or "2026-11-07T18:30" (seconds are ignored); nil for anything else.
    init?(_ text: String) {
        let parts = text.split(separator: "T", maxSplits: 1).map(String.init)
        guard let first = parts.first, first.count == 10, let day = Day(first) else { return nil }
        guard parts.count == 2 else {
            self.init(day: day)
            return
        }
        let clock = parts[1].split(separator: ":").map { Int($0) }
        guard clock.count >= 2, let hour = clock[0], let minute = clock[1],
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(day: day, hour: hour, minute: minute)
    }

    /// A reminder's `dueDateComponents`; nil without a day in them.
    init?(components: DateComponents) {
        guard let year = components.year, let month = components.month, let dayOfMonth = components.day else {
            return nil
        }
        let day = Day(year: year, month: month, day: dayOfMonth)
        if let hour = components.hour {
            self.init(day: day, hour: hour, minute: components.minute ?? 0)
        } else {
            self.init(day: day)
        }
    }

    /// What a reminder is given: the day alone (all day), or with the time in the user's calendar.
    var components: DateComponents {
        var components = DateComponents(calendar: Day.calendar, year: day.year, month: day.month, day: day.day)
        if let time {
            components.hour = time.hour
            components.minute = time.minute
            components.timeZone = .current
        }
        return components
    }

    var description: String {
        guard let time else { return day.description }
        return day.description + String(format: "T%02d:%02d", time.hour, time.minute)
    }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let due = ReminderDue(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a due date: \(text)"))
        }
        self = due
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// One reminder as read (`EKReminder`).
struct ReminderSnapshot: Hashable, Identifiable {
    /// `calendarItemIdentifier`.
    var id: String
    /// The list's `calendarIdentifier`.
    var listID: String
    var title: String
    var notes: String?
    var due: ReminderDue?
    var isCompleted: Bool
    var completionDate: Date?
    var url: URL?

    init(id: String, listID: String, title: String, notes: String? = nil, due: ReminderDue? = nil,
         isCompleted: Bool = false, completionDate: Date? = nil, url: URL? = nil) {
        self.id = id
        self.listID = listID
        self.title = title
        self.notes = notes
        self.due = due
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.url = url
    }

    /// Nearest due first (by day, then time; all day before timed), those without a due date last,
    /// then by title.
    static func nearestDueFirst(_ a: ReminderSnapshot, _ b: ReminderSnapshot) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y:
            if x.day != y.day { return x.day < y.day }
            let tx = x.time.map { $0.hour * 60 + $0.minute } ?? -1
            let ty = y.time.map { $0.hour * 60 + $0.minute } ?? -1
            return tx < ty
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

/// A reminder to add.
struct ReminderDraft: Hashable {
    var title: String
    var notes: String?
    var due: ReminderDue?
    var url: URL?
    /// How it repeats (from its due day, which it needs then); nil: once.
    var rule: RepeatRule?

    init(title: String, notes: String? = nil, due: ReminderDue? = nil, url: URL? = nil, rule: RepeatRule? = nil) {
        self.title = title
        self.notes = notes
        self.due = due
        self.url = url
        self.rule = rule
    }
}

/// A change to a reminder: each field nil leaves it as it is; `.some(nil)` clears an optional one.
struct ReminderChange: Hashable {
    var title: String?
    var notes: String??
    var due: ReminderDue??
    /// Another list to move it to.
    var listID: String?
    var url: URL??
    /// How it repeats; `.some(nil)`: not anymore.
    var rule: RepeatRule??

    init(title: String? = nil, notes: String?? = nil, due: ReminderDue?? = nil, listID: String? = nil, url: URL?? = nil,
         rule: RepeatRule?? = nil) {
        self.title = title
        self.notes = notes
        self.due = due
        self.listID = listID
        self.url = url
        self.rule = rule
    }

    /// Nothing would change.
    var isEmpty: Bool { title == nil && notes == nil && due == nil && listID == nil && url == nil && rule == nil }

    /// `reminder` with the change applied (what `RemindersStore.update` does to the real one).
    func applied(to reminder: ReminderSnapshot) -> ReminderSnapshot {
        var result = reminder
        if let title { result.title = title }
        if let notes { result.notes = notes }
        if let due { result.due = due }
        if let listID { result.listID = listID }
        if let url { result.url = url }
        return result
    }
}

/// Why a change to Reminders didn't happen.
enum RemindersError: LocalizedError, Equatable {
    /// Ohana may not use Reminders (not asked, denied, restricted, write-only).
    case noAccess
    /// The list is gone (deleted, or its account removed from the device).
    case listNotFound
    /// The reminder is gone.
    case reminderNotFound
    /// The list can't take changes (a subscription).
    case readOnlyList
    /// There's no account to make a new list in.
    case noAccount

    var errorDescription: String? {
        switch self {
        case .noAccess: String(localized: "Ohana has no access to your reminders. You can allow it in the Settings.")
        case .listNotFound: String(localized: "The Reminders list is gone.")
        case .reminderNotFound: String(localized: "The reminder is gone.")
        case .readOnlyList: String(localized: "This Reminders list can’t be changed.")
        case .noAccount: String(localized: "There’s no account for Reminders lists on this device.")
        }
    }
}

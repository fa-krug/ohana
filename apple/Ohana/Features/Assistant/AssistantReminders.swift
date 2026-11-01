import Foundation

// The assistant's Reminders tools on the device (server: lib/assistant/tools/reminders.ts). The
// user's Reminders never live on the server: every message carries what the assistant may know
// of them (`AssistantRemindersContext`, only with full access and never in the demo), and the
// changes it suggests (`AssistantRemindersEdit`) are applied here, once the user says so
// (`AssistantRemindersApply`), then answered with each op's result.

/// What the app tells the assistant about the user's Reminders (`reminders` in a chat request):
/// the writable lists, their open reminders (nearest due first) and which one is the family's
/// shopping list. Capped like the server caps it (`cleanReminders`).
struct AssistantRemindersContext: Encodable, Equatable {
    static let maxLists = 100
    static let maxItems = 500
    static let maxTitle = 200
    static let maxNotes = 1000

    /// The list the family's shopping goes into on this device; nil: none chosen (or not writable).
    var shoppingListId: String?
    var lists: [List]
    var items: [Item]

    struct List: Encodable, Equatable {
        var id: String
        var title: String
    }

    struct Item: Encodable, Equatable {
        var id: String
        /// The list's id.
        var list: String
        var title: String
        var notes: String?
        var due: ReminderDue?
        var completed: Bool

        private enum Keys: String, CodingKey { case id, list, title, notes, due, completed }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(list, forKey: .list)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(notes, forKey: .notes)
            try c.encode(due, forKey: .due) // null without a due date
            try c.encode(completed, forKey: .completed)
        }
    }

    private enum Keys: String, CodingKey { case shoppingListId, lists, items }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(shoppingListId, forKey: .shoppingListId) // null when none is chosen
        try c.encode(lists, forKey: .lists)
        try c.encode(items, forKey: .items)
    }

    /// The snapshot of what `RemindersStore` read: writable lists only (at most 100), their open
    /// reminders nearest due first (at most 500), titles and notes cut short.
    static func build(lists all: [ReminderList], reminders: [ReminderSnapshot], shoppingListID: String?) -> Self {
        let lists = all.filter(\.isWritable).prefix(maxLists).map { List(id: $0.id, title: cut($0.title, maxTitle)) }
        let ids = Set(lists.map(\.id))
        let items = reminders
            .filter { !$0.isCompleted && ids.contains($0.listID) }
            .sorted(by: ReminderSnapshot.nearestDueFirst)
            .prefix(maxItems)
            .map { r in
                let notes = r.notes.map { cut($0, maxNotes) } ?? ""
                return Item(id: r.id, list: r.listID, title: cut(r.title, maxTitle), notes: notes.isEmpty ? nil : notes,
                            due: r.due, completed: false)
            }
        let shopping = shoppingListID.flatMap { ids.contains($0) ? $0 : nil }
        return Self(shoppingListId: shopping, lists: Array(lists), items: Array(items))
    }

    private static func cut(_ text: String, _ max: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    /// The user's Reminders now, for the family of `api`; nil in the demo and without full access
    /// (then the server offers no Reminders tools).
    static func current(for api: FamilyAPI, store: RemindersStore = .shared) async -> Self? {
        guard !api.client.isDemo else { return nil }
        store.refreshAccess()
        guard store.access.isGranted else { return nil }
        let lists = store.lists()
        guard let reminders = try? await store.openReminders() else { return nil }
        return build(lists: lists, reminders: reminders, shoppingListID: ShoppingReminders.shared.settings(for: api).listID)
    }
}

/// What applying an edit needs of `RemindersStore` (tests fake it).
protocol RemindersWriting {
    func list(_ id: String) -> ReminderList?
    func add(_ draft: ReminderDraft, to listID: String, commit: Bool) throws -> String
    func update(_ id: String, _ change: ReminderChange, commit: Bool) throws
    func setCompleted(_ id: String, _ completed: Bool, commit: Bool) throws
    func delete(_ id: String, commit: Bool) throws
    func commit() throws
    func reset()
}

extension RemindersStore: RemindersWriting {}

/// Applies the ops of a Reminders edit, in order, and says how each went.
enum AssistantRemindersApply {
    /// Every op is tried (one that fails doesn't stop the others) and the ones that went through
    /// are saved together at the end; if that fails, nothing is saved and every op failed.
    static func perform(_ ops: [AssistantReminderOp], on store: some RemindersWriting) -> [AssistantReminderResult] {
        var results = ops.map { op -> AssistantReminderResult in
            do {
                return .done(try apply(op, store))
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
            results = results.map { $0.ok ? .failed(message) : $0 }
        }
        return results
    }

    /// One op (not saved yet); the reminder's id.
    private static func apply(_ op: AssistantReminderOp, _ store: some RemindersWriting) throws -> String? {
        switch op.op {
        case "add":
            let title = op.title ?? ""
            guard !title.isEmpty else { throw ApplyError.unsupported }
            var due: ReminderDue?
            if case let .set(value) = op.due { due = value }
            let notes = op.notes.flatMap { $0.isEmpty ? nil : $0 }
            return try store.add(ReminderDraft(title: title, notes: notes, due: due), to: op.list, commit: false)
        case "update":
            let id = try reminderID(op)
            // Checked first: a change half made to a reminder that can't move would be saved later.
            if !op.list.isEmpty {
                guard let list = store.list(op.list) else { throw RemindersError.listNotFound }
                guard list.isWritable else { throw RemindersError.readOnlyList }
            }
            var change = ReminderChange(listID: op.list.isEmpty ? nil : op.list)
            if let title = op.title, !title.isEmpty { change.title = title }
            if let notes = op.notes { change.notes = .some(notes.isEmpty ? nil : notes) }
            switch op.due {
            case .keep: break
            case .clear: change.due = .some(nil)
            case let .set(value): change.due = .some(value)
            }
            try store.update(id, change, commit: false)
            return id
        case "complete", "uncomplete":
            let id = try reminderID(op)
            try store.setCompleted(id, op.op == "complete", commit: false)
            return id
        case "delete":
            let id = try reminderID(op)
            try store.delete(id, commit: false)
            return id
        default:
            throw ApplyError.unsupported
        }
    }

    private static func reminderID(_ op: AssistantReminderOp) throws -> String {
        guard let id = op.id, !id.isEmpty else { throw RemindersError.reminderNotFound }
        return id
    }

    enum ApplyError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            String(localized: "This version of Ohana can’t make this change.")
        }
    }
}

/// One op of a Reminders edit in plain words, e.g. "Add “Milk” to Groceries · due Sat 7 Nov",
/// with an icon and a fainter detail (the list, the notes, what an update changes).
struct AssistantReminderOpLine: Equatable {
    var icon: String
    var text: String
    var detail: String?
    /// It deletes a reminder.
    var destructive = false

    /// `currentListID`: the list the reminder is in now, when known (an update to another list
    /// moves it).
    static func make(_ op: AssistantReminderOp, currentListID: String? = nil, locale: Locale = .current) -> Self {
        let subject = op.subject
        switch op.op {
        case "add":
            var text = String(localized: "Add “\(subject)” to \(op.listTitle)")
            if case let .set(due) = op.due { text += " · " + String(localized: "due \(dueText(due, locale: locale))") }
            let notes = op.notes.flatMap { $0.isEmpty ? nil : $0 }
            return Self(icon: "plus.circle", text: text, detail: notes)
        case "update":
            let changes = op.title != nil || op.notes != nil || op.due != .keep
            let moves = !changes || (currentListID.map { !op.list.isEmpty && $0 != op.list } ?? false)
            if !changes {
                return Self(icon: "arrow.right.circle", text: String(localized: "Move “\(subject)” to \(op.listTitle)"))
            }
            var parts: [String] = []
            if let title = op.title { parts.append(String(localized: "rename to “\(title)”")) }
            switch op.due {
            case .keep: break
            case .clear: parts.append(String(localized: "no due date"))
            case let .set(due): parts.append(String(localized: "due \(dueText(due, locale: locale))"))
            }
            if let notes = op.notes {
                parts.append(notes.isEmpty ? String(localized: "remove the notes") : String(localized: "notes: \(notes)"))
            }
            if moves { parts.append(String(localized: "move to \(op.listTitle)")) }
            return Self(icon: "pencil.circle", text: String(localized: "Change “\(subject)”"),
                        detail: parts.joined(separator: ", "))
        case "complete":
            return Self(icon: "checkmark.circle", text: String(localized: "Complete “\(subject)”"), detail: op.listTitle)
        case "uncomplete":
            return Self(icon: "circle", text: String(localized: "Reopen “\(subject)”"), detail: op.listTitle)
        case "delete":
            return Self(icon: "trash", text: String(localized: "Delete “\(subject)”"), detail: op.listTitle,
                        destructive: true)
        default:
            return Self(icon: "questionmark.circle", text: subject.isEmpty ? op.op : "\(op.op) “\(subject)”",
                        detail: op.listTitle.isEmpty ? nil : op.listTitle)
        }
    }

    /// "Sat 7 Nov" or "Sat 7 Nov, 18:30" (in the user's language).
    static func dueText(_ due: ReminderDue, locale: Locale = .current) -> String {
        var calendar = Day.calendar
        calendar.locale = locale
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        let components = DateComponents(year: due.day.year, month: due.day.month, day: due.day.day,
                                        hour: due.time?.hour ?? 12, minute: due.time?.minute ?? 0)
        guard let date = calendar.date(from: components) else { return due.description }
        if due.time != nil { style = style.hour().minute() }
        return date.formatted(style)
    }
}

extension AssistantRemindersEdit {
    /// How it ended, in a few words; nil while it waits.
    var outcome: String? {
        if let answer {
            guard answer.applied else { return String(localized: "Not applied") }
            let failed = answer.failures
            return failed == 0
                ? String(localized: "Applied")
                : String(localized: "Applied, \(failed) of \(ops.count) failed")
        }
        return skipped ? String(localized: "Not answered") : nil
    }
}

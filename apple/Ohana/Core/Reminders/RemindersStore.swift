import EventKit
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The user's Reminders through EventKit: one `EKEventStore` for the app, the access to
/// reminders (asked for once, `requestAccess`), the lists, and reading and changing reminders by
/// their `calendarItemIdentifier`. Everything comes and goes as plain values
/// (`ReminderModels.swift`). Views reload on `revision`, which grows whenever the reminders
/// database changes (here, in the Reminders app, through iCloud).
///
/// Used by the shopping list's and the chores' syncs (`ShoppingReminders`, `ChoreReminders`), the
/// Siri action that adds to the shopping list and the assistant's Reminders tools.
@Observable
final class RemindersStore {
    static let shared = RemindersStore()
    static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "reminders")

    @ObservationIgnored let eventStore = EKEventStore()

    /// Whether the app may use Reminders; `refreshAccess()` reads it again.
    private(set) var access: RemindersAccess
    /// Grows with every change of the reminders database (`EKEventStoreChanged`).
    private(set) var revision = 0

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        access = Self.currentAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
    }

    private func storeChanged() {
        refreshAccess()
        revision += 1
    }

    // MARK: Access

    private static func currentAccess() -> RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Reads the access again (e.g. when the app becomes active: it may have changed in Settings).
    func refreshAccess() {
        let now = Self.currentAccess()
        if now != access { access = now }
    }

    /// Asks the user for full access to their reminders (the system's prompt, once; later calls
    /// answer at once). True when granted.
    @discardableResult
    func requestAccess() async throws -> Bool {
        let granted = try await eventStore.requestFullAccessToReminders()
        refreshAccess()
        if granted {
            // Lists and reminders read before the access may be stale.
            eventStore.reset()
            revision += 1
        }
        return granted
    }

    private func requireAccess() throws {
        refreshAccess()
        guard access.isGranted else { throw RemindersError.noAccess }
    }

    // MARK: Lists

    /// Every Reminders list, by account then title; empty without access.
    func lists() -> [ReminderList] {
        guard access.isGranted else { return [] }
        return eventStore.calendars(for: .reminder).map(Self.list)
            .sorted { ($0.source, $0.title.lowercased()) < ($1.source, $1.title.lowercased()) }
    }

    func list(_ id: String) -> ReminderList? {
        calendar(id).map(Self.list)
    }

    /// The list new reminders go to by default (the Reminders app's setting).
    var defaultListID: String? {
        guard access.isGranted else { return nil }
        return eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    /// Makes a new list called `title` in the account of the default list (else iCloud, else on
    /// the device).
    func createList(title: String) throws -> ReminderList {
        try requireAccess()
        let source = eventStore.defaultCalendarForNewReminders()?.source
            ?? eventStore.sources.first { $0.sourceType == .calDAV && !$0.calendars(for: .reminder).isEmpty }
            ?? eventStore.sources.first { $0.sourceType == .local }
        guard let source else { throw RemindersError.noAccount }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = title
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return Self.list(calendar)
    }

    private func calendar(_ id: String) -> EKCalendar? {
        guard access.isGranted, let calendar = eventStore.calendar(withIdentifier: id),
              calendar.allowedEntityTypes.contains(.reminder) else { return nil }
        return calendar
    }

    private static func list(_ calendar: EKCalendar) -> ReminderList {
        ReminderList(id: calendar.calendarIdentifier, title: calendar.title, color: hex(calendar.cgColor),
                     source: calendar.source?.title ?? "", isWritable: calendar.allowsContentModifications)
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color, let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        let value = { (x: CGFloat) in Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", value(c[0]), value(c[1]), value(c[2]))
    }

    // MARK: Reading

    /// The open reminders of `listIDs` (nil: every list), nearest due first.
    func openReminders(in listIDs: [String]? = nil) async throws -> [ReminderSnapshot] {
        try requireAccess()
        guard let calendars = calendars(listIDs) else { return [] }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await fetch(predicate).sorted(by: ReminderSnapshot.nearestDueFirst)
    }

    /// The open reminders of a list and those completed since `since`.
    func reminders(in listID: String, completedSince since: Date) async throws -> [ReminderSnapshot] {
        try requireAccess()
        guard let calendar = calendar(listID) else { throw RemindersError.listNotFound }
        let open = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        let done = eventStore.predicateForCompletedReminders(withCompletionDateStarting: since, ending: nil,
                                                             calendars: [calendar])
        return await fetch(open) + fetch(done)
    }

    /// One reminder; nil when it's gone.
    func reminder(_ id: String) -> ReminderSnapshot? {
        reminderObject(id).map(Self.snapshot)
    }

    /// The calendars of `ids` that still exist (nil: every list); nil when none of them does.
    private func calendars(_ ids: [String]?) -> [EKCalendar]? {
        guard let ids else { return eventStore.calendars(for: .reminder) }
        let calendars = ids.compactMap { calendar($0) }
        return calendars.isEmpty ? nil : calendars
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderSnapshot] {
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<UncheckedReminders, Never>) in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: UncheckedReminders(reminders: reminders ?? []))
            }
        }
        return found.reminders.map(Self.snapshot)
    }

    private static func snapshot(_ reminder: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            notes: reminder.notes,
            due: reminder.dueDateComponents.flatMap { ReminderDue(components: $0) },
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            url: reminder.url
        )
    }

    private func reminderObject(_ id: String) -> EKReminder? {
        guard access.isGranted else { return nil }
        return eventStore.calendarItem(withIdentifier: id) as? EKReminder
    }

    // MARK: Changing

    // Each change is saved at once unless `commit` is false: then `commit()` saves them together
    // (`reset()` drops them).

    /// Adds a reminder to the list `listID`; its `calendarItemIdentifier`.
    @discardableResult
    func add(_ draft: ReminderDraft, to listID: String, commit: Bool = true) throws -> String {
        try requireAccess()
        guard let calendar = calendar(listID) else { throw RemindersError.listNotFound }
        guard calendar.allowsContentModifications else { throw RemindersError.readOnlyList }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.dueDateComponents = draft.due?.components
        reminder.url = draft.url
        reminder.recurrenceRules = draft.rule.map { [$0.ekRule] }
        try eventStore.save(reminder, commit: commit)
        return reminder.calendarItemIdentifier
    }

    /// Changes a reminder's title, notes, due date, list, url or how it repeats (`ReminderChange`).
    func update(_ id: String, _ change: ReminderChange, commit: Bool = true) throws {
        let reminder = try writable(id)
        if let title = change.title { reminder.title = title }
        if let notes = change.notes { reminder.notes = notes }
        if let due = change.due { reminder.dueDateComponents = due?.components }
        if let url = change.url { reminder.url = url }
        if let rule = change.rule { reminder.recurrenceRules = rule.map { [$0.ekRule] } }
        if let listID = change.listID, listID != reminder.calendar?.calendarIdentifier {
            guard let calendar = calendar(listID) else { throw RemindersError.listNotFound }
            guard calendar.allowsContentModifications else { throw RemindersError.readOnlyList }
            reminder.calendar = calendar
        }
        try eventStore.save(reminder, commit: commit)
    }

    /// Ticks a reminder off, or back on.
    func setCompleted(_ id: String, _ completed: Bool, commit: Bool = true) throws {
        let reminder = try writable(id)
        guard reminder.isCompleted != completed else { return }
        reminder.isCompleted = completed
        try eventStore.save(reminder, commit: commit)
    }

    func delete(_ id: String, commit: Bool = true) throws {
        let reminder = try writable(id)
        try eventStore.remove(reminder, commit: commit)
    }

    /// Saves the changes made with `commit: false`.
    func commit() throws {
        try eventStore.commit()
    }

    /// Drops the changes not committed yet.
    func reset() {
        eventStore.reset()
    }

    private func writable(_ id: String) throws -> EKReminder {
        try requireAccess()
        guard let reminder = reminderObject(id) else { throw RemindersError.reminderNotFound }
        guard reminder.calendar?.allowsContentModifications != false else { throw RemindersError.readOnlyList }
        return reminder
    }

    // MARK: Elsewhere

    /// Where the user allows the access again: the app's page in Settings (iOS), Privacy &
    /// Security → Reminders (Mac).
    static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
        #endif
    }

    /// Opens the Reminders app.
    static func openRemindersApp() {
        #if os(iOS)
        if let url = URL(string: "x-apple-reminderkit://") { UIApplication.shared.open(url) }
        #else
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        #endif
    }
}

/// EventKit hands its reminders over on a queue of its own; they're only read on the main actor.
private nonisolated struct UncheckedReminders: @unchecked Sendable {
    let reminders: [EKReminder]
}

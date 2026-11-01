import Foundation
import Observation

/// The family's chores in Reminders on this device: the list chosen for them, whose chores go
/// there, the reminders the sync linked, and how the last sync went. Kept per server and family
/// in `UserDefaults`; nil list: off.
struct ChoreRemindersSettings: Codable, Equatable {
    /// The Reminders list (`calendarIdentifier`); nil: off.
    var listID: String?
    /// Whose chores: a `ChorePerson.id`; nil: everyone's.
    var scope: String?
    /// The reminders written, by `ChoreReminderLink.key`: a single chore's, a repeating chore's
    /// occurrences' (`ChoreReminderPlan`).
    var links: [String: ChoreReminderLink] = [:]
    /// The last sync that went through.
    var lastSync: Date?
    var lastResult: ChoreSyncResult?
    /// Why the last sync failed; nil when it went through.
    var lastError: String?
}

/// What a sync changed.
struct ChoreSyncResult: Codable, Equatable {
    var added = 0
    var updated = 0
    var removed = 0
    /// Reminders ticked off or opened again for the server's chores.
    var completed = 0
    /// Chores reported done (or not) to the server, ticked in Reminders.
    var reported = 0

    var changedNothing: Bool { added == 0 && updated == 0 && removed == 0 && completed == 0 && reported == 0 }
}

/// Writes the family's chores (GET /chores) into the Reminders list the user chose for them on
/// this device: a single chore as one reminder, a repeating one as a reminder per occurrence made
/// 3 hours before it's due (`ChoreReminderPlan` has the rules), and brings back what was ticked off
/// there of the single ones (POST /chores/{id}/done). Off in the demo and with Chores turned off.
/// Viewers sync too; ticking off a chore that isn't theirs isn't taken by the server, and the
/// reminder opens again. It runs when it is turned on, when the app becomes active or shows another
/// family, a few seconds after the chores or the reminders change, from "Sync now"
/// (`ChoreRemindersUpdates`, the settings page) and, while the app runs, when the next occurrence of
/// a repeating chore is to appear (`wakeUps`).
@Observable
final class ChoreReminders {
    static let shared = ChoreReminders()

    /// Why a sync runs.
    enum Reason {
        /// The app became active or shows the family: skipped when the last one was a moment ago.
        case automatic
        /// The chores or the reminders changed, or the list or whose chores.
        case changed
        /// "Sync now".
        case manual
    }

    /// An automatic sync is skipped within this time of the last one.
    static var automaticInterval: TimeInterval = 30

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: RemindersStore
    /// The settings read so far, by `key` (so views observe them).
    private var cache: [String: ChoreRemindersSettings] = [:]
    /// Keys whose sync is running.
    private(set) var syncing: Set<String> = []
    /// Keys asked to sync again while one was running.
    @ObservationIgnored private var again: Set<String> = []
    /// The sync waiting for the next occurrence of a repeating chore to appear, by key.
    @ObservationIgnored private var wakeUps: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard, store: RemindersStore = .shared) {
        self.defaults = defaults
        self.store = store
    }

    // MARK: Settings

    private static let prefix = "choreReminders|"

    /// The settings' key: the server and the family.
    static func key(server: URL, familyID: String) -> String {
        var text = server.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return "\(prefix)\(text)|\(familyID)"
    }

    static func key(_ api: FamilyAPI) -> String {
        key(server: api.client.baseURL, familyID: api.familyID)
    }

    func settings(for api: FamilyAPI) -> ChoreRemindersSettings {
        settings(Self.key(api))
    }

    private func settings(_ key: String) -> ChoreRemindersSettings {
        if let cached = cache[key] { return cached }
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ChoreRemindersSettings.self, from: $0) }
            ?? ChoreRemindersSettings()
        cache[key] = stored
        return stored
    }

    private func save(_ settings: ChoreRemindersSettings, _ key: String) {
        cache[key] = settings
        if settings == ChoreRemindersSettings() {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }

    /// Chooses the Reminders list for the family's chores (nil: off). Another list starts from
    /// nothing linked; the reminders already written stay where they are. Whose chores stays.
    func setList(_ listID: String?, for api: FamilyAPI) {
        let key = Self.key(api)
        let current = settings(key)
        guard current.listID != listID else { return }
        cancelWakeUp(key)
        save(ChoreRemindersSettings(listID: listID, scope: current.scope), key)
    }

    /// Whose chores go to the list (nil: everyone's). The next sync removes the reminders of
    /// those no longer in it and retitles the rest.
    func setScope(_ scope: String?, for api: FamilyAPI) {
        let key = Self.key(api)
        var settings = settings(key)
        guard settings.scope != scope else { return }
        settings.scope = scope
        save(settings, key)
    }

    func isSyncing(_ api: FamilyAPI) -> Bool { syncing.contains(Self.key(api)) }

    /// Signing out of `server`: its families' settings go.
    static func forget(server: URL, defaults: UserDefaults = .standard) {
        let prefix = key(server: server, familyID: "")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        shared.cache = shared.cache.filter { !$0.key.hasPrefix(prefix) }
        for key in shared.wakeUps.keys where key.hasPrefix(prefix) { shared.cancelWakeUp(key) }
    }

    // MARK: Waking up

    /// Syncs the family again at `date` (replacing the one waiting; nil: none), while the app runs.
    private func scheduleWakeUp(_ key: String, at date: Date?, family: FamilyContext) {
        cancelWakeUp(key)
        guard let date else { return }
        wakeUps[key] = Task { [weak self] in
            // A moment after, so the occurrence has appeared by then.
            let wait = max(date.timeIntervalSinceNow, 0) + 1
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.wakeUps[key] = nil
            await self.sync(family, reason: .changed)
        }
    }

    private func cancelWakeUp(_ key: String) {
        wakeUps.removeValue(forKey: key)?.cancel()
    }

    // MARK: Syncing

    /// Syncs the family's chores with its Reminders list, if it has one; the outcome lands in the
    /// settings (`lastSync`, `lastResult`, `lastError`). One at a time per family: asked again
    /// meanwhile, it runs once more afterwards.
    func sync(_ family: FamilyContext, reason: Reason = .changed, now: Date = Date()) async {
        let api = family.api
        guard !api.client.isDemo, family.isEnabled(.chores) else {
            cancelWakeUp(Self.key(api))
            return
        }
        let key = Self.key(api)
        let start = settings(key)
        guard let listID = start.listID else {
            cancelWakeUp(key)
            return
        }
        if reason == .automatic, start.lastError == nil, let last = start.lastSync,
           now.timeIntervalSince(last) < Self.automaticInterval { return }
        guard !syncing.contains(key) else {
            again.insert(key)
            return
        }
        syncing.insert(key)
        var result: Result<(ChoreSyncResult, [String: ChoreReminderLink], Date?), any Error>
        do {
            result = .success(try await run(family, listID: listID, scope: start.scope, now: now))
        } catch is CancellationError {
            syncing.remove(key)
            again.remove(key)
            return
        } catch {
            RemindersStore.log.error("Chores sync failed: \(error.localizedDescription, privacy: .public)")
            result = .failure(error)
        }
        syncing.remove(key)
        // Turned off, moved to another list or to other chores meanwhile: this run doesn't count.
        var settings = settings(key)
        if settings.listID == listID, settings.scope == start.scope {
            switch result {
            case let .success((changes, links, next)):
                settings.links = links
                scheduleWakeUp(key, at: next, family: family)
                settings.lastSync = now
                settings.lastResult = changes
                settings.lastError = nil
            case let .failure(error):
                settings.lastError = error.localizedDescription
            }
            save(settings, key)
        }
        if case let .success((changes, _, _)) = result, changes.reported > 0 {
            // The chores screens show what was ticked off in Reminders.
            family.didChange(.chores)
        }
        if again.remove(key) != nil { await sync(family, reason: .changed) }
    }

    /// One sync: the server's chores, the list's reminders, the plan, applied. What changed, the
    /// links, and when the next occurrence appears.
    private func run(_ family: FamilyContext, listID: String, scope: String?,
                     now: Date) async throws -> (ChoreSyncResult, [String: ChoreReminderLink], Date?) {
        let api = family.api
        store.refreshAccess()
        guard store.access.isGranted else { throw RemindersError.noAccess }
        guard store.list(listID) != nil else { throw RemindersError.listNotFound }
        let today = Day(now)
        let page: ChoresPage = try await api.get("/chores", query: ["today": today.description])
        let since = Day.calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let reminders = try await store.reminders(in: listID, completedSince: since)
        let plan = ChoreReminderPlan.make(familyID: api.familyID, chores: page.chores, reminders: reminders,
                                          links: settings(for: api).links, scope: scope, today: today, now: now)
        // The server first: a failure there leaves Reminders as they were, to try again.
        var reported = 0
        for mark in plan.markDone {
            do {
                let _: ChoreResponse = try await api.send(.post, "/chores/\(mark.choreID)/done",
                                                          query: ["today": today.description], body: ["done": mark.done])
                reported += 1
            } catch let error as APIError where [400, 403, 404].contains(error.status ?? 0) {
                // Not this account's to tick off, gone, or repeating now: the next sync puts the
                // reminder back as the server has it.
                RemindersStore.log.info("Chore \(mark.choreID, privacy: .public) not marked: \(error.localizedDescription, privacy: .public)")
            }
        }
        var links = plan.links
        try apply(plan, to: listID, links: &links)
        let changes = ChoreSyncResult(added: plan.creates.count, updated: plan.updates.count, removed: plan.removals.count,
                                      completed: plan.completions.count, reported: reported)
        return (changes, links, plan.nextAppearance)
    }

    /// Makes the plan's changes to Reminders, saved together (none of them when one fails); the
    /// new reminders' links go into `links`.
    private func apply(_ plan: ChoreReminderPlan, to listID: String, links: inout [String: ChoreReminderLink]) throws {
        guard !(plan.creates.isEmpty && plan.updates.isEmpty && plan.completions.isEmpty && plan.removals.isEmpty) else {
            return
        }
        do {
            var added: [String: ChoreReminderLink] = [:]
            for create in plan.creates {
                let c = create.content
                let id = try store.add(ReminderDraft(title: c.title, notes: c.notes, due: c.due, url: c.url),
                                       to: listID, commit: false)
                added[create.key] = ChoreReminderLink(reminderID: id, done: false, fingerprint: create.fingerprint,
                                                      occurrence: create.occurrence)
            }
            for update in plan.updates {
                let c = update.content
                try store.update(update.id, ReminderChange(title: c.title, notes: .some(c.notes), due: .some(c.due),
                                                           url: .some(c.url)), commit: false)
            }
            for completion in plan.completions {
                try store.setCompleted(completion.id, completion.done, commit: false)
            }
            for id in plan.removals {
                do {
                    try store.delete(id, commit: false)
                } catch RemindersError.reminderNotFound {
                    // Gone already.
                }
            }
            try store.commit()
            links.merge(added) { _, new in new }
        } catch {
            store.reset()
            throw error
        }
    }
}

import Foundation
import Observation

/// The family's shopping list in Reminders on this device: the list chosen for it, what the sync
/// wrote, and how the last sync went. Kept per server and family in `UserDefaults`; nil list: off.
struct ShoppingRemindersSettings: Codable, Equatable {
    /// The Reminders list (`calendarIdentifier`); nil: off.
    var listID: String?
    /// The items written to it ("{date}/{key}", `ShoppingReminderPlan.written`).
    var written: Set<String> = []
    /// The last sync that went through.
    var lastSync: Date?
    var lastResult: ShoppingSyncResult?
    /// Why the last sync failed; nil when it went through.
    var lastError: String?
}

/// What a sync changed in Reminders.
struct ShoppingSyncResult: Codable, Equatable {
    var added = 0
    var updated = 0
    var removed = 0

    var changedNothing: Bool { added == 0 && updated == 0 && removed == 0 }
}

/// Writes what the meal plan needs (GET /meals/shopping) into the Reminders list the user chose
/// for the family, one way (`ShoppingReminderPlan` has the rules), and keeps the settings. Off in
/// the demo and with Meals turned off. Viewers sync too: it only reads the server. It runs when it
/// is turned on, when the app becomes active or shows another family, a few seconds after the
/// meal plan or the recipes change, and from "Sync now" (`ShoppingRemindersUpdates`, the settings
/// page).
@Observable
final class ShoppingReminders {
    static let shared = ShoppingReminders()

    /// Why a sync runs.
    enum Reason {
        /// The app became active or shows the family: skipped when the last one was a moment ago.
        case automatic
        /// The meal plan or the recipes changed, or the list was chosen.
        case changed
        /// "Sync now".
        case manual
    }

    /// An automatic sync is skipped within this time of the last one.
    static var automaticInterval: TimeInterval = 60

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: RemindersStore
    /// The settings read so far, by `key` (so views observe them).
    private var cache: [String: ShoppingRemindersSettings] = [:]
    /// Keys whose sync is running.
    private(set) var syncing: Set<String> = []
    /// Keys asked to sync again while one was running.
    @ObservationIgnored private var again: Set<String> = []

    init(defaults: UserDefaults = .standard, store: RemindersStore = .shared) {
        self.defaults = defaults
        self.store = store
    }

    // MARK: Settings

    private static let prefix = "shoppingReminders|"

    /// The settings' key: the server and the family.
    static func key(server: URL, familyID: String) -> String {
        var text = server.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return "\(prefix)\(text)|\(familyID)"
    }

    static func key(_ api: FamilyAPI) -> String {
        key(server: api.client.baseURL, familyID: api.familyID)
    }

    func settings(server: URL, familyID: String) -> ShoppingRemindersSettings {
        settings(Self.key(server: server, familyID: familyID))
    }

    func settings(for api: FamilyAPI) -> ShoppingRemindersSettings {
        settings(Self.key(api))
    }

    private func settings(_ key: String) -> ShoppingRemindersSettings {
        if let cached = cache[key] { return cached }
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ShoppingRemindersSettings.self, from: $0) }
            ?? ShoppingRemindersSettings()
        cache[key] = stored
        return stored
    }

    private func save(_ settings: ShoppingRemindersSettings, _ key: String) {
        cache[key] = settings
        if settings == ShoppingRemindersSettings() {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }

    /// Chooses the Reminders list for the family's shopping (nil: off). Another list starts from
    /// nothing written; the reminders already written stay where they are.
    func setList(_ listID: String?, for api: FamilyAPI) {
        let key = Self.key(api)
        var settings = settings(key)
        guard settings.listID != listID else { return }
        settings = ShoppingRemindersSettings(listID: listID)
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
    }

    // MARK: Syncing

    /// Syncs the family's shopping into its Reminders list, if it has one; the outcome lands in
    /// the settings (`lastSync`, `lastResult`, `lastError`). One at a time per family: asked again
    /// meanwhile, it runs once more afterwards.
    func sync(_ family: FamilyContext, reason: Reason = .changed, now: Date = Date()) async {
        let api = family.api
        guard !api.client.isDemo, family.isEnabled(.meals) else { return }
        let key = Self.key(api)
        let start = settings(key)
        guard let listID = start.listID else { return }
        if reason == .automatic, start.lastError == nil, let last = start.lastSync,
           now.timeIntervalSince(last) < Self.automaticInterval { return }
        guard !syncing.contains(key) else {
            again.insert(key)
            return
        }
        syncing.insert(key)
        var result: Result<(ShoppingSyncResult, Set<String>), any Error>
        do {
            result = .success(try await run(api, listID: listID, now: now))
        } catch is CancellationError {
            syncing.remove(key)
            again.remove(key)
            return
        } catch {
            RemindersStore.log.error("Shopping sync failed: \(error.localizedDescription, privacy: .public)")
            result = .failure(error)
        }
        syncing.remove(key)
        // Turned off or moved to another list meanwhile: what this run found doesn't count.
        var settings = settings(key)
        if settings.listID == listID {
            switch result {
            case let .success((changes, written)):
                settings.written = written
                settings.lastSync = now
                settings.lastResult = changes
                settings.lastError = nil
            case let .failure(error):
                settings.lastError = error.localizedDescription
            }
            save(settings, key)
        }
        if again.remove(key) != nil { await sync(family, reason: .changed) }
    }

    /// One sync: the server's items, the list's reminders, the plan, applied.
    private func run(_ api: FamilyAPI, listID: String, now: Date) async throws -> (ShoppingSyncResult, Set<String>) {
        store.refreshAccess()
        guard store.access.isGranted else { throw RemindersError.noAccess }
        guard store.list(listID) != nil else { throw RemindersError.listNotFound }
        let today = Day(now)
        let needs: ShoppingNeeds = try await api.get("/meals/shopping", query: [
            "from": today.description, "lang": MealPlanLanguage.current,
        ])
        let since = Day.calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let reminders = try await store.reminders(in: listID, completedSince: since)
        let plan = ShoppingReminderPlan.make(familyID: api.familyID, days: needs.days, reminders: reminders,
                                             written: settings(for: api).written, today: today)
        try apply(plan, to: listID)
        return (ShoppingSyncResult(added: plan.creates.count, updated: plan.updates.count, removed: plan.removals.count),
                plan.written)
    }

    /// Makes the plan's changes, saved together (none of them when one fails).
    private func apply(_ plan: ShoppingReminderPlan, to listID: String) throws {
        guard !plan.changesNothing else { return }
        do {
            for create in plan.creates {
                try store.add(ReminderDraft(title: create.title, due: ReminderDue(day: create.due), url: create.url),
                              to: listID, commit: false)
            }
            for update in plan.updates {
                try store.update(update.id, ReminderChange(title: update.title, url: .some(update.url)), commit: false)
            }
            for id in plan.removals {
                do {
                    try store.delete(id, commit: false)
                } catch RemindersError.reminderNotFound {
                    // Gone already.
                }
            }
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
    }
}

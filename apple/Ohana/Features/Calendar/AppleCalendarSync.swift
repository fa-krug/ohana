import EventKit
import Foundation
import Observation

/// What this device syncs for one family (`AppleCalendarSync`): kept in Application Support,
/// `Ohana/CalendarSync/<server>_<family>.json`.
struct AppleCalendarSyncState: Codable, Equatable {
    var calendarID: String
    var calendarTitle: String
    /// The day entries go to Apple too, as all-day events.
    var entries: Bool
    var links: [AppleSyncLink] = []
    /// The Apple events of the entry runs.
    var entryIDs: [String] = []
    var lastSync: Date?
}

/// POST /events of an imported Apple event: the event and the Apple event's `key`.
private struct AppleImportBody: Encodable {
    let input: CalendarEventInput
    let externalId: String

    enum CodingKeys: String, CodingKey { case externalId }

    func encode(to encoder: any Encoder) throws {
        try input.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(externalId, forKey: .externalId)
    }
}

/// Syncs a family's calendar with an Apple Calendar calendar on this device, through EventKit
/// (`AppleSyncPlanner` decides what). Per device and family: the calendar is picked in the calendar
/// settings. It runs while the app is open: at launch and when it comes to the front, every
/// 15 minutes, when the Apple calendars change and when the family's events or entries change in
/// the app. One for the app.
@Observable
final class AppleCalendarSync {
    static let shared = AppleCalendarSync()

    /// The days a sync looks at: from a month back to a year ahead.
    static func window(today: Day = .today) -> ClosedRange<Day> {
        today.adding(days: -31)...today.adding(days: 365)
    }

    /// Around the window, where occurrences moved out of it are still found (a changed occurrence
    /// keeps its original day, but shows on its new one).
    static func reach(_ window: ClosedRange<Day>) -> ClosedRange<Day> {
        window.lowerBound.adding(days: -60)...window.upperBound.adding(days: 60)
    }

    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    /// Per family key (`key(_:)`).
    private(set) var states: [String: AppleCalendarSyncState] = [:]
    private(set) var running: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Ohana events not deleted although their Apple events were missing.
    private(set) var heldBack: [String: Int] = [:]

    @ObservationIgnored private var store = EKEventStore()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var loaded = Set<String>()
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var allPending: Task<Void, Never>?
    @ObservationIgnored private var lastFinished = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    var hasAccess: Bool { access == .fullAccess }

    /// Watches the Apple calendars and syncs every 15 minutes.
    func start(_ app: AppModel) {
        self.app = app
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Its own changes come back as this too: not right after a sync.
                guard let self, self.running.isEmpty, Date().timeIntervalSince(self.lastFinished) > 3 else { return }
                self.syncAllSoon()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAllSoon() }
        }
    }

    // MARK: Access and calendars

    /// Asks for access to the calendars (once; afterwards only the Settings app changes it).
    func requestAccess() async -> Bool {
        _ = try? await store.requestFullAccessToEvents()
        access = EKEventStore.authorizationStatus(for: .event)
        // A store made before access was given doesn't see the calendars.
        if hasAccess { store = EKEventStore() }
        return hasAccess
    }

    /// The calendars Ohana can write to, by account.
    func calendars() -> [(source: String, calendars: [EKCalendar])] {
        guard hasAccess else { return [] }
        let writable = store.calendars(for: .event).filter {
            $0.allowsContentModifications && $0.type != .birthday && $0.type != .subscription
        }
        let groups = Dictionary(grouping: writable) { $0.source?.title ?? "" }
        return groups.keys.sorted().map { key in
            (key, groups[key]!.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
    }

    func calendar(_ id: String) -> EKCalendar? {
        hasAccess ? store.calendar(withIdentifier: id) : nil
    }

    /// A new calendar named `title` in the account new events go to (iCloud, usually).
    func makeCalendar(title: String) throws -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        guard let source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV || $0.sourceType == .local }) else {
            throw AppleCalendarSyncError.noAccount
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    // MARK: Settings per family

    func state(for api: FamilyAPI) -> AppleCalendarSyncState? {
        guard let key = Self.key(api) else { return nil }
        if !loaded.contains(key) {
            loaded.insert(key)
            if let file = Self.file(key), let data = try? Data(contentsOf: file) {
                states[key] = try? JSONDecoder().decode(AppleCalendarSyncState.self, from: data)
            }
        }
        return states[key]
    }

    private func save(_ state: AppleCalendarSyncState?, key: String) {
        states[key] = state
        loaded.insert(key)
        guard let file = Self.file(key) else { return }
        if let state, let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Starts syncing the family with `calendar`.
    func enable(_ context: FamilyContext, calendar: EKCalendar, entries: Bool) async {
        guard let key = Self.key(context.api) else { return }
        save(AppleCalendarSyncState(calendarID: calendar.calendarIdentifier, calendarTitle: calendar.title, entries: entries), key: key)
        errors[key] = nil
        await sync(context)
    }

    func setEntries(_ on: Bool, for context: FamilyContext) async {
        guard let key = Self.key(context.api), var state = state(for: context.api), state.entries != on else { return }
        state.entries = on
        save(state, key: key)
        await sync(context)
    }

    /// Stops syncing the family. `removeCopies` deletes what Ohana wrote into the Apple calendar (its
    /// events' copies and the entry runs); events that came from Apple stay in both.
    func disable(_ context: FamilyContext, removeCopies: Bool) {
        guard let key = Self.key(context.api), let state = state(for: context.api) else { return }
        if removeCopies, hasAccess, let calendar = store.calendar(withIdentifier: state.calendarID) {
            let family = context.family.id
            var ids = Set(state.entryIDs)
            for event in fetch(calendar, range: Self.reach(Self.window())) where AppleSyncMark(event.url, family: family) != nil {
                ids.insert(event.calendarItemIdentifier)
            }
            // Copies outside the window too.
            ids.formUnion(state.links.map(\.appleID))
            for id in ids {
                guard let event = master(id), event.calendar?.calendarIdentifier == calendar.calendarIdentifier,
                      AppleSyncMark(event.url, family: family) != nil || state.entryIDs.contains(id) else { continue }
                try? store.remove(event, span: .futureEvents, commit: false)
            }
            try? store.commit()
            lastFinished = Date()
        }
        save(nil, key: key)
        errors[key] = nil
        heldBack[key] = nil
    }

    /// Signing out: this device's syncs with `server`'s families are forgotten (the Apple events stay).
    func removeAll(server: URL) {
        let prefix = Self.safe(Self.serverPrefix(server))
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.base, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
        states = [:]
        loaded = []
        errors = [:]
        heldBack = [:]
    }

    func error(_ api: FamilyAPI) -> String? { Self.key(api).flatMap { errors[$0] } }
    func heldBack(_ api: FamilyAPI) -> Int { Self.key(api).flatMap { heldBack[$0] } ?? 0 }
    func isRunning(_ api: FamilyAPI) -> Bool { Self.key(api).map { running.contains($0) } ?? false }

    // MARK: When it runs

    /// Every family this device syncs, shortly (several reasons at once run once).
    func syncAllSoon() {
        allPending?.cancel()
        allPending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncAll()
        }
    }

    func syncAll() async {
        guard let app, !app.isDemo, app.phase == .ready, hasAccess else { return }
        for family in app.families {
            guard let context = app.context(for: family), state(for: context.api) != nil else { continue }
            await sync(context)
        }
    }

    /// The family's events or entries changed in the app: synced a few seconds later.
    func ohanaChanged(_ context: FamilyContext) {
        guard let key = Self.key(context.api), !running.contains(key), state(for: context.api) != nil else { return }
        pending[key]?.cancel()
        pending[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.sync(context)
        }
    }

    // MARK: Syncing

    func sync(_ context: FamilyContext) async {
        guard let key = Self.key(context.api), let state = state(for: context.api), !running.contains(key) else { return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            errors[key] = String(localized: "Ohana has no access to your calendars.")
            return
        }
        guard let calendar = store.calendar(withIdentifier: state.calendarID) else {
            errors[key] = String(localized: "The Apple calendar “\(state.calendarTitle)” is gone. Pick another one.")
            return
        }
        running.insert(key)
        defer {
            running.remove(key)
            lastFinished = Date()
        }
        do {
            var failed: (any Error)?
            var held = 0
            var changedOhana = false
            // A series made or changed as a whole has its occurrences synced in the next pass.
            for _ in 0..<3 {
                let pass = try await syncPass(context, calendar: calendar, key: key)
                failed = failed ?? pass.failed
                held = pass.heldBack
                changedOhana = changedOhana || pass.changedOhana
                guard pass.again, pass.failed == nil else { break }
            }
            heldBack[key] = held > 0 ? held : nil
            errors[key] = failed.map { String(localized: "Not everything could be synced: \($0.localizedDescription)") }
            if changedOhana { context.didChange(.events) }
        } catch is CancellationError {
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    /// One sync: reads both sides, plans, does it, keeps the links.
    private func syncPass(_ context: FamilyContext, calendar: EKCalendar, key: String) async throws -> Pass {
        guard let state = state(for: context.api) else { return Pass() }
        let family = context.family.id
        let window = Self.window()
        let reach = Self.reach(window)

        // Ohana: every event as stored, the occurrences around the window, the entries.
        let side = try await ohanaSide(context, window: window, reach: reach, entries: state.entries)
        let ohana = side.items
        let spans = side.spans
        guard self.state(for: context.api)?.calendarID == state.calendarID else { return Pass() } // stopped meanwhile

        // Apple: the events around the window, a series by its first occurrence.
        var events = AppleEvents()
        let apple = Self.appleItems(fetch(calendar, range: reach), window: window, events: &events) { self.master($0) }
        let plan = AppleSyncPlanner.plan(
            family: family, ohana: ohana, apple: apple, window: window, links: state.links,
            canEdit: context.canEdit, spans: spans, entryIDs: Set(state.entryIDs)
        ) { link in
            guard let event = self.master(link.appleID) ?? self.master(byKey: link.appleKey, in: calendar),
                  event.calendar?.calendarIdentifier == calendar.calendarIdentifier else { return .gone }
            events.masters[event.calendarItemIdentifier] = event
            let snapshot = Self.event(event)
            return .found(AppleSyncEvent(localID: snapshot.localID, key: snapshot.key, url: event.url,
                                         fields: snapshot.fields, inWindow: false))
        }

        let previous = Dictionary(state.links.map { ($0.ohanaID, $0) }, uniquingKeysWith: { first, _ in first })
        var steps = Steps(
            context: context, calendar: calendar, family: family, store: store, events: events,
            previous: previous, linked: Set(plan.keep.map(\.ohanaID)),
            pass: Pass(heldBack: plan.heldBack, again: plan.needsAnotherPass),
            links: plan.keep, entryIDs: plan.keepEntries
        )
        for step in plan.steps {
            do {
                try await steps.apply(step)
            } catch {
                steps.keepAfterFailure(step, error: error)
            }
        }
        for (id, days) in steps.failedDays {
            guard let index = steps.links.firstIndex(where: { $0.ohanaID == id }) else { continue }
            for day in days { steps.links[index].exceptions[day] = previous[id]?.exceptions[day] }
        }
        // Stopped or moved to another calendar meanwhile: this sync's links are of no use. Settings
        // changed meanwhile stay.
        guard var current = self.state(for: context.api), current.calendarID == state.calendarID else {
            return steps.pass
        }
        current.links = steps.links
        current.entryIDs = steps.entryIDs
        current.lastSync = Date()
        save(current, key: key)
        return steps.pass
    }

    /// What Ohana brings to the plan: every event as stored with its occurrences around the
    /// window, and the entry runs as all-day spans (only when the family syncs those).
    private func ohanaSide(_ context: FamilyContext, window: ClosedRange<Day>, reach: ClosedRange<Day>,
                           entries: Bool) async throws -> (items: [OhanaSyncItem], spans: [AppleSyncSpan]?) {
        let series: CalendarEventSeriesResponse = try await context.api.get("/events", query: ["raw": "1"])
        let listed: CalendarEventsResponse = try await context.api.get(
            "/events", query: ["from": reach.lowerBound.description, "to": reach.upperBound.description])
        let items = Self.items(series.events, occurrences: listed.events, window: window, reach: reach)
        guard entries else { return (items, nil) }
        var types: [Int: [CalendarEntryType]] = [:]
        var days: [Day: [String]] = [:]
        var members: [String: String] = [:]
        for year in window.lowerBound.year...window.upperBound.year {
            let calendarYear: CalendarState = try await context.api.get("", query: ["year": String(year)])
            types[year] = calendarYear.types
            for (day, ids) in calendarYear.entries { if let day = Day(day), day.year == year { days[day] = ids } }
            for member in calendarYear.members ?? [] { members[member.id] = member.name }
        }
        return (items, AppleSyncMapping.spans(entries: days, types: types, members: members, window: window))
    }

    private func fetch(_ calendar: EKCalendar, range: ClosedRange<Day>) -> [EKEvent] {
        let start = Day.calendar.startOfDay(for: range.lowerBound.date)
        let end = Day.calendar.startOfDay(for: range.upperBound.adding(days: 1).date)
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
    }

    /// A single event, or a series' first occurrence (with its rule).
    private func master(_ id: String) -> EKEvent? {
        store.calendarItem(withIdentifier: id) as? EKEvent
    }

    private func master(byKey key: String, in calendar: EKCalendar) -> EKEvent? {
        store.calendarItems(withExternalIdentifier: key).compactMap { $0 as? EKEvent }
            .first { $0.calendar?.calendarIdentifier == calendar.calendarIdentifier }
    }

    // MARK: Files

    private static func key(_ api: FamilyAPI) -> String? {
        api.client.isDemo ? nil : safe(serverPrefix(api.client.baseURL) + api.familyID)
    }

    private static func file(_ key: String) -> URL? {
        base.appending(path: "\(key).json")
    }

    private static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Ohana/CalendarSync", directoryHint: .isDirectory)
    }

    private static func serverPrefix(_ server: URL) -> String {
        "\(server.host() ?? "server")\(server.port.map { "-\($0)" } ?? "")_"
    }

    private static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
    }
}

enum AppleCalendarSyncError: LocalizedError {
    case noAccount

    var errorDescription: String? {
        String(localized: "There is no calendar account on this device to make the calendar in.")
    }
}

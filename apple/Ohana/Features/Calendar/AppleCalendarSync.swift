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
}

extension AppleCalendarSync {
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

    private struct Pass {
        var failed: (any Error)?
        var heldBack = 0
        var changedOhana = false
        var again = false
    }

    /// What one pass writes and keeps while its steps run: the plan's links and entries, what its
    /// steps add to them, and what they couldn't do. A class, so its steps can add to it as they go.
    private final class Writing {
        let context: FamilyContext
        let calendar: EKCalendar
        /// The Apple events read for this pass, with their masters.
        let events: AppleEvents
        let family: String
        /// The steps the planner made, in their order.
        let steps: [AppleSyncStep]
        /// The links this pass starts from, by Ohana event: a step that fails keeps them.
        let previous: [String: AppleSyncLink]
        /// The Ohana events that had a link when the plan was made.
        let linked: Set<String>
        var pass: Pass
        var links: [AppleSyncLink]
        var entryIDs: [String]
        /// Occurrences whose step failed: their last state stays, so they are tried again.
        var failedDays: [String: Set<Day>] = [:]

        init(context: FamilyContext, calendar: EKCalendar, events: AppleEvents, family: String,
             plan: AppleSyncPlan, state: AppleCalendarSyncState) {
            self.context = context
            self.calendar = calendar
            self.events = events
            self.family = family
            steps = plan.steps
            links = plan.keep
            entryIDs = plan.keepEntries
            pass = Pass(heldBack: plan.heldBack, again: plan.needsAnotherPass)
            previous = Dictionary(state.links.map { ($0.ohanaID, $0) }, uniquingKeysWith: { first, _ in first })
            linked = Set(plan.keep.map(\.ohanaID))
        }
    }

    /// What Ohana has for one pass: the events as the planner wants them and, when the family syncs
    /// its day entries too, the runs of entry types.
    private func readOhana(_ context: FamilyContext, state: AppleCalendarSyncState, window: ClosedRange<Day>)
        async throws -> (ohana: [OhanaSyncItem], spans: [AppleSyncSpan]?, reach: ClosedRange<Day>) {
        let reach = Self.reach(window)
        // Ohana: every event as stored, the occurrences around the window, the entries.
        let series: CalendarEventSeriesResponse = try await context.api.get("/events", query: ["raw": "1"])
        let listed: CalendarEventsResponse = try await context.api.get(
            "/events", query: ["from": reach.lowerBound.description, "to": reach.upperBound.description])
        let ohana = Self.items(series.events, occurrences: listed.events, window: window, reach: reach)
        guard state.entries else { return (ohana, nil, reach) }
        var types: [Int: [CalendarEntryType]] = [:]
        var entries: [Day: [String]] = [:]
        var members: [String: String] = [:]
        for year in window.lowerBound.year...window.upperBound.year {
            let calendarYear: CalendarState = try await context.api.get("", query: ["year": String(year)])
            types[year] = calendarYear.types
            for (day, ids) in calendarYear.entries { if let day = Day(day), day.year == year { entries[day] = ids } }
            for member in calendarYear.members ?? [] { members[member.id] = member.name }
        }
        return (ohana, AppleSyncMapping.spans(entries: entries, types: types, members: members, window: window), reach)
    }

    /// One sync: reads both sides, plans, does it, keeps the links.
    private func syncPass(_ context: FamilyContext, calendar: EKCalendar, key: String) async throws -> Pass {
        guard let state = state(for: context.api) else { return Pass() }
        let family = context.family.id
        let window = Self.window()
        let reading = try await readOhana(context, state: state, window: window)
        guard self.state(for: context.api)?.calendarID == state.calendarID else { return Pass() } // stopped meanwhile

        // Apple: the events around the window, a series by its first occurrence.
        var events = AppleEvents()
        let fetched = fetch(calendar, range: reading.reach)
        let apple = Self.appleItems(fetched, window: window, events: &events) { self.master($0) }
        let plan = AppleSyncPlanner.plan(
            family: family, ohana: reading.ohana, apple: apple, window: window, links: state.links,
            canEdit: context.canEdit, spans: reading.spans, entryIDs: Set(state.entryIDs)
        ) { link in
            guard let event = self.master(link.appleID) ?? self.master(byKey: link.appleKey, in: calendar),
                  event.calendar?.calendarIdentifier == calendar.calendarIdentifier else { return .gone }
            events.masters[event.calendarItemIdentifier] = event
            let snapshot = Self.event(event)
            return .found(AppleSyncEvent(localID: snapshot.localID, key: snapshot.key, url: event.url,
                                         fields: snapshot.fields, inWindow: false))
        }

        let writing = Writing(context: context, calendar: calendar, events: events, family: family,
                              plan: plan, state: state)
        await applySteps(writing)
        keepFailedOccurrences(writing)

        // Stopped or moved to another calendar meanwhile: this sync's links are of no use. Settings
        // changed meanwhile stay.
        guard var current = self.state(for: context.api), current.calendarID == state.calendarID else {
            return writing.pass
        }
        current.links = writing.links
        current.entryIDs = writing.entryIDs
        current.lastSync = Date()
        save(current, key: key)
        return writing.pass
    }

    // MARK: Doing the steps of a plan

    /// The steps one after another; what a step writes and keeps goes into `writing`.
    private func applySteps(_ writing: Writing) async {
        for step in writing.steps {
            do {
                try applyAppleStep(step, writing)
                try applyEntryStep(step, writing)
                try await applyOhanaStep(step, writing)
            } catch {
                keepWhatFailed(step, error: error, writing)
            }
        }
    }

    /// The steps that write on the Apple side; the other steps are for the passes below.
    private func applyAppleStep(_ step: AppleSyncStep, _ writing: Writing) throws {
        switch step {
        case let .createApple(item):
            let event = EKEvent(eventStore: store)
            event.calendar = writing.calendar
            Self.write(item.fields, to: event, isNew: true, rule: true)
            event.url = AppleSyncMark.url(family: writing.family, day: item.fields.date, .event(item.id))
            try store.save(event, span: .thisEvent, commit: true)
            writing.links.append(Self.link(item.id, item.fields, event))
        case let .updateApple(item, appleID):
            try updateOnApple(item, appleID: appleID, writing)
        case let .link(item, apple, exceptions):
            writing.links.append(AppleSyncLink(ohanaID: item.id, appleID: apple.localID, appleKey: apple.key,
                                               ohana: item.fields, apple: apple.fields, exceptions: exceptions))
        case let .deleteApple(appleID):
            if let event = writing.events.masters[appleID] {
                try store.remove(event, span: .futureEvents, commit: true)
            }
        default:
            break
        }
    }

    /// An Ohana event written into its Apple event: as a series when it or the Apple event has a rule.
    private func updateOnApple(_ item: OhanaSyncItem, appleID: String, _ writing: Writing) throws {
        guard let event = writing.events.masters[appleID] else { return }
        let span: EKSpan = event.hasRecurrenceRules || item.fields.rrule != nil ? .futureEvents : .thisEvent
        Self.write(item.fields, to: event, isNew: false, rule: true)
        if AppleSyncMark(event.url, family: writing.family) != nil {
            event.url = AppleSyncMark.url(family: writing.family, day: item.fields.date, .event(item.id))
        }
        try store.save(event, span: span, commit: true)
        let kept = Self.kept(writing.previous[item.id], rule: item.fields.rrule)
        writing.links.append(Self.link(item.id, item.fields, event, exceptions: kept))
    }

    /// The steps that write a day entry as an all-day event, or take it out again.
    private func applyEntryStep(_ step: AppleSyncStep, _ writing: Writing) throws {
        switch step {
        case let .createEntry(entry):
            let event = EKEvent(eventStore: store)
            event.calendar = writing.calendar
            event.title = entry.title
            event.isAllDay = true
            event.startDate = Day.calendar.startOfDay(for: entry.first.date)
            // Noon of the last day: read back as that day however the account stores the end.
            event.endDate = entry.last.date
            event.url = AppleSyncMark.url(family: writing.family, day: entry.first, .entry(entry.typeID))
            try store.save(event, span: .thisEvent, commit: true)
            writing.entryIDs.append(event.calendarItemIdentifier)
        case let .deleteEntry(appleID):
            if let event = writing.events.masters[appleID] {
                try store.remove(event, span: .futureEvents, commit: true)
            }
        default:
            break
        }
    }

    /// The steps that write in Ohana.
    private func applyOhanaStep(_ step: AppleSyncStep, _ writing: Writing) async throws {
        switch step {
        case let .createOhana(apple):
            try await importToOhana(apple, writing)
        case let .updateOhana(id, fields, apple):
            let updated: CalendarEventSeries = try await writing.context.api.send(
                .patch, "/events/\(id)", body: fields.input)
            writing.pass.changedOhana = true
            let kept = Self.kept(writing.previous[id], rule: fields.rrule)
            writing.links.append(AppleSyncLink(ohanaID: updated.id, appleID: apple.localID, appleKey: apple.key,
                                               ohana: OhanaSyncFields(updated), apple: apple.fields, exceptions: kept))
        case let .deleteOhana(id):
            do {
                try await writing.context.api.perform(.delete, "/events/\(id)")
            } catch let apiError as APIError where apiError.status == 404 {}
            writing.pass.changedOhana = true
        case let .updateOhanaOccurrence(id, day, fields):
            let _: CalendarEventSeries = try await writing.context.api.send(
                .patch, "/events/\(id)", query: Self.occurrenceQuery(day), body: fields.input)
            writing.pass.changedOhana = true
        case let .deleteOhanaOccurrence(id, day):
            do {
                let _: JSONValue = try await writing.context.api.send(
                    .delete, "/events/\(id)", query: Self.occurrenceQuery(day))
            } catch let apiError as APIError where apiError.status == 404 {}
            writing.pass.changedOhana = true
        default:
            break
        }
    }

    /// An Apple event brought into Ohana; its link stays only when the event isn't linked twice.
    private func importToOhana(_ apple: AppleSyncEvent, _ writing: Writing) async throws {
        let fields = AppleSyncMapping.ohana(apple.fields, url: apple.url, current: nil)
        let created: CalendarEventSeries = try await writing.context.api.send(
            .post, "/events", body: AppleImportBody(input: fields.input, externalId: apple.key))
        writing.pass.changedOhana = true
        let alreadyLinked = writing.links.contains(where: { $0.ohanaID == created.id })
        guard !writing.linked.contains(created.id), !alreadyLinked else { return }
        writing.links.append(AppleSyncLink(ohanaID: created.id, appleID: apple.localID, appleKey: apple.key,
                                           ohana: OhanaSyncFields(created), apple: apple.fields))
    }

    /// A step that failed: what it would have written stays as it was, so it is tried again.
    private func keepWhatFailed(_ step: AppleSyncStep, error: any Error, _ writing: Writing) {
        writing.pass.failed = error
        switch step {
        case let .updateAppleOccurrence(_, day, _, ohanaID), let .deleteAppleOccurrence(_, day, ohanaID):
            writing.failedDays[ohanaID, default: []].insert(day)
        case let .updateOhanaOccurrence(id, day, _), let .deleteOhanaOccurrence(id, day):
            writing.failedDays[id, default: []].insert(day)
        case let .updateApple(item, _), let .link(item, _, _):
            keepLink(of: item.id, writing)
        case let .updateOhana(id, _, _):
            keepLink(of: id, writing)
        default:
            break
        }
    }

    /// The link an Ohana event had before this pass, unless the pass made a new one for it.
    private func keepLink(of id: String, _ writing: Writing) {
        // A link that couldn't be brought up to date stays as it was: tried again next time.
        guard let link = writing.previous[id], !writing.links.contains(where: { $0.ohanaID == id }) else { return }
        writing.links.append(link)
    }

    /// The occurrences whose step failed: their last state stays, so they are tried again.
    private func keepFailedOccurrences(_ writing: Writing) {
        for (id, days) in writing.failedDays {
            guard let index = writing.links.firstIndex(where: { $0.ohanaID == id }) else { continue }
            for day in days { writing.links[index].exceptions[day] = writing.previous[id]?.exceptions[day] }
        }
    }

    /// A link's occurrences after its series changed as a whole: kept while the rule stays.
    private static func kept(_ link: AppleSyncLink?, rule: String?) -> [Day: AppleSyncException] {
        guard let link, link.ohana.rrule == RepeatRule.canonical(rule) else { return [:] }
        return link.exceptions
    }

    private static func occurrenceQuery(_ day: Day) -> [String: String?] {
        ["occurrence": day.description, "span": CalendarEventSpan.this.rawValue]
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

    private static func link(_ id: String, _ fields: OhanaSyncFields, _ event: EKEvent,
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
        return series.map { seriesItem in
            let listed = byID[seriesItem.id] ?? []
            var item = OhanaSyncItem(
                id: seriesItem.id, externalId: seriesItem.externalId, fields: OhanaSyncFields(seriesItem),
                inWindow: listed.contains { $0.date <= window.upperBound && $0.endDate >= window.lowerBound }
                    || (seriesItem.date <= window.upperBound && seriesItem.endDate >= window.lowerBound)
            )
            guard seriesItem.repeats else { return item }
            let overrides = Dictionary(seriesItem.overrides.map { ($0.occurrence, $0) },
                                       uniquingKeysWith: { first, _ in first })
            for found in listed {
                guard let day = found.occurrence else { continue }
                let fields = OhanaSyncFields(occurrence: found)
                item.occurrenceFields[day] = fields
                item.occurrences[day] = overrides[day] == nil ? .normal : .changed(fields)
            }
            // Changed ones moved far away still count on their own day.
            for override in seriesItem.overrides
            where reach.contains(override.occurrence) && item.occurrences[override.occurrence] == nil {
                let fields = OhanaSyncFields(
                    date: override.date, endDate: override.endDate, start: override.start, end: override.end,
                    title: override.title, location: override.location, person: override.person,
                    note: override.note, url: override.url
                )
                item.occurrenceFields[override.occurrence] = fields
                item.occurrences[override.occurrence] = .changed(fields)
            }
            for day in seriesItem.exdates where reach.contains(day) { item.occurrences[day] = .deleted }
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
    private static func appleItems(_ fetched: [EKEvent], window: ClosedRange<Day>, events: inout AppleEvents,
                                   master: (String) -> EKEvent?) -> [AppleSyncEvent] {
        var order: [String] = []
        var groups: [String: [EKEvent]] = [:]
        for found in fetched {
            let id = found.calendarItemIdentifier
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(found)
        }
        return order.compactMap { id in
            let list = groups[id]!
            let inWindow = list.contains { found in
                let fields = event(found).fields
                return fields.day <= window.upperBound && fields.lastDay >= window.lowerBound
            }
            guard list.contains(where: { $0.hasRecurrenceRules || $0.isDetached }) else {
                events.masters[id] = list[0]
                let snapshot = event(list[0])
                return AppleSyncEvent(localID: snapshot.localID, key: snapshot.key, url: list[0].url,
                                      fields: snapshot.fields, inWindow: inWindow)
            }
            guard let first = master(id) else { return nil }
            events.masters[id] = first
            var occurrences: [Day: AppleOccurrence] = [:]
            for found in list {
                let day = Day(found.occurrenceDate ?? found.startDate)
                events.occurrences[AppleEvents.occurrenceKey(id, day)] = found
                occurrences[day] = found.isDetached ? .changed(fields(found, rule: false)) : .normal
            }
            let snapshot = event(first)
            return AppleSyncEvent(localID: snapshot.localID, key: snapshot.key, url: first.url,
                                  fields: snapshot.fields, inWindow: inWindow, occurrences: occurrences)
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
    /// or a single event as a whole) the rule.
    static func write(_ ohana: OhanaSyncFields, to event: EKEvent, isNew: Bool, rule: Bool) {
        writeTexts(ohana, to: event, isNew: isNew)
        writeDays(ohana, to: event, isNew: isNew)
        if rule {
            event.recurrenceRules = ohana.rrule.flatMap(RepeatRule.init).map { [$0.ekRule] }
        }
    }

    /// The texts of an event: one that only reads the same as Ohana's keeps what Apple has (a long
    /// note isn't cut).
    private static func writeTexts(_ ohana: OhanaSyncFields, to event: EKEvent, isNew: Bool) {
        let apple = AppleSyncMapping.apple(ohana)
        let same = isNew ? (title: false, location: false, notes: false)
            : AppleSyncMapping.unchangedTexts(ohana, over: fields(event, rule: false))
        if !same.title { event.title = apple.title }
        if !same.location { event.location = apple.location.isEmpty ? nil : apple.location }
        if !same.notes { event.notes = apple.notes.isEmpty ? nil : apple.notes }
    }

    /// The days and times of an event: a timed one keeps its length, an all-day one ends at noon of
    /// its last day.
    private static func writeDays(_ ohana: OhanaSyncFields, to event: EKEvent, isNew: Bool) {
        let calendar = Day.calendar
        let midnight = calendar.startOfDay(for: ohana.date.date)
        let oldStart: Date? = isNew ? nil : event.startDate
        let oldEnd: Date? = isNew ? nil : event.endDate
        let wasAllDay = event.isAllDay
        guard let start = ohana.start, let begin = date(start, on: midnight) else {
            event.isAllDay = true
            event.startDate = midnight
            // Noon of the last day: read back as that day however the account stores the end.
            event.endDate = ohana.endDate.date
            return
        }
        event.isAllDay = false
        event.startDate = begin
        event.endDate = endDate(ohana, begin: begin, lastMidnight: calendar.startOfDay(for: ohana.endDate.date),
                                wasAllDay: wasAllDay, oldStart: oldStart, oldEnd: oldEnd)
    }

    /// When a timed event ends: the time Ohana gives, the end of its last day when it runs over more
    /// than one day, or the length it had.
    private static func endDate(_ ohana: OhanaSyncFields, begin: Date, lastMidnight: Date, wasAllDay: Bool,
                                oldStart: Date?, oldEnd: Date?) -> Date {
        if let end = ohana.end.flatMap({ date($0, on: lastMidnight) }) { return max(end, begin) }
        guard ohana.endDate > ohana.date else {
            var length: TimeInterval = 3600
            if !wasAllDay, let oldStart, let oldEnd, oldEnd > oldStart { length = oldEnd.timeIntervalSince(oldStart) }
            return begin.addingTimeInterval(length)
        }
        return Day.calendar.startOfDay(for: ohana.endDate.adding(days: 1).date)
    }

    private static func time(_ date: Date) -> String {
        let components = Day.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func date(_ time: String, on midnight: Date) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Day.calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: midnight)
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

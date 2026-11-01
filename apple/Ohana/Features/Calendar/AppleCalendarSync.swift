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
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(externalId, forKey: .externalId)
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

    func isRunning(_ api: FamilyAPI) -> Bool { Self.key(api).map(running.contains) ?? false }
    func error(_ api: FamilyAPI) -> String? { Self.key(api).flatMap { errors[$0] } }
    func heldBack(_ api: FamilyAPI) -> Int { Self.key(api).flatMap { heldBack[$0] } ?? 0 }

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

    /// One sync: reads both sides, plans, does it, keeps the links.
    private func syncPass(_ context: FamilyContext, calendar: EKCalendar, key: String) async throws -> Pass {
        guard let state = state(for: context.api) else { return Pass() }
        let family = context.family.id
        let window = Self.window()
        let reach = Self.reach(window)

        // Ohana: every event as stored, the occurrences around the window, the entries.
        let series: CalendarEventSeriesResponse = try await context.api.get("/events", query: ["raw": "1"])
        let listed: CalendarEventsResponse = try await context.api.get(
            "/events", query: ["from": reach.lowerBound.description, "to": reach.upperBound.description])
        let ohana = Self.items(series.events, occurrences: listed.events, window: window, reach: reach)
        var spans: [AppleSyncSpan]?
        if state.entries {
            var types: [Int: [CalendarEntryType]] = [:]
            var entries: [Day: [String]] = [:]
            for year in window.lowerBound.year...window.upperBound.year {
                let calendarYear: CalendarState = try await context.api.get("", query: ["year": String(year)])
                types[year] = calendarYear.types
                for (day, ids) in calendarYear.entries { if let day = Day(day), day.year == year { entries[day] = ids } }
            }
            spans = AppleSyncMapping.spans(entries: entries, types: types, window: window)
        }
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

        var pass = Pass(heldBack: plan.heldBack, again: plan.needsAnotherPass)
        var links = plan.keep
        var entryIDs = plan.keepEntries
        let previous = Dictionary(state.links.map { ($0.ohanaID, $0) }, uniquingKeysWith: { a, _ in a })
        let linked = Set(links.map(\.ohanaID))
        /// Occurrences whose step failed: their last state stays, so they are tried again.
        var failedDays: [String: Set<Day>] = [:]
        for step in plan.steps {
            do {
                switch step {
                case let .createApple(o):
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    Self.write(o.fields, to: event, isNew: true, rule: true)
                    event.url = AppleSyncMark.url(family: family, day: o.fields.date, .event(o.id))
                    try store.save(event, span: .thisEvent, commit: true)
                    links.append(Self.link(o.id, o.fields, event))
                case let .updateApple(o, appleID):
                    guard let event = events.masters[appleID] else { continue }
                    let span: EKSpan = event.hasRecurrenceRules || o.fields.rrule != nil ? .futureEvents : .thisEvent
                    Self.write(o.fields, to: event, isNew: false, rule: true)
                    if AppleSyncMark(event.url, family: family) != nil {
                        event.url = AppleSyncMark.url(family: family, day: o.fields.date, .event(o.id))
                    }
                    try store.save(event, span: span, commit: true)
                    links.append(Self.link(o.id, o.fields, event, exceptions: Self.kept(previous[o.id], rule: o.fields.rrule)))
                case let .link(o, a, exceptions):
                    links.append(AppleSyncLink(ohanaID: o.id, appleID: a.localID, appleKey: a.key, ohana: o.fields,
                                               apple: a.fields, exceptions: exceptions))
                case let .createOhana(a):
                    let fields = AppleSyncMapping.ohana(a.fields, url: a.url, current: nil)
                    let o: CalendarEventSeries = try await context.api.send(
                        .post, "/events", body: AppleImportBody(input: fields.input, externalId: a.key))
                    pass.changedOhana = true
                    guard !linked.contains(o.id), !links.contains(where: { $0.ohanaID == o.id }) else { continue }
                    links.append(AppleSyncLink(ohanaID: o.id, appleID: a.localID, appleKey: a.key,
                                               ohana: OhanaSyncFields(o), apple: a.fields))
                case let .updateOhana(id, fields, a):
                    let o: CalendarEventSeries = try await context.api.send(.patch, "/events/\(id)", body: fields.input)
                    pass.changedOhana = true
                    links.append(AppleSyncLink(ohanaID: o.id, appleID: a.localID, appleKey: a.key, ohana: OhanaSyncFields(o),
                                               apple: a.fields, exceptions: Self.kept(previous[id], rule: fields.rrule)))
                case let .deleteApple(appleID):
                    if let event = events.masters[appleID] { try store.remove(event, span: .futureEvents, commit: true) }
                case let .deleteOhana(id):
                    do {
                        try await context.api.perform(.delete, "/events/\(id)")
                    } catch let error as APIError where error.status == 404 {}
                    pass.changedOhana = true
                case let .updateAppleOccurrence(appleID, day, fields, ohanaID):
                    guard let event = events.occurrences[AppleEvents.occurrenceKey(appleID, day)] else {
                        failedDays[ohanaID, default: []].insert(day)
                        continue
                    }
                    Self.write(fields, to: event, isNew: false, rule: false)
                    try store.save(event, span: .thisEvent, commit: true)
                case let .deleteAppleOccurrence(appleID, day, _):
                    if let event = events.occurrences[AppleEvents.occurrenceKey(appleID, day)] {
                        try store.remove(event, span: .thisEvent, commit: true)
                    }
                case let .updateOhanaOccurrence(id, day, fields):
                    let _: CalendarEventSeries = try await context.api.send(
                        .patch, "/events/\(id)", query: Self.occurrenceQuery(day), body: fields.input)
                    pass.changedOhana = true
                case let .deleteOhanaOccurrence(id, day):
                    do {
                        let _: JSONValue = try await context.api.send(.delete, "/events/\(id)", query: Self.occurrenceQuery(day))
                    } catch let error as APIError where error.status == 404 {}
                    pass.changedOhana = true
                case let .createEntry(span):
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    event.title = span.title
                    event.isAllDay = true
                    event.startDate = Day.calendar.startOfDay(for: span.first.date)
                    // Noon of the last day: read back as that day however the account stores the end.
                    event.endDate = span.last.date
                    event.url = AppleSyncMark.url(family: family, day: span.first, .entry(span.typeID))
                    try store.save(event, span: .thisEvent, commit: true)
                    entryIDs.append(event.calendarItemIdentifier)
                case let .deleteEntry(appleID):
                    if let event = events.masters[appleID] { try store.remove(event, span: .futureEvents, commit: true) }
                }
            } catch {
                pass.failed = error
                switch step {
                case let .updateAppleOccurrence(_, day, _, ohanaID), let .deleteAppleOccurrence(_, day, ohanaID):
                    failedDays[ohanaID, default: []].insert(day)
                case let .updateOhanaOccurrence(id, day, _), let .deleteOhanaOccurrence(id, day):
                    failedDays[id, default: []].insert(day)
                case let .updateApple(o, _), let .link(o, _, _):
                    // A link that couldn't be brought up to date stays as it was: tried again next time.
                    if let link = previous[o.id], !links.contains(where: { $0.ohanaID == o.id }) { links.append(link) }
                case let .updateOhana(id, _, _):
                    if let link = previous[id], !links.contains(where: { $0.ohanaID == id }) { links.append(link) }
                default:
                    break
                }
            }
        }
        for (id, days) in failedDays {
            guard let i = links.firstIndex(where: { $0.ohanaID == id }) else { continue }
            for day in days { links[i].exceptions[day] = previous[id]?.exceptions[day] }
        }
        // Stopped or moved to another calendar meanwhile: this sync's links are of no use. Settings
        // changed meanwhile stay.
        guard var current = self.state(for: context.api), current.calendarID == state.calendarID else { return pass }
        current.links = links
        current.entryIDs = entryIDs
        current.lastSync = Date()
        save(current, key: key)
        return pass
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
        let a = Self.event(event)
        return AppleSyncLink(ohanaID: id, appleID: a.localID, appleKey: a.key, ohana: fields, apple: a.fields,
                             exceptions: exceptions)
    }

    // MARK: Ohana ↔ the planner

    /// The family's events for the planner: a series with its occurrences around the window by their
    /// original day (as the rule makes them, changed on their own, taken out).
    static func items(_ series: [CalendarEventSeries], occurrences: [CalendarEvent], window: ClosedRange<Day>,
                      reach: ClosedRange<Day>) -> [OhanaSyncItem] {
        let byID = Dictionary(grouping: occurrences, by: \.id)
        return series.map { s in
            let listed = byID[s.id] ?? []
            var item = OhanaSyncItem(
                id: s.id, externalId: s.externalId, fields: OhanaSyncFields(s),
                inWindow: listed.contains { $0.date <= window.upperBound && $0.endDate >= window.lowerBound }
                    || (s.date <= window.upperBound && s.endDate >= window.lowerBound)
            )
            guard s.repeats else { return item }
            let overrides = Dictionary(s.overrides.map { ($0.occurrence, $0) }, uniquingKeysWith: { a, _ in a })
            for e in listed {
                guard let day = e.occurrence else { continue }
                let fields = OhanaSyncFields(occurrence: e)
                item.occurrenceFields[day] = fields
                item.occurrences[day] = overrides[day] == nil ? .normal : .changed(fields)
            }
            // Changed ones moved far away still count on their own day.
            for o in s.overrides where reach.contains(o.occurrence) && item.occurrences[o.occurrence] == nil {
                let fields = OhanaSyncFields(date: o.date, endDate: o.endDate, start: o.start, end: o.end, title: o.title,
                                             location: o.location, person: o.person, note: o.note, url: o.url)
                item.occurrenceFields[o.occurrence] = fields
                item.occurrences[o.occurrence] = .changed(fields)
            }
            for day in s.exdates where reach.contains(day) { item.occurrences[day] = .deleted }
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
        for e in fetched {
            let id = e.calendarItemIdentifier
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(e)
        }
        return order.compactMap { id in
            let list = groups[id]!
            let inWindow = list.contains { e in
                let a = event(e).fields
                return a.day <= window.upperBound && a.lastDay >= window.lowerBound
            }
            guard list.contains(where: { $0.hasRecurrenceRules || $0.isDetached }) else {
                events.masters[id] = list[0]
                let a = event(list[0])
                return AppleSyncEvent(localID: a.localID, key: a.key, url: list[0].url, fields: a.fields, inWindow: inWindow)
            }
            guard let first = master(id) else { return nil }
            events.masters[id] = first
            var occurrences: [Day: AppleOccurrence] = [:]
            for e in list {
                let day = Day(e.occurrenceDate ?? e.startDate)
                events.occurrences[AppleEvents.occurrenceKey(id, day)] = e
                occurrences[day] = e.isDetached ? .changed(fields(e, rule: false)) : .normal
            }
            let a = event(first)
            return AppleSyncEvent(localID: a.localID, key: a.key, url: first.url, fields: a.fields, inWindow: inWindow,
                                  occurrences: occurrences)
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
            rrule: rule ? event.recurrenceRules?.first.flatMap(repeatRule).map(\.string) : nil
        )
    }

    /// Writes Ohana's event into the Apple event: the days and times, the texts and (`rule`, a series
    /// or a single event as a whole) the rule. A timed event without an end keeps its length.
    static func write(_ o: OhanaSyncFields, to event: EKEvent, isNew: Bool, rule: Bool) {
        let a = AppleSyncMapping.apple(o)
        event.title = a.title
        event.location = a.location.isEmpty ? nil : a.location
        event.notes = a.notes.isEmpty ? nil : a.notes
        let calendar = Day.calendar
        let midnight = calendar.startOfDay(for: o.date.date)
        let oldStart: Date? = isNew ? nil : event.startDate
        let oldEnd: Date? = isNew ? nil : event.endDate
        if let start = o.start, let begin = date(start, on: midnight) {
            let lastMidnight = calendar.startOfDay(for: o.endDate.date)
            var length: TimeInterval = 3600
            if !event.isAllDay, let oldStart, let oldEnd, oldEnd > oldStart { length = oldEnd.timeIntervalSince(oldStart) }
            event.isAllDay = false
            event.startDate = begin
            if let end = o.end.flatMap({ date($0, on: lastMidnight) }) {
                event.endDate = max(end, begin)
            } else if o.endDate > o.date {
                event.endDate = calendar.startOfDay(for: o.endDate.adding(days: 1).date)
            } else {
                event.endDate = begin.addingTimeInterval(length)
            }
        } else {
            event.isAllDay = true
            event.startDate = midnight
            // Noon of the last day: read back as that day however the account stores the end.
            event.endDate = o.endDate.date
        }
        if rule {
            event.recurrenceRules = o.rrule.flatMap(RepeatRule.init).map { [ekRule($0)] }
        }
    }

    /// EventKit's rule for a `RepeatRule` (EventKit has no week start of its own to set).
    static func ekRule(_ rule: RepeatRule) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let days = rule.weekdays.compactMap { entry -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: entry.weekday) else { return nil }
            return entry.ordinal.map { EKRecurrenceDayOfWeek(weekday, weekNumber: $0) } ?? EKRecurrenceDayOfWeek(weekday)
        }
        let end: EKRecurrenceEnd? = switch rule.end {
        case .never: nil
        // The end of the day, so its last occurrence is in at any time.
        case let .until(day): EKRecurrenceEnd(end: Day.calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day.date) ?? day.date)
        case let .count(n): EKRecurrenceEnd(occurrenceCount: n)
        }
        func numbers(_ list: [Int]) -> [NSNumber]? { list.isEmpty ? nil : list.map { NSNumber(value: $0) } }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: rule.interval, daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(rule.monthDays), monthsOfTheYear: numbers(rule.months),
            weeksOfTheYear: numbers(rule.weekNumbers), daysOfTheYear: numbers(rule.yearDays),
            setPositions: numbers(rule.setPositions), end: end
        )
    }

    /// A `RepeatRule` for EventKit's (nil for a frequency Ohana doesn't have).
    static func repeatRule(_ rule: EKRecurrenceRule) -> RepeatRule? {
        let frequency: RepeatRule.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let end: RepeatRule.End = if let count = rule.recurrenceEnd?.occurrenceCount, count > 0 {
            .count(count)
        } else if let date = rule.recurrenceEnd?.endDate {
            .until(Day(date))
        } else {
            .never
        }
        return RepeatRule(
            frequency, interval: rule.interval,
            weekdays: (rule.daysOfTheWeek ?? []).map {
                RepeatRule.WeekdayEntry($0.dayOfTheWeek.rawValue, ordinal: $0.weekNumber == 0 ? nil : $0.weekNumber)
            },
            monthDays: (rule.daysOfTheMonth ?? []).map(\.intValue), months: (rule.monthsOfTheYear ?? []).map(\.intValue),
            yearDays: (rule.daysOfTheYear ?? []).map(\.intValue), weekNumbers: (rule.weeksOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            weekStart: rule.firstDayOfTheWeek == 0 ? nil : rule.firstDayOfTheWeek, end: end
        )
    }

    private static func time(_ date: Date) -> String {
        let c = Day.calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
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

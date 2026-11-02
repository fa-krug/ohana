import Foundation
import Observation

/// One change to the chores, made on the device at once and sent when the server can be reached.
enum ChoreChange: Codable, Equatable {
    /// POST /chores with the id the app made.
    case create(id: String, input: ChoreInput)
    /// PATCH /chores/{id}
    case update(id: String, input: ChoreInput)
    /// DELETE /chores/{id}
    case delete(id: String)
    /// POST /chores/{id}/done
    case done(id: String, body: ChoreDoneBody)
    /// POST /chores/{id}/subscribe (the signed-in account)
    case subscribe(id: String, on: Bool)

    var choreID: String {
        switch self {
        case let .create(id, _), let .update(id, _), let .delete(id), let .done(id, _), let .subscribe(id, _): id
        }
    }
}

/// What the chores pages show: the chores (`GET /chores`) and the days of the agenda the server
/// answered for, each change applied on top the way the server would.
struct ChoresSnapshot: Equatable {
    var page: ChoresPage
    /// The agenda's days (a day without chores: an empty list); the others are worked out from the
    /// chores (`items(on:)`).
    var days: [Day: [ChoreItem]] = [:]

    /// The chores of `day`: the agenda's, else the chores due that day as far as the device can
    /// tell (a repeating one's occurrences not ticked off).
    func items(on day: Day) -> [ChoreItem] {
        if let items = days[day] { return items }
        return page.chores.compactMap { chore in
            let due = chore.rule.map { $0.occurs(on: day, start: chore.day) } ?? (chore.day == day)
            return due ? ChoreItem(chore, on: day) : nil
        }
    }

    /// The open single chores whose day passed, oldest first.
    func overdue(today: Day) -> [ChoreItem] {
        page.chores.filter { !$0.isRepeating && !$0.done && $0.day < today }
            .map { ChoreItem($0, on: $0.day) }
            .sorted { a, b in
                if a.day != b.day { return a.day < b.day }
                let (pa, pb) = (ChorePart.allCases.firstIndex(of: a.part)!, ChorePart.allCases.firstIndex(of: b.part)!)
                if pa != pb { return pa < pb }
                if (a.time ?? "") != (b.time ?? "") { return (a.time ?? "") < (b.time ?? "") }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }

    /// Applies `change` as the server would (before it answers). A change to a chore that isn't
    /// there (deleted meanwhile) changes nothing.
    mutating func apply(_ change: ChoreChange, me: String?, today: Day, now: Date = Date()) {
        let id = change.choreID
        let index = page.chores.firstIndex { $0.id == id }
        let stamp = now.ISO8601Format()
        switch change {
        case let .create(_, input), let .update(_, input):
            if case .update = change, index == nil { return }
            let chore = Chore(local: id, input, old: index.map { page.chores[$0] }, people: page.people, me: me,
                              today: today, stamp: stamp)
            if let index { page.chores[index] = chore } else { page.chores.append(chore) }
            place(chore)
        case .delete:
            page.chores.removeAll { $0.id == id }
            for day in days.keys { days[day]?.removeAll { $0.choreId == id } }
        case let .done(_, body):
            guard let index else { return }
            let by = me.flatMap { me in page.people.first { $0.id == me } }
            let chore = page.chores[index]
            if chore.isRepeating {
                guard let day = body.day else { return }
                updateItems(id, day: day) { $0.setDone(body.done, stamp: stamp, by: by) }
            } else {
                page.chores[index].done = body.done
                page.chores[index].doneAt = body.done ? chore.doneAt ?? stamp : nil
                page.chores[index].doneBy = body.done ? chore.doneBy ?? by : nil
                page.chores[index].next = body.done ? nil : chore.day
                updateItems(id) { $0.setDone(body.done, stamp: stamp, by: by) }
            }
        case let .subscribe(_, on):
            guard let index else { return }
            page.chores[index] = page.chores[index].subscribing(on, me: me)
            updateItems(id) { $0.subscribed = on }
        }
    }

    /// The chore as the server answered it.
    mutating func take(_ chore: Chore) {
        if let index = page.chores.firstIndex(where: { $0.id == chore.id }) { page.chores[index] = chore }
    }

    /// The agenda's days the server answered with, in place of what was known of them.
    mutating func take(_ agenda: ChoreAgenda) {
        for day in agenda.days { days[day.date] = day.items }
    }

    /// The agenda holds every day of `window`.
    func covers(_ window: (from: Day, to: Day)) -> Bool {
        CalendarMath.range(window.from, window.to).allSatisfy { days[$0] != nil }
    }

    private mutating func updateItems(_ id: String, day: Day? = nil, _ change: (inout ChoreItem) -> Void) {
        for d in days.keys where day == nil || d == day {
            guard let items = days[d], items.contains(where: { $0.choreId == id }) else { continue }
            days[d] = items.map { item in
                guard item.choreId == id else { return item }
                var item = item
                change(&item)
                return item
            }
        }
    }

    /// Puts a new or changed chore on its days of the agenda; a repeating one's occurrences keep
    /// whether they were ticked off.
    private mutating func place(_ chore: Chore) {
        var before: [Day: ChoreItem] = [:]
        for (day, items) in days {
            guard let item = items.first(where: { $0.choreId == chore.id }) else { continue }
            before[day] = item
            days[day] = items.filter { $0.choreId != chore.id }
        }
        guard let first = days.keys.min(), let last = days.keys.max() else { return }
        let due = chore.rule.map { $0.occurrences(start: chore.day, from: first, to: last) } ?? [chore.day]
        for day in due where days[day] != nil {
            var item = ChoreItem(chore, on: day)
            if chore.isRepeating, let old = before[day], old.repeating {
                item.done = old.done
                item.doneAt = old.doneAt
                item.doneBy = old.doneBy
            }
            days[day]?.append(item)
        }
    }
}

extension ChoreItem {
    /// `chore` on `day`, as the agenda lists it.
    init(_ chore: Chore, on day: Day) {
        let done = !chore.isRepeating && chore.done
        self.init(choreId: chore.id, day: day, title: chore.title, note: chore.note, assignee: chore.assignee,
                  part: chore.part, time: chore.time, repeating: chore.isRepeating, done: done,
                  doneAt: done ? chore.doneAt : nil, doneBy: done ? chore.doneBy : nil, subscribed: chore.subscribed)
    }

    fileprivate mutating func setDone(_ on: Bool, stamp: String, by: ChorePerson?) {
        doneAt = on ? doneAt ?? stamp : nil
        doneBy = on ? doneBy ?? by : nil
        done = on
    }
}

extension Chore {
    /// The chore `input` makes, before the server answers; an edit keeps from `old` what the input
    /// doesn't hold (whether it's done, when it was made). One that starts repeating isn't done.
    init(local id: String, _ input: ChoreInput, old: Chore?, people: [ChorePerson], me: String?, today: Day, stamp: String) {
        let assignee = input.assigneeId.flatMap { assignee in
            people.first { $0.id == assignee } ?? (old?.assignee?.id == assignee ? old?.assignee : nil)
        }
        let rrule = input.rrule
        let done = rrule == nil && old?.done == true
        let next: Day? = if let rule = rrule.flatMap(RepeatRule.init) {
            rule.occurrences(start: input.day, from: max(today, input.day),
                             to: Day(year: today.year + 100, month: 12, day: 31), limit: 1).first
        } else {
            done ? nil : input.day
        }
        self.init(id: id, title: input.title, note: input.note, assignee: assignee, day: input.day, time: input.time,
                  part: input.effectivePart, rrule: rrule, done: done, doneAt: done ? old?.doneAt : nil,
                  doneBy: done ? old?.doneBy : nil, next: next, subscriberIds: input.subscriberIds,
                  subscribed: me.map { input.subscriberIds.contains($0) } ?? false,
                  createdAt: old?.createdAt ?? stamp, updatedAt: stamp)
    }
}

/// The chores of one family, kept on the device: the server's chores and agenda (their copies in
/// `ResponseCache`) show at once and are brought up to date in the background whenever the server
/// can be reached. Changes show at once and wait in a queue kept on the device (`queueFile`) until
/// the server took them, sent in order; the server wins: what it refuses is dropped and the chores
/// load again. One per family (`FamilyContext.chores`), shared by the chores pages.
@Observable
final class ChoresStore {
    enum Phase: Equatable {
        case loading, loaded
        /// Nothing on the device and the server couldn't be asked.
        case failed(String)
    }

    let api: FamilyAPI
    /// The signed-in account: its subscriptions, who ticked a chore off.
    var me: String? {
        didSet { if me != oldValue { rebuild() } }
    }
    /// Whether the account edits the family, until the server said (`ChoresPage.canEdit`).
    var familyCanEdit: Bool
    /// Told when the server took changes (the overview, the widgets, the search).
    @ObservationIgnored var notify: ((DataArea) -> Void)?

    private(set) var phase: Phase = .loading
    /// What shows: the server's chores with the queued changes on top; nil before any are known.
    private(set) var shown: ChoresSnapshot?

    /// The server's state as far as it's known (its last answers, the changes it took since).
    @ObservationIgnored private var base: ChoresSnapshot?
    @ObservationIgnored private var queue: [ChoreChange] = []
    /// Where the queue is kept while it holds changes; nil: only in memory (the demo, tests).
    @ObservationIgnored private let queueFile: URL?
    /// The windows of the agenda (by their first day) the server answered since the last refresh,
    /// and those being asked for.
    @ObservationIgnored private var windowsLoaded: Set<Day> = []
    @ObservationIgnored private var windowsLoading: Set<Day> = []
    /// The day on screen: a refresh loads its window.
    @ObservationIgnored private var focus = Day.today
    /// Counts the changes the server took or refused: an answer asked before one of them may miss it.
    @ObservationIgnored private var sent = 0
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var retryDelay: Double = 2
    @ObservationIgnored private var retryWait: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    /// `removeQueues` ran since this store was made (signed out): it sends and keeps nothing more.
    @ObservationIgnored private let generation: Int

    /// The copies on the device show at once; a queue left from before is sent.
    init(api: FamilyAPI, canEdit: Bool, queueFile: URL? = nil, today: Day = .today) {
        self.api = api
        familyCanEdit = canEdit
        self.queueFile = queueFile
        generation = Self.generation
        if let queueFile, let data = try? Data(contentsOf: queueFile),
           let saved = try? JSONDecoder().decode([ChoreChange].self, from: data) {
            queue = saved
        }
        if let page = Self.pageRequest(api, today: today).saved()?.value {
            var snapshot = ChoresSnapshot(page: page)
            if let agenda = Self.agendaRequest(api, around: today, today: today).saved()?.value { snapshot.take(agenda) }
            base = snapshot
        }
        rebuild()
        if !queue.isEmpty { Task { await flush() } }
        Connectivity.shared.whenReconnected { [weak self] in
            self?.retryNow()
            Task { await self?.refresh() }
        }
    }

    // MARK: Reading

    var page: ChoresPage? { shown?.page }
    var canEdit: Bool { page?.canEdit ?? familyCanEdit }
    /// Changes wait to be sent (or are being sent).
    var pending: Bool { !queue.isEmpty || flushing }

    func chore(_ id: String) -> Chore? { page?.chores.first { $0.id == id } }

    func items(on day: Day) -> [ChoreItem] { shown?.items(on: day) ?? [] }

    func overdue(today: Day = .today) -> [ChoreItem] { shown?.overdue(today: today) ?? [] }

    /// Editors tick off any chore, the member it's for theirs.
    func canTick(_ item: ChoreItem) -> Bool {
        if canEdit { return true }
        guard let me, let assignee = item.assignee else { return false }
        return assignee.id == me
    }

    // MARK: Requests

    /// The chores' GET (the prefetch asks the same); its copy is kept whatever the day.
    static func pageRequest(_ api: FamilyAPI, today: Day = .today) -> CachedGet<ChoresPage> {
        api.cached("/chores", query: ["today": today.description], key: "/chores")
    }

    /// The agenda of the window around `day` (`ChoreAgenda.window`); the one around today is kept
    /// whatever the day, the others by their days.
    static func agendaRequest(_ api: FamilyAPI, around day: Day, today: Day = .today) -> CachedGet<ChoreAgenda> {
        let window = ChoreAgenda.window(around: day, today: today)
        let range = ["from": window.from.description, "to": window.to.description]
        let current = window == ChoreAgenda.window(around: today, today: today)
        return api.cached("/chores/agenda", query: range.merging(["today": today.description]) { a, _ in a },
                          key: current ? "/chores/agenda" : "/chores/agenda?from=\(window.from)&to=\(window.to)")
    }

    static var todayQuery: [String: String?] { ["today": Day.today.description] }

    // MARK: Loading

    /// Asks the server for the chores and the window of the day on screen, quietly: while it
    /// can't be reached what's on the device stays. Changes waiting are sent first. Not cancelled
    /// with the caller (a screen going away): another screen may wait for the same load.
    func refresh() async {
        retryNow()
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        let task = Task {
            repeat {
                refreshAgain = false
                await load()
            } while refreshAgain
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func load() async {
        let today = Day.today
        let window = ChoreAgenda.window(around: focus, today: today)
        let sent = self.sent
        do {
            async let page = fetchPage(today)
            async let agenda = fetchAgenda(around: focus, today: today)
            let (p, a) = try await (page, agenda)
            // The server took a change meanwhile, which the answer may miss: ask again.
            guard sent == self.sent else {
                refreshAgain = true
                return
            }
            var snapshot = base ?? ChoresSnapshot(page: p)
            snapshot.page = p
            snapshot.take(a)
            base = snapshot
            // The other windows may be out of date: asked again when they show.
            windowsLoaded = [window.from]
            phase = .loaded
            rebuild()
        } catch {
            if base == nil, !(error is CancellationError) { phase = .failed(error.localizedDescription) }
        }
    }

    private func fetchPage(_ today: Day) async throws -> ChoresPage {
        try await Self.pageRequest(api, today: today).fetch()
    }

    private func fetchAgenda(around day: Day, today: Day) async throws -> ChoreAgenda {
        try await Self.agendaRequest(api, around: day, today: today).fetch()
    }

    /// The day on screen: its window of the agenda is loaded unless it was since the last refresh
    /// (its copy on the device shows meanwhile).
    func show(_ day: Day) {
        focus = day
        let today = Day.today
        let window = ChoreAgenda.window(around: day, today: today)
        guard base != nil, !windowsLoaded.contains(window.from), !windowsLoading.contains(window.from) else { return }
        if base?.covers(window) == false, let copy = Self.agendaRequest(api, around: day, today: today).saved() {
            base?.take(copy.value)
            rebuild()
        }
        windowsLoading.insert(window.from)
        Task {
            defer { windowsLoading.remove(window.from) }
            while true {
                let sent = self.sent
                guard let agenda = try? await Self.agendaRequest(api, around: day, today: today).fetch() else { return }
                guard sent == self.sent else { continue }
                base?.take(agenda)
                windowsLoaded.insert(window.from)
                rebuild()
                return
            }
        }
    }

    /// What shows: the server's state with the queue on top. Only a change is assigned.
    private func rebuild() {
        guard var snapshot = base else { return }
        let today = Day.today
        for change in queue { snapshot.apply(change, me: me, today: today) }
        if shown != snapshot { shown = snapshot }
        if phase != .loaded { phase = .loaded }
    }

    // MARK: Changing

    /// Adds a chore (`id` nil) or changes one; the id it has.
    @discardableResult
    func save(_ input: ChoreInput, editing id: String? = nil) -> String {
        guard canEdit else { return id ?? "" }
        if let id {
            enqueue(.update(id: id, input: input))
            return id
        }
        let id = UUID().uuidString.lowercased()
        var input = input
        input.id = id
        enqueue(.create(id: id, input: input))
        return id
    }

    func delete(_ id: String) {
        guard canEdit else { return }
        enqueue(.delete(id: id))
    }

    /// Ticks `item` off, or opens it again (a repeating chore's occurrence).
    func toggleDone(_ item: ChoreItem) {
        guard canTick(item) else { return }
        enqueue(.done(id: item.choreId, body: ChoreDoneBody(toggling: item)))
    }

    /// The signed-in account notified when it's due, or not.
    func subscribe(_ id: String, _ on: Bool) {
        enqueue(.subscribe(id: id, on: on))
    }

    private func enqueue(_ change: ChoreChange) {
        guard base != nil else { return }
        queue.append(change)
        saveQueue()
        rebuild()
        Task { await flush() }
    }

    // MARK: Sending

    /// The connection is back (or the app active again): what waits is sent now, not after the
    /// backoff.
    func retryNow() {
        retryDelay = 2
        retryWait?.cancel()
        retryWait = nil
        if !flushing && !queue.isEmpty { Task { await flush() } }
    }

    private var closed: Bool { generation != Self.generation }

    private func flush() async {
        guard !flushing, !closed else { return }
        flushing = true
        var took = false, refused = false
        while let change = queue.first, !closed {
            do {
                let chore = try await send(change)
                accept(chore)
                took = true
            } catch let error as APIError where Self.isRejection(error) {
                // Sent before, its answer lost: the server has it.
                if case .create = change, error.status == 409 {
                    accept(nil)
                    took = true
                } else if case .delete = change, error.status == 404 {
                    accept(nil)
                    took = true
                } else {
                    // The server wins: the change is dropped and the chores load again.
                    dequeue()
                    rebuild()
                    refused = true
                    ErrorBanner.shared.show(String(localized: "Couldn’t save: \(error.localizedDescription)"))
                }
            } catch {
                // Offline or the server down: again after a while, or once the connection is back.
                scheduleRetry()
                break
            }
        }
        flushing = false
        if took { notify?(.chores) }
        if took || refused { await refresh() }
    }

    /// The first change is the server's now: it joins the known state (with the chore as the
    /// server answered).
    private func accept(_ chore: Chore?) {
        guard let change = queue.first else { return }
        base?.apply(change, me: me, today: .today)
        if let chore { base?.take(chore) }
        dequeue()
        retryDelay = 2
        rebuild()
    }

    private func dequeue() {
        if !queue.isEmpty { queue.removeFirst() }
        sent += 1
        saveQueue()
    }

    private func send(_ change: ChoreChange) async throws -> Chore? {
        let query = Self.todayQuery
        let response: ChoreResponse
        switch change {
        case let .create(_, input):
            response = try await api.send(.post, "/chores", query: query, body: input)
        case let .update(id, input):
            response = try await api.send(.patch, "/chores/\(id)", query: query, body: input)
        case let .delete(id):
            try await api.perform(.delete, "/chores/\(id)")
            return nil
        case let .done(id, body):
            response = try await api.send(.post, "/chores/\(id)/done", query: query, body: body)
        case let .subscribe(id, on):
            response = try await api.send(.post, "/chores/\(id)/subscribe", query: query,
                                          body: ChoreSubscribeBody(subscribed: on))
        }
        return response.chore
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        retryWait?.cancel()
        retryWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            retryWait = nil
            await flush()
        }
    }

    /// A refusal that won't change by trying again (unlike 408, 429, 5xx and network errors).
    private static func isRejection(_ error: APIError) -> Bool {
        guard let status = error.status else { return false }
        return !APIError.isTemporary(error) && status < 500
    }

    // MARK: The queue on the device

    /// Keeps the queue on the device while it holds changes.
    private func saveQueue() {
        guard let queueFile, !closed else { return }
        do {
            if queue.isEmpty {
                try? FileManager.default.removeItem(at: queueFile)
            } else {
                try FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(queue).write(to: queueFile, options: .atomic)
            }
        } catch {
            // The queue in memory is still sent; only quitting before that would lose it.
        }
    }

    /// Grows with every `removeQueues`: the stores made before stop.
    private static var generation = 0

    /// Where a family's queue is kept: Application Support, `Ohana/Chores/<server>_<family>/
    /// queue.json`; nil in the demo.
    static func queueFile(for api: FamilyAPI) -> URL? {
        guard !api.client.isDemo else { return nil }
        return queueBase.appending(path: safe(serverPrefix(api.client.baseURL) + api.familyID), directoryHint: .isDirectory)
            .appending(path: "queue.json")
    }

    /// Whether changes of the family wait on the device.
    static func hasQueue(for api: FamilyAPI) -> Bool {
        queueFile(for: api).map { FileManager.default.fileExists(atPath: $0.path()) } ?? false
    }

    /// Signing out or pairing anew: the queues of every family on `server` are removed.
    static func removeQueues(server: URL) {
        generation += 1
        let prefix = safe(serverPrefix(server))
        let folders = (try? FileManager.default.contentsOfDirectory(at: queueBase, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static var queueBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Ohana/Chores", directoryHint: .isDirectory)
    }

    private static func serverPrefix(_ server: URL) -> String {
        "\(server.host() ?? "server")\(server.port.map { "-\($0)" } ?? "")_"
    }

    /// A file name of letters, digits, dots, dashes and underscores.
    private static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
    }
}

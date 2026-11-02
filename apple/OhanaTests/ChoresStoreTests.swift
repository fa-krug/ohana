import Foundation
import Testing
@testable import Ohana

private func d(_ s: String) -> Day { Day(s)! }

/// Repeat rules expanded on the device, as the server does (rrule.ts `expandRule`).
struct RepeatRuleOccurrenceTests {
    private func days(_ rule: String, start: String, from: String, to: String, limit: Int = 5000) -> [String] {
        RepeatRule(rule)!.occurrences(start: d(start), from: d(from), to: d(to), limit: limit).map(\.description)
    }

    @Test func dailyAndInterval() {
        #expect(days("FREQ=DAILY;INTERVAL=2", start: "2026-11-02", from: "2026-11-01", to: "2026-11-10")
            == ["2026-11-02", "2026-11-04", "2026-11-06", "2026-11-08", "2026-11-10"])
        // Far after the start: skipped ahead.
        #expect(days("FREQ=DAILY", start: "2026-01-01", from: "2030-01-01", to: "2030-01-03")
            == ["2030-01-01", "2030-01-02", "2030-01-03"])
        // Nothing before the start.
        #expect(days("FREQ=DAILY", start: "2026-11-05", from: "2026-11-01", to: "2026-11-06") == ["2026-11-05", "2026-11-06"])
        #expect(days("FREQ=DAILY", start: "2026-11-05", from: "2026-11-01", to: "2026-11-04").isEmpty)
    }

    @Test func weeklyOnWeekdays() {
        // 2026-11-02 is a Monday.
        #expect(days("FREQ=WEEKLY", start: "2026-11-02", from: "2026-11-01", to: "2026-11-20")
            == ["2026-11-02", "2026-11-09", "2026-11-16"])
        #expect(days("FREQ=WEEKLY;BYDAY=MO,WE", start: "2026-11-02", from: "2026-11-01", to: "2026-11-15")
            == ["2026-11-02", "2026-11-04", "2026-11-09", "2026-11-11"])
        // The start is always one, even on another weekday.
        #expect(days("FREQ=WEEKLY;BYDAY=MO,WE", start: "2026-11-03", from: "2026-11-01", to: "2026-11-10")
            == ["2026-11-03", "2026-11-04", "2026-11-09"])
        // Every other week.
        #expect(days("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH", start: "2026-11-03", from: "2026-11-01", to: "2026-11-30")
            == ["2026-11-03", "2026-11-05", "2026-11-17", "2026-11-19"])
    }

    @Test func monthlyByDayAndOrdinalWeekday() {
        // The 31st: only months that have one.
        #expect(days("FREQ=MONTHLY", start: "2026-01-31", from: "2026-01-01", to: "2026-06-30")
            == ["2026-01-31", "2026-03-31", "2026-05-31"])
        #expect(days("FREQ=MONTHLY;BYDAY=2TU", start: "2026-11-10", from: "2026-11-01", to: "2027-01-31")
            == ["2026-11-10", "2026-12-08", "2027-01-12"])
        #expect(days("FREQ=MONTHLY;BYDAY=-1FR", start: "2026-11-27", from: "2026-11-01", to: "2027-01-31")
            == ["2026-11-27", "2026-12-25", "2027-01-29"])
        #expect(days("FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=-1", start: "2026-01-31", from: "2026-01-01", to: "2026-12-31")
            == ["2026-01-31", "2026-04-30", "2026-07-31", "2026-10-31"])
    }

    @Test func yearly() {
        #expect(days("FREQ=YEARLY", start: "2024-02-29", from: "2024-01-01", to: "2032-12-31")
            == ["2024-02-29", "2028-02-29", "2032-02-29"])
        #expect(days("FREQ=YEARLY;INTERVAL=2", start: "2026-11-02", from: "2026-01-01", to: "2031-12-31")
            == ["2026-11-02", "2028-11-02", "2030-11-02"])
    }

    @Test func countAndUntil() {
        // COUNT counts from the start, also before the range asked.
        #expect(days("FREQ=WEEKLY;COUNT=3", start: "2026-11-02", from: "2026-11-01", to: "2026-12-31")
            == ["2026-11-02", "2026-11-09", "2026-11-16"])
        #expect(days("FREQ=WEEKLY;COUNT=3", start: "2026-11-02", from: "2026-11-10", to: "2026-12-31") == ["2026-11-16"])
        #expect(days("FREQ=DAILY;COUNT=1", start: "2026-11-02", from: "2026-11-01", to: "2026-11-30") == ["2026-11-02"])
        // UNTIL is inclusive.
        #expect(days("FREQ=DAILY;UNTIL=20261105", start: "2026-11-02", from: "2026-11-01", to: "2026-11-30")
            == ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"])
        #expect(days("FREQ=DAILY", start: "2026-11-02", from: "2026-11-01", to: "2026-11-30", limit: 2) == ["2026-11-02", "2026-11-03"])
        let rule = RepeatRule("FREQ=MONTHLY;BYDAY=2TU")!
        #expect(rule.occurs(on: d("2026-12-08"), start: d("2026-11-10")))
        #expect(!rule.occurs(on: d("2026-12-15"), start: d("2026-11-10")))
    }
}

/// Changes shown on top of what the server said, before it answers.
struct ChoresSnapshotTests {
    private func snapshot() throws -> ChoresSnapshot {
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(ChoreModelTests.json.utf8))
        var days: [Day: [ChoreItem]] = [:]
        for day in CalendarMath.range(d("2026-11-01"), d("2026-11-14")) { days[day] = [] }
        let car = page.chores[1], bins = page.chores[0]
        days[d("2026-11-01")] = [ChoreItem(car, on: d("2026-11-01"))]
        // Bins: weekly from Tuesday 2026-10-20.
        for day in ["2026-11-03", "2026-11-10"] { days[d(day)] = [ChoreItem(bins, on: d(day))] }
        return ChoresSnapshot(page: page, days: days)
    }

    @Test func ticksOffAtOnce() throws {
        var s = try snapshot()
        #expect(s.overdue(today: d("2026-11-05")).map(\.choreId) == ["c2"])
        s.apply(.done(id: "c2", body: ChoreDoneBody(done: true)), me: "u1", today: d("2026-11-05"))
        #expect(s.items(on: d("2026-11-01")).first?.done == true)
        #expect(s.items(on: d("2026-11-01")).first?.doneBy?.id == "u1")
        #expect(s.page.chores[1].done && s.page.chores[1].next == nil)
        #expect(s.overdue(today: d("2026-11-05")).isEmpty)
        // A repeating chore's occurrence alone.
        s.apply(.done(id: "c1", body: ChoreDoneBody(done: true, day: d("2026-11-03"))), me: "u1", today: d("2026-11-05"))
        #expect(s.items(on: d("2026-11-03")).first?.done == true)
        #expect(s.items(on: d("2026-11-10")).first?.done == false)
        s.apply(.done(id: "c1", body: ChoreDoneBody(done: false, day: d("2026-11-03"))), me: "u1", today: d("2026-11-05"))
        #expect(s.items(on: d("2026-11-03")).first?.done == false)
    }

    @Test func aNewRepeatingChoreShowsOnItsDays() throws {
        var s = try snapshot()
        let input = ChoreInput(id: "new", title: "Plants", day: d("2026-11-02"), rrule: "FREQ=WEEKLY;BYDAY=MO,FR",
                               subscriberIds: ["u1"])
        s.apply(.create(id: "new", input: input), me: "u1", today: d("2026-11-02"))
        let on = CalendarMath.range(d("2026-11-01"), d("2026-11-14")).filter { day in
            s.items(on: day).contains { $0.choreId == "new" }
        }
        #expect(on.map(\.description) == ["2026-11-02", "2026-11-06", "2026-11-09", "2026-11-13"])
        let chore = try #require(s.page.chores.first { $0.id == "new" })
        #expect(chore.subscribed && chore.next == d("2026-11-02") && chore.isRepeating)
        // Beyond the agenda's days: worked out from the rule.
        #expect(s.items(on: d("2026-11-20")).contains { $0.choreId == "new" })
        #expect(!s.items(on: d("2026-11-21")).contains { $0.choreId == "new" })
        // A single one on its day, for someone.
        s.apply(.create(id: "one", input: ChoreInput(title: "Letter", assigneeId: "p1", day: d("2026-11-04"), time: "18:00")),
                me: "u1", today: d("2026-11-02"))
        let letter = try #require(s.items(on: d("2026-11-04")).first { $0.choreId == "one" })
        #expect(letter.assignee?.name == "Mia" && letter.part == .evening && !letter.subscribed)
    }

    @Test func anEditMovesItAndKeepsWhatWasTicked() throws {
        var s = try snapshot()
        s.apply(.done(id: "c1", body: ChoreDoneBody(done: true, day: d("2026-11-03"))), me: "u1", today: d("2026-11-02"))
        var input = ChoreInput(s.page.chores[0])
        input.title = "Bins out"
        s.apply(.update(id: "c1", input: input), me: "u1", today: d("2026-11-02"))
        let item = try #require(s.items(on: d("2026-11-03")).first { $0.choreId == "c1" })
        #expect(item.title == "Bins out" && item.done)
        // A single chore moved to another day.
        var car = ChoreInput(s.page.chores[1])
        car.day = d("2026-11-04")
        s.apply(.update(id: "c2", input: car), me: "u1", today: d("2026-11-02"))
        #expect(s.items(on: d("2026-11-01")).isEmpty)
        #expect(s.items(on: d("2026-11-04")).map(\.choreId) == ["c2"])
        // A chore deleted meanwhile stays deleted.
        s.apply(.update(id: "gone", input: car), me: "u1", today: d("2026-11-02"))
        #expect(!s.page.chores.contains { $0.id == "gone" })
    }

    @Test func deletesAndSubscribesAtOnce() throws {
        var s = try snapshot()
        s.apply(.subscribe(id: "c2", on: true), me: "u1", today: d("2026-11-02"))
        #expect(s.page.chores[1].subscribed && s.page.chores[1].subscriberIds == ["u1"])
        #expect(s.items(on: d("2026-11-01")).first?.subscribed == true)
        s.apply(.delete(id: "c1"), me: "u1", today: d("2026-11-02"))
        #expect(!s.page.chores.contains { $0.id == "c1" })
        #expect(s.items(on: d("2026-11-03")).isEmpty)
        #expect(!s.items(on: d("2026-11-17")).contains { $0.choreId == "c1" })
    }

    @Test func theQueueIsKeptAsJSON() throws {
        let queue: [ChoreChange] = [
            .create(id: "n1", input: ChoreInput(id: "n1", title: "T", assigneeId: "u1", day: d("2026-11-02"), time: "07:30",
                                                rrule: "FREQ=DAILY", subscriberIds: ["u1"])),
            .update(id: "c1", input: ChoreInput(title: "U", day: d("2026-11-03"), part: .evening)),
            .delete(id: "c2"),
            .done(id: "c1", body: ChoreDoneBody(done: true, day: d("2026-11-03"))),
            .done(id: "c3", body: ChoreDoneBody(done: false)),
            .subscribe(id: "c1", on: false),
        ]
        let back = try JSONDecoder().decode([ChoreChange].self, from: JSONEncoder().encode(queue))
        // The time decides the part, as sent.
        var expected = queue
        expected[0] = .create(id: "n1", input: ChoreInput(id: "n1", title: "T", assigneeId: "u1", day: d("2026-11-02"),
                                                          time: "07:30", part: .morning, rrule: "FREQ=DAILY", subscriberIds: ["u1"]))
        #expect(back == expected)
        // A new chore's POST carries its id; an edit's PATCH none.
        let post = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(queue[0].input!)) as? [String: Any])
        #expect(post["id"] as? String == "n1")
        let patch = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(queue[1].input!)) as? [String: Any])
        #expect(patch["id"] == nil)
    }
}

private extension ChoreChange {
    var input: ChoreInput? {
        switch self {
        case let .create(_, input), let .update(_, input): input
        default: nil
        }
    }
}

/// Answers the chores' requests as set and records them; nothing leaves the test.
nonisolated final class ChoresStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var answers: (page: Data?, agenda: Data?, write: Int, offline: Bool) = (nil, nil, 200, false)

    static var requests: [String] { lock.withLock { log } }
    /// The GETs' answers; nil: 503.
    static var page: Data? {
        get { lock.withLock { answers.page } }
        set { lock.withLock { answers.page = newValue } }
    }
    static var agenda: Data? {
        get { lock.withLock { answers.agenda } }
        set { lock.withLock { answers.agenda = newValue } }
    }
    /// The status of every change.
    static var writeStatus: Int {
        get { lock.withLock { answers.write } }
        set { lock.withLock { answers.write = newValue } }
    }
    /// No connection: every request fails.
    static var offline: Bool {
        get { lock.withLock { answers.offline } }
        set { lock.withLock { answers.offline = newValue } }
    }
    static func reset() { lock.withLock { log = []; answers = (nil, nil, 200, false) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.log.append("\(method) \(path)") }
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var status = 200
        var body = Data("{}".utf8)
        if method == "GET" {
            if let data = path.hasSuffix("/agenda") ? Self.agenda : Self.page { body = data } else { status = 503 }
        } else {
            status = Self.writeStatus
            if status >= 400 {
                body = Data(#"{"error":"No"}"#.utf8)
            } else if method != "DELETE" {
                body = Data(#"{"chore":{"id":"c9","title":"T","note":"","assignee":null,"day":"2026-11-01","time":null,"rrule":null,"done":false,"doneAt":null,"next":"2026-11-01","createdAt":"x","updatedAt":"x"}}"#.utf8)
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The store: what's on the device shows at once, changes too; they're kept on the device and
/// sent when the server can be reached; the server wins.
@Suite(.serialized)
@MainActor
struct ChoresStoreTests {
    private let today = Day.today

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ohana-chores-\(UUID().uuidString)")
    }

    private func api(cache: ResponseCache? = nil) -> FamilyAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChoresStubProtocol.self]
        return FamilyAPI(client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil,
                                           session: URLSession(configuration: config), cache: cache), familyID: "f1")
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Ben's daily dishes and a single chore today, as the server answers them.
    private func answers(canEdit: Bool = true) throws -> (page: Data, agenda: Data) {
        let ben = ChorePerson(id: "u1", name: "Ben", account: true)
        let dishes = Chore(id: "dishes", title: "Dishes", note: "", assignee: ben, day: today.adding(days: -40), time: nil,
                           rrule: "FREQ=DAILY", done: false, doneAt: nil, next: today, createdAt: "x", updatedAt: "x")
        let car = Chore(id: "car", title: "Car", note: "", assignee: nil, day: today, time: nil, rrule: nil, done: false,
                        doneAt: nil, next: today, createdAt: "x", updatedAt: "x")
        let page = ChoresPage(chores: [dishes, car], people: [ben], canEdit: canEdit)
        let window = ChoreAgenda.window(around: today, today: today)
        let days = CalendarMath.range(window.from, window.to).map { day in
            ChoreAgenda.DayItems(date: day, items: [ChoreItem(dishes, on: day)] + (day == today ? [ChoreItem(car, on: day)] : []))
        }
        return (try JSONEncoder().encode(page), try JSONEncoder().encode(ChoreAgenda(days: days)))
    }

    /// A store whose copies on the device are the server's answers.
    private func store(_ directory: URL, canEdit: Bool = true, queueFile: URL? = nil) throws -> ChoresStore {
        let cache = ResponseCache(directory: directory.appending(path: "responses"))
        let api = api(cache: cache)
        let (page, agenda) = try answers(canEdit: canEdit)
        cache.write(page, for: ChoresStore.pageRequest(api).key)
        cache.write(agenda, for: ChoresStore.agendaRequest(api, around: today).key)
        ResponseCache.waitForWrites()
        let store = ChoresStore(api: api, canEdit: canEdit, queueFile: queueFile)
        store.me = "u1"
        return store
    }

    private func item(_ store: ChoresStore, _ id: String) -> ChoreItem? {
        store.items(on: today).first { $0.choreId == id }
    }

    @Test func offlineChangesShowAtOnceAreKeptAndSentLater() async throws {
        ChoresStubProtocol.reset()
        ChoresStubProtocol.offline = true
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueFile = directory.appending(path: "queue/queue.json")
        let first = try store(directory, queueFile: queueFile)
        // The copy on the device at once.
        #expect(first.phase == .loaded && first.page?.chores.count == 2)
        let dishes = try #require(item(first, "dishes"))
        #expect(!dishes.done)

        first.toggleDone(dishes)
        let id = first.save(ChoreInput(title: "Plants", day: today))
        first.subscribe("car", true)
        #expect(item(first, "dishes")?.done == true)
        #expect(item(first, id)?.title == "Plants")
        #expect(item(first, "car")?.subscribed == true)
        #expect(FileManager.default.fileExists(atPath: queueFile.path()))
        #expect(await until { ChoresStubProtocol.requests.contains { $0.hasPrefix("POST") } })
        #expect(first.pending)

        // The app quit and starts again: the changes show on top of the copy.
        let second = try store(directory, queueFile: queueFile)
        #expect(item(second, "dishes")?.done == true)
        #expect(item(second, id)?.title == "Plants")
        #expect(item(second, "car")?.subscribed == true)

        // Online again: sent in order, the file removed.
        ChoresStubProtocol.offline = false
        (ChoresStubProtocol.page, ChoresStubProtocol.agenda) = try answers()
        second.retryNow()
        #expect(await until { !second.pending })
        #expect(!FileManager.default.fileExists(atPath: queueFile.path()))
        let writes = ChoresStubProtocol.requests.filter { !$0.hasPrefix("GET") }.suffix(3)
        #expect(Array(writes) == ["POST /api/v1/families/f1/chores/dishes/done", "POST /api/v1/families/f1/chores",
                                  "POST /api/v1/families/f1/chores/car/subscribe"])
        first.retryNow()
        #expect(await until { !first.pending })
    }

    @Test func aRefusalDropsTheChangeAndLoadsAgain() async throws {
        ChoresStubProtocol.reset()
        ChoresStubProtocol.writeStatus = 400
        (ChoresStubProtocol.page, ChoresStubProtocol.agenda) = try answers()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueFile = directory.appending(path: "queue.json")
        let store = try store(directory, queueFile: queueFile)
        store.toggleDone(try #require(item(store, "car")))
        #expect(item(store, "car")?.done == true)
        // The server wins: dropped, also from the device, and the chores asked again.
        #expect(await until { !store.pending && self.item(store, "car")?.done == false })
        #expect(!FileManager.default.fileExists(atPath: queueFile.path()))
        #expect(await until { ChoresStubProtocol.requests.contains("GET /api/v1/families/f1/chores") })
    }

    @Test func aNetworkFailureKeepsTheChange() async throws {
        ChoresStubProtocol.reset()
        ChoresStubProtocol.offline = true
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueFile = directory.appending(path: "queue.json")
        let store = try store(directory, queueFile: queueFile)
        store.delete("car")
        #expect(item(store, "car") == nil)
        #expect(await until { ChoresStubProtocol.requests.contains("DELETE /api/v1/families/f1/chores/car") })
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.pending && item(store, "car") == nil)
        #expect(FileManager.default.fileExists(atPath: queueFile.path()))
        // A refresh while offline keeps what's on the device.
        await store.refresh()
        #expect(store.page?.chores.map(\.id) == ["dishes"])
        ChoresStubProtocol.offline = false
        store.retryNow()
        #expect(await until { !store.pending })
    }

    @Test func aCreateTheServerAlreadyHasCountsAsDone() async throws {
        ChoresStubProtocol.reset()
        ChoresStubProtocol.writeStatus = 409
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(directory)
        let id = store.save(ChoreInput(title: "Plants", day: today))
        #expect(await until { !store.pending })
        // Not dropped: it stays while the server can't be asked for its chores.
        #expect(store.chore(id)?.title == "Plants")
        #expect(ChoresStubProtocol.requests.contains("POST /api/v1/families/f1/chores"))
    }

    @Test func viewersOnlyTickTheirOwnAndSubscribe() async throws {
        ChoresStubProtocol.reset()
        ChoresStubProtocol.offline = true
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store(directory, canEdit: false)
        #expect(!store.canEdit)
        store.save(ChoreInput(title: "Plants", day: today))
        store.delete("car")
        store.toggleDone(try #require(item(store, "car")))
        #expect(!store.pending && store.page?.chores.count == 2 && item(store, "car")?.done == false)
        // Ben's own, and his notification.
        store.toggleDone(try #require(item(store, "dishes")))
        store.subscribe("car", true)
        #expect(item(store, "dishes")?.done == true && item(store, "car")?.subscribed == true)
        #expect(store.pending)
        ChoresStubProtocol.offline = false
        store.retryNow()
        #expect(await until { !store.pending })
    }
}

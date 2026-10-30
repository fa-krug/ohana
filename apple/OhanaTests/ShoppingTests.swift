import Foundation
import Testing
@testable import Ohana

struct ShoppingTests {
    /// GET /meals/shopping as web/lib/meals/app-routes-plan.ts answers it.
    static let overviewJSON = """
    {"lists":[{"id":"l2","iterationId":"it","iterationStatus":"ACTIVE","shoppingDate":"2026-11-05","itemCount":3,"checkedCount":0},{"id":"l1","iterationId":"it","iterationStatus":"ACTIVE","shoppingDate":"2026-11-02","itemCount":4,"checkedCount":1}],"latest":{"id":"l1","shoppingDate":"2026-11-02","createdAt":"2026-10-30T02:44:46.000Z","items":[{"id":"a","ingredientName":"Tomato","category":"PRODUCE","quantity":"100","unitAbbreviation":"g","isChecked":true},{"id":"b","ingredientName":"Zucchini","category":"PRODUCE","quantity":"2.5","unitAbbreviation":"Stk","isChecked":false},{"id":"c","ingredientName":"Milk","category":"DAIRY","quantity":"1","unitAbbreviation":"l","isChecked":false},{"id":"d","ingredientName":"Saffron","category":"SPICES","quantity":"0.333","unitAbbreviation":"g","isChecked":false}]}}
    """

    static let spentJSON = """
    {"currency":"EUR","category":{"id":"groceries","name":"Groceries","icon":"🛒","color":"#f97316"},"from":"2026-11-04","to":"2026-11-06","transactions":[{"id":"t1","date":"2026-11-05","payee":"Rewe","description":"","amountCents":-2350}],"totalCents":2350}
    """

    static func list() throws -> ShoppingList {
        try #require(try JSONDecoder().decode(ShoppingOverview.self, from: Data(overviewJSON.utf8)).latest)
    }

    @Test func decodesTheOverview() throws {
        let overview = try JSONDecoder().decode(ShoppingOverview.self, from: Data(Self.overviewJSON.utf8))
        #expect(overview.lists.map(\.id) == ["l2", "l1"])
        #expect(overview.lists[1].checkedCount == 1)
        #expect(overview.latest?.shoppingDate == Day("2026-11-02"))
        #expect(overview.latest?.items.count == 4)
        let empty = try JSONDecoder().decode(ShoppingOverview.self, from: Data(#"{"lists":[],"latest":null}"#.utf8))
        #expect(empty.latest == nil)
    }

    @Test func decodesTheSpend() throws {
        let spend = try JSONDecoder().decode(ShoppingSpend.self, from: Data(Self.spentJSON.utf8))
        #expect(spend.category?.name == "Groceries")
        #expect(spend.transactions.first?.amountCents == -2350)
        #expect(spend.from == Day("2026-11-04"))
        #expect(spend.totalCents == 2350)
        let none = #"{"currency":"EUR","category":null,"from":"2026-11-04","to":"2026-11-06","transactions":[],"totalCents":0}"#
        #expect(try JSONDecoder().decode(ShoppingSpend.self, from: Data(none.utf8)).category == nil)
    }

    @Test func groupsByAisleWithOpenItemsFirst() throws {
        let groups = ShoppingGrouping.groups(try Self.list().items)
        #expect(groups.map(\.category) == [.produce, .dairy, .other]) // unknown categories go to Other
        #expect(groups[0].items.map(\.id) == ["b", "a"])
        #expect(groups[0].checkedCount == 1)
        #expect(groups[2].items.map(\.id) == ["d"])
    }

    @Test func formatsQuantities() {
        let en = Locale(identifier: "en_US")
        #expect(ShoppingQuantity.format("100", locale: en) == "100")
        #expect(ShoppingQuantity.format("100.00", locale: en) == "100")
        #expect(ShoppingQuantity.format("2.5", locale: en) == "2.5")
        #expect(ShoppingQuantity.format("0.333", locale: en) == "0.33")
        #expect(ShoppingQuantity.format("1500", locale: en) == "1500")
        #expect(ShoppingQuantity.format("2.5", locale: Locale(identifier: "de_DE")) == "2,5")
        #expect(ShoppingQuantity.format("lots", locale: en) == "lots")
    }

    @Test func exportsWhatIsLeftToBuy() throws {
        let text = ShoppingExport.text(for: try Self.list(), locale: Locale(identifier: "en_US"))
        #expect(text.contains("• 2.5 Stk Zucchini"))
        #expect(text.contains("• 1 l Milk"))
        #expect(!text.contains("Tomato")) // ticked off
        #expect(text.components(separatedBy: "\n").count == 10) // title, 3 × (blank, aisle, item)
    }

    @Test func tellsOfflineFromAServerThatDoesntAnswer() {
        typealias S = ShoppingSyncStatus
        #expect(S.current(isOnline: false, waiting: true, savedCopy: false, sending: false) == .offline)
        #expect(S.current(isOnline: false, waiting: false, savedCopy: true, sending: false) == .offline)
        #expect(S.current(isOnline: true, waiting: true, savedCopy: false, sending: false) == .serverUnreachable)
        #expect(S.current(isOnline: true, waiting: false, savedCopy: true, sending: true) == .serverUnreachable)
        #expect(S.current(isOnline: true, waiting: false, savedCopy: false, sending: true) == .syncing)
        #expect(S.current(isOnline: true, waiting: false, savedCopy: false, sending: false) == nil)
    }

    @Test func encodesTheTick() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShoppingSetInput(itemId: "a", checked: true))) as? [String: Any]
        #expect(body?["kind"] as? String == "set")
        #expect(body?["itemId"] as? String == "a")
        #expect(body?["checked"] as? Bool == true)
    }
}

/// Records what the queue sends and fails as told.
@MainActor
final class ShoppingFakeServer {
    var sent: [(String, Bool)] = []
    var failures: [any Error] = []

    func send(_ id: String, _ checked: Bool) async throws {
        sent.append((id, checked))
        if !failures.isEmpty { throw failures.removeFirst() }
    }
}

@MainActor
struct ShoppingTickQueueTests {
    static let item = ShoppingItem(id: "a", ingredientName: "Tomato", category: "PRODUCE", quantity: "1",
                                   unitAbbreviation: "Stk", isChecked: false)

    func queue(_ server: ShoppingFakeServer) -> ShoppingTickQueue {
        let queue = ShoppingTickQueue { id, checked in try await server.send(id, checked) }
        queue.retryDelay = { _ in .seconds(3600) } // retries only when the test says so
        return queue
    }

    @Test func showsATickAtOnceAndSendsIt() async {
        let server = ShoppingFakeServer()
        let queue = queue(server)
        queue.set("a", checked: true)
        #expect(queue.isChecked(Self.item)) // before anything was sent
        await queue.flush()
        #expect(server.sent.count == 1 && server.sent[0] == ("a", true))
        #expect(queue.pending.isEmpty)
        // Still shown ticked until fresh data arrives; then the server's state counts.
        #expect(queue.isChecked(Self.item))
        queue.reconcile()
        var fresh = Self.item
        fresh.isChecked = true
        #expect(queue.apply(to: [fresh]).first?.isChecked == true)
    }

    @Test func keepsTicksWhileOfflineAndRetries() async {
        let server = ShoppingFakeServer()
        server.failures = [APIError.transport("The Internet connection appears to be offline.")]
        let queue = queue(server)
        queue.set("a", checked: true)
        await queue.flush()
        #expect(queue.pending == ["a": true])
        #expect(queue.isWaiting)
        #expect(queue.isChecked(Self.item))
        // Unticked again while offline: only the latest wish is sent.
        queue.set("a", checked: false)
        await queue.flush()
        #expect(server.sent.map(\.1) == [true, false])
        #expect(queue.pending.isEmpty)
        #expect(!queue.isWaiting)
        #expect(!queue.isChecked(Self.item))
    }

    @Test func dropsATickTheServerRefuses() async {
        let server = ShoppingFakeServer()
        server.failures = [APIError.http(status: 404, message: "Item not found")]
        let queue = queue(server)
        var rejected: [String] = []
        queue.onRejected = { id, _ in rejected.append(id) }
        queue.set("a", checked: true)
        await queue.flush()
        #expect(rejected == ["a"])
        #expect(queue.pending.isEmpty)
        #expect(!queue.isChecked(Self.item)) // back to the server's state
    }

    @Test func tellsRetryableErrors() {
        #expect(ShoppingTickQueue.isRetryable(APIError.transport("offline")))
        #expect(ShoppingTickQueue.isRetryable(URLError(.notConnectedToInternet)))
        #expect(ShoppingTickQueue.isRetryable(APIError.http(status: 503, message: nil)))
        #expect(ShoppingTickQueue.isRetryable(APIError.http(status: 429, message: nil)))
        #expect(!ShoppingTickQueue.isRetryable(APIError.http(status: 403, message: nil)))
        #expect(!ShoppingTickQueue.isRetryable(APIError.decoding("x")))
    }
}

/// The ticks and lists kept on the device (`ShoppingOfflineStore`): they survive a restart.
@MainActor
struct ShoppingOfflineTests {
    static func store() -> ShoppingOfflineStore {
        ShoppingOfflineStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "ohana-shopping-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test func keepsUnsentTicksAcrossARestart() async {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let offline = ShoppingFakeServer()
        offline.failures = [APIError.transport("offline"), APIError.transport("offline")]
        let first = ShoppingTickQueue(store: store) { id, checked in try await offline.send(id, checked) }
        first.retryDelay = { _ in .seconds(3600) }
        first.set("a", checked: true)
        first.set("b", checked: false)
        await first.flush()
        #expect(store.loadTicks() == ["a": true, "b": false])

        // The app starts again: the queue picks the ticks up and sends them.
        let online = ShoppingFakeServer()
        let second = ShoppingTickQueue(store: store) { id, checked in try await online.send(id, checked) }
        #expect(second.pending == ["a": true, "b": false])
        #expect(second.isChecked(ShoppingTickQueueTests.item))
        await second.flush()
        #expect(Set(online.sent.map(\.0)) == ["a", "b"])
        #expect(second.pending.isEmpty)
        #expect(store.loadTicks().isEmpty)
    }

    @Test func forgetsATickTheServerRefused() async {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let server = ShoppingFakeServer()
        server.failures = [APIError.http(status: 404, message: "gone")]
        let queue = ShoppingTickQueue(store: store) { id, checked in try await server.send(id, checked) }
        queue.set("a", checked: true)
        await queue.flush()
        #expect(store.loadTicks().isEmpty)
    }

    @Test func keepsTheListsForOffline() throws {
        let store = Self.store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.loadOverview() == nil)
        let overview = try JSONDecoder().decode(ShoppingOverview.self, from: Data(ShoppingTests.overviewJSON.utf8))
        store.saveOverview(overview)
        let saved = try #require(store.loadOverview())
        #expect(saved.lists.map(\.id) == ["l2", "l1"])
        #expect(saved.latest?.items.count == 4)
        // The latest list is kept on its own too.
        #expect(store.loadList("l1")?.shoppingDate == Day("2026-11-02"))
        #expect(store.loadList("l2") == nil)

        store.saveList(ShoppingList(id: "l2", shoppingDate: Day("2026-11-05"), createdAt: nil, items: []))
        #expect(store.loadList("l2")?.items.isEmpty == true)
        store.prune(keeping: ["l2"])
        #expect(store.loadList("l1") == nil)
        #expect(store.loadList("l2") != nil)
        #expect(store.loadOverview() != nil)
    }

    @Test func namesTheFolderSafely() {
        #expect(ShoppingOfflineStore.safe("ohana.example.com_ab/c d") == "ohana.example.com_ab-c-d")
    }
}

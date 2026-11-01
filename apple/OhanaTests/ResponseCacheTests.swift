import Foundation
import SwiftUI
import Testing
@testable import Ohana

/// The copies of GET answers kept on the device and the screens' `LoadState` around them.
@MainActor
struct ResponseCacheTests {
    private struct Plan: Codable, Equatable {
        let name: String
    }

    private func cache() -> ResponseCache {
        ResponseCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "ohana-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// A client of `host` whose answers `CacheStubProtocol` gives.
    private func client(_ host: String, cache: ResponseCache?) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CacheStubProtocol.self]
        return APIClient(baseURL: URL(string: "https://\(host)")!, token: nil,
                         session: URLSession(configuration: config), cache: cache)
    }

    /// `run` with a state kept in a box, as a view's `@State` would.
    private final class Box<Value> {
        var state: LoadState<Value> = .idle
        var binding: Binding<LoadState<Value>> {
            Binding(get: { self.state }, set: { self.state = $0 })
        }
    }

    @Test func keepsWhatTheServerAnsweredAndClearsIt() async throws {
        let cache = cache()
        let api = FamilyAPI(client: client("keep.example", cache: cache), familyID: "f1")
        CacheStubProtocol.answer("keep.example", status: 200, body: #"{"name":"Week 1"}"#)
        let get = api.cached("/meals/plan", as: Plan.self)
        #expect(get.saved() == nil)
        #expect(try await get.fetch() == Plan(name: "Week 1"))
        ResponseCache.waitForWrites()
        #expect(get.saved()?.value == Plan(name: "Week 1"))
        // Another query is another copy; a key files it under one.
        #expect(api.cached("/meals/plan", query: ["lang": "de"], as: Plan.self).saved() == nil)
        cache.clear()
        #expect(get.saved() == nil)
    }

    @Test func aKeyFilesTheCopyWithoutTheQuery() async throws {
        let api = FamilyAPI(client: client("key.example", cache: cache()), familyID: "f1")
        CacheStubProtocol.answer("key.example", status: 200, body: #"{"name":"Today"}"#)
        _ = try await api.cached("/overview", query: ["today": "2026-10-31"], key: "/overview", as: Plan.self).fetch()
        ResponseCache.waitForWrites()
        let tomorrow = api.cached("/overview", query: ["today": "2026-11-01"], key: "/overview", as: Plan.self)
        #expect(tomorrow.saved()?.value == Plan(name: "Today"))
    }

    @Test func theDemoKeepsNothing() {
        let api = FamilyAPI(client: APIClient(demo: DemoServer()), familyID: "demo")
        #expect(api.cached("/meals/plan", as: Plan.self).saved() == nil)
    }

    @Test func showsTheCopyAndKeepsItWhileTheServerIsDown() async throws {
        let cache = cache()
        let api = FamilyAPI(client: client("down.example", cache: cache), familyID: "f1")
        CacheStubProtocol.answer("down.example", status: 200, body: #"{"name":"Saved"}"#)
        _ = try await api.cached("/meals/plan", as: Plan.self).fetch()
        ResponseCache.waitForWrites()

        CacheStubProtocol.answer("down.example", status: 503, body: #"{"error":"down"}"#)
        let box = Box<Plan>()
        await LoadState.run(box.binding, api.cached("/meals/plan"))
        guard case let .saved(plan, _, updating) = box.state else {
            Issue.record("Expected the saved copy, got \(box.state)")
            return
        }
        #expect(plan == Plan(name: "Saved"))
        #expect(!updating)
        #expect(box.state.isSaved)

        // Back up: the server's answer replaces the copy.
        CacheStubProtocol.answer("down.example", status: 200, body: #"{"name":"Fresh"}"#)
        await LoadState.run(box.binding, api.cached("/meals/plan"))
        #expect(box.state.value == Plan(name: "Fresh"))
        #expect(!box.state.isSaved)
    }

    @Test func aRefusalDropsTheCopy() async throws {
        let api = FamilyAPI(client: client("gone.example", cache: cache()), familyID: "f1")
        CacheStubProtocol.answer("gone.example", status: 200, body: #"{"name":"Saved"}"#)
        _ = try await api.cached("/meals/plan", as: Plan.self).fetch()
        ResponseCache.waitForWrites()

        CacheStubProtocol.answer("gone.example", status: 404, body: #"{"error":"Not found"}"#)
        let box = Box<Plan>()
        await LoadState.run(box.binding, api.cached("/meals/plan"))
        guard case let .failed(message) = box.state else {
            Issue.record("Expected a failure, got \(box.state)")
            return
        }
        #expect(message == "Not found")
    }

    @Test func withoutACopyItLoadsAsBefore() async {
        let api = FamilyAPI(client: client("none.example", cache: cache()), familyID: "f1")
        CacheStubProtocol.answer("none.example", status: 503, body: #"{"error":"down"}"#)
        let box = Box<Plan>()
        await LoadState.run(box.binding, api.cached("/meals/plan"))
        guard case .failed = box.state else {
            Issue.record("Expected a failure, got \(box.state)")
            return
        }
    }

    @Test func aTransformAppliesToTheCopyToo() async throws {
        let api = FamilyAPI(client: client("map.example", cache: cache()), familyID: "f1")
        CacheStubProtocol.answer("map.example", status: 200, body: #"{"name":"Soup"}"#)
        _ = try await api.cached("/meals/recipes/r1", as: Plan.self).fetch()
        ResponseCache.waitForWrites()

        CacheStubProtocol.answer("map.example", status: 503, body: "")
        let box = Box<String>()
        await LoadState.run(box.binding, api.cached("/meals/recipes/r1", as: Plan.self)) { $0.name.uppercased() }
        #expect(box.state.value == "SOUP")
        #expect(box.state.isSaved)
    }

    /// The prefetch asks what the screens ask: with the server down afterwards, each screen's own
    /// load shows the copy it left.
    @Test func aPrefetchFillsTheCopiesTheScreensFind() async throws {
        let host = "prefetch.example"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DemoStubProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://\(host)")!, token: nil,
                               session: URLSession(configuration: config), cache: cache())
        let api = FamilyAPI(client: client, familyID: DemoServer.familyID)
        let family = FamilyContext(family: FamilySummary(id: DemoServer.familyID, name: "Demo", role: .editor,
                                                         memberCount: 1), api: api)

        let answered = await Prefetch.load(family)
        ResponseCache.waitForWrites()
        DemoStubProtocol.setDown(host, true)
        defer { DemoStubProtocol.setDown(host, false) }

        let overview = Box<OverviewDashboard>()
        await LoadState.run(overview.binding, OverviewView.request(api))
        #expect(overview.state.isSaved)

        let plan = Box<MealPlanResponse>()
        await LoadState.run(plan.binding, MealPlanView.request(api))
        #expect(plan.state.isSaved)
        let recipes = Set(plan.state.value?.plan?.activeIteration?.entries.map(\.recipeId) ?? [])
        #expect(!recipes.isEmpty)
        // Every request answered: each screen's and the plan's recipes.
        #expect(answered == Prefetch.jobs(family).count + recipes.count)
        for id in recipes {
            #expect(MealsRecipeDetailView.request(api, recipeID: id).saved() != nil, "recipe \(id)")
        }

        let list = RecipeListModel()
        await list.reload(api, RecipeListModel.opening)
        #expect(list.saved != nil)
        #expect(!list.items.isEmpty)
        #expect(RecipeTagsView.request(api).saved() != nil)

        // The calendar asks as its store does (`CalendarStore.load`).
        let calendar = CalendarStore(api: api, readOnly: false)
        await calendar.load()
        #expect(calendar.savedCopy != nil)

        let finance = FinanceStore(family: family)
        await finance.loadOverview()
        await finance.loadList()
        await finance.loadBalances()
        await finance.loadSummary()
        #expect(finance.overviewCopy != nil)
        #expect(finance.listCopy != nil)
        #expect(finance.balancesCopy != nil)
        #expect(finance.summaryCopy != nil)
        #expect(finance.comparisons != nil)

        #expect(AppointmentsView.request(api).saved() != nil)
        #expect(AssistantChatStore.chatsRequest(api).saved() != nil)
        let settings = FamilySettingsModel()
        await settings.load(api)
        #expect(settings.state.isSaved)
    }

    @Test func noPrefetchInTheDemo() {
        let api = FamilyAPI(client: APIClient(demo: DemoServer()), familyID: DemoServer.familyID)
        let family = FamilyContext(family: FamilySummary(id: DemoServer.familyID, name: "Demo", role: .viewer,
                                                         memberCount: 1), api: api)
        let prefetcher = Prefetcher()
        prefetcher.start(family)
        #expect(!prefetcher.isRunning)
    }
}

/// Answers like the demo (`DemoServer`: the family "demo"), so a prefetch meets real answers on
/// every path; a host set down answers 503.
nonisolated final class DemoStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var down: Set<String> = []

    static func setDown(_ host: String, _ isDown: Bool) {
        lock.withLock { if isDown { down.insert(host) } else { down.remove(host) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        nonisolated(unsafe) let this = self
        let request = request
        let isDown = Self.lock.withLock { Self.down.contains(request.url?.host() ?? "") }
        Task { @MainActor in
            var (data, response) = DemoServer().respond(to: request)
            if isDown {
                data = Data(#"{"error":"down"}"#.utf8)
                response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            }
            this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
            this.client?.urlProtocol(this, didLoad: data)
            this.client?.urlProtocolDidFinishLoading(this)
        }
    }
    override func stopLoading() {}
}

/// Answers every request of a host with what `answer` set for it (one host per test, as the
/// tests run side by side).
nonisolated final class CacheStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: (Int, Data)] = [:]

    static func answer(_ host: String, status: Int, body: String) {
        lock.withLock { answers[host] = (status, Data(body.utf8)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.lock.withLock { Self.answers[request.url?.host() ?? ""] } ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

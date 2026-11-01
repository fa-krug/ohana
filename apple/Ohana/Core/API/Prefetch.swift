import Foundation

/// Loads the selected family's main screens in the background, so their copies on the device
/// (`ResponseCache`, the shopping lists' `ShoppingOfflineStore`) are there before they're opened,
/// offline too. The app model starts it once the server answered, when the family changes and
/// when the connection comes back; at most every `interval` per family, never in the demo nor in
/// Low Data Mode. A new family or server stops the one under way.
final class Prefetcher {
    /// How long a family's prefetch counts as fresh.
    static var interval: TimeInterval = 15 * 60
    /// The pause before it starts, so the screen on show loads first.
    static var delay = Duration.seconds(3)

    private var task: Task<Void, Never>?
    /// The server and family under way.
    private var running: String?
    /// When each server's family was last loaded (some answer came).
    private var loaded: [String: Date] = [:]

    var isRunning: Bool { running != nil }

    /// Loads `family` unless it's under way or was loaded lately; another family's prefetch stops.
    func start(_ family: FamilyContext) {
        let client = family.api.client
        guard !client.isDemo, client.cache != nil else { return }
        let key = "\(client.baseURL.absoluteString)|\(family.api.familyID)"
        guard running != key else { return }
        cancel()
        let connectivity = Connectivity.shared
        guard connectivity.isOnline, !connectivity.isConstrained else { return }
        if let last = loaded[key], Date().timeIntervalSince(last) < Self.interval { return }
        running = key
        task = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            let answered = await Prefetch.load(family)
            guard !Task.isCancelled, let self else { return }
            if answered > 0 { loaded[key] = Date() }
            running = nil
        }
    }

    /// Stops what's under way (the server or family changed).
    func cancel() {
        task?.cancel()
        task = nil
        running = nil
    }
}

/// What the prefetch loads: each module's main GETs, the way its screen asks for them (the
/// screens' `request` builders), so the screen finds the copy. Quiet: a failure is skipped, the
/// screen asks again when it opens. Only modules the server has on.
enum Prefetch {
    /// One request, and those its answer leads to (the plan's recipes).
    struct Job: Sendable {
        let run: @MainActor () async throws -> [Job]
    }

    /// Requests at a time.
    static let width = 3
    /// The most recipes of the plan loaded ahead.
    static let maxRecipes = 30

    /// Loads `family`'s screens; the number of requests answered.
    @discardableResult
    static func load(_ family: FamilyContext) async -> Int {
        await run(jobs(family))
    }

    static func jobs(_ family: FamilyContext) -> [Job] {
        let api = family.api
        var jobs: [Job] = [
            fetch(OverviewView.request(api)),
            // As `CalendarStore.load` asks for the year it opens on.
            fetch(api.cached("", query: ["year": String(CalendarStore.lastYear ?? Day.today.year)],
                             as: CalendarState.self)),
        ]
        if family.isEnabled(.meals) {
            jobs += [
                Job { try await planRecipes(api, MealPlanView.request(api).fetch()) },
                fetch(RecipeListModel.firstPage(api, RecipeListModel.opening, limit: RecipeListModel.pageSize)),
                fetch(RecipeTagsView.request(api)),
                fetch(RecipeListModel.statusRequest(api)),
                Job { _ = try await RecipeCatalogCache.load(api); return [] },
                Job { try await shopping(api); return [] },
                // As the shopping page asks, for adding items offline.
                fetch(api.cached("/meals/shopping/units", as: ShoppingUnitsResponse.self)),
            ]
        }
        if family.isEnabled(.finance) { jobs += finance(api) }
        if family.isEnabled(.appointments) { jobs.append(fetch(AppointmentsView.request(api))) }
        if family.isEnabled(.assistant) {
            jobs += [fetch(AssistantChatStore.chatsRequest(api)), fetch(AssistantChatStore.settingsRequest(api))]
        }
        jobs.append(fetch(FamilySettingsModel.request(api)))
        return jobs
    }

    /// Runs `jobs` and those they lead to, `width` at a time, until done or cancelled; the number
    /// that succeeded.
    static func run(_ jobs: [Job]) async -> Int {
        var waiting = jobs
        var answered = 0
        await withTaskGroup(of: [Job]?.self) { group in
            var running = 0
            while true {
                while running < width, !waiting.isEmpty, !Task.isCancelled {
                    let job = waiting.removeFirst()
                    group.addTask(priority: .utility) { try? await job.run() }
                    running += 1
                }
                guard let result = await group.next() else { break }
                running -= 1
                if let more = result {
                    answered += 1
                    waiting += more
                }
            }
        }
        return answered
    }

    private static func fetch<Value>(_ get: CachedGet<Value>) -> Job {
        Job { _ = try await get.fetch(); return [] }
    }

    /// The recipes of the plan's active iteration, so they can be cooked offline.
    private static func planRecipes(_ api: FamilyAPI, _ response: MealPlanResponse) -> [Job] {
        var seen = Set<String>()
        let ids = (response.plan?.activeIteration?.entries ?? []).map(\.recipeId).filter { seen.insert($0).inserted }
        return ids.prefix(maxRecipes).map { fetch(MealsRecipeDetailView.request(api, recipeID: $0)) }
    }

    /// What the finance page starts with (`FinanceStore.reloadAll`): this month, no filter, the
    /// first page, the balances and the summary with its comparisons.
    private static func finance(_ api: FamilyAPI) -> [Job] {
        let period = FinancePeriod.current()
        var jobs = [
            fetch(FinanceStore.overviewRequest(api)),
            fetch(FinanceStore.listRequest(api, FinanceStore.listQuery(period, FinanceFilter(), limit: FinanceStore.page))),
        ]
        if let at = period.balanceDay() { jobs.append(fetch(FinanceStore.balancesRequest(api, at: at))) }
        jobs += FinanceStore.summaryQueries(period).map { fetch(FinanceStore.summaryRequest(api, $0)) }
        return jobs
    }

    /// The shopping overview and its latest list into the lists' own store, as
    /// `ShoppingListsView` and its list page keep them. Not while ticks or added items wait to be
    /// sent, nor when one went through meanwhile: the answer may not have it.
    private static func shopping(_ api: FamilyAPI) async throws {
        let queue = ShoppingTickQueue.for(api)
        func settled() -> Bool { queue.pending.isEmpty && queue.pendingAdds.isEmpty }
        guard settled() else { return }
        let (confirmed, adds) = (queue.confirmed, queue.addsSettled)
        // As `ShoppingListsView.load` asks.
        let overview = try await api.get("/meals/shopping", query: ["lang": MealPlanLanguage.current],
                                         as: ShoppingOverview.self)
        guard settled(), queue.confirmed == confirmed, queue.addsSettled == adds else { return }
        let store = ShoppingOfflineStore(api: api)
        store.saveOverview(overview)
        if let latest = overview.latest { store.saveList(latest) }
        store.prune(keeping: Set(overview.lists.map(\.id)))
    }
}

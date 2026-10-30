import Foundation
import Observation

/// What the transaction list is filtered by (finance-store.ts Filter).
struct FinanceFilter: Hashable {
    enum Kind: String, CaseIterable, Hashable, Identifiable {
        case all = "", income, expense, transfer
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "In and out")
            case .income: String(localized: "Income")
            case .expense: String(localized: "Expenses")
            case .transfer: String(localized: "Transfers")
            }
        }
    }

    var q = ""
    /// "" = all, "none" = uncategorized, else a category id (with its subcategories).
    var category = ""
    /// "" = all, "none" = without an account, else an account id.
    var account = ""
    var kind = Kind.all

    var isActive: Bool { activeCount > 0 }
    /// How many of account, category and kind narrow the list (the filter menu's badge).
    var activeCount: Int { [!category.isEmpty, !account.isEmpty, kind != .all].filter { $0 }.count }
}

/// The accounts' balances (by id) at the end of the day `at`.
struct FinanceBalances: Hashable {
    var at: String
    var cents: [String: Int]
}

/// A message at the bottom of the page; with `undo`, the ops that revert what it reports.
struct FinanceToast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undo: [JSONValue]?
    /// Its entry in the window's undo manager (Edit → Undo), removed when the toast undoes it.
    var undoToken: FinanceUndoToken?
}

/// The target of one change's entry in the undo manager, so the toast can remove just that one.
final class FinanceUndoToken: Equatable {
    static func == (a: FinanceUndoToken, b: FinanceUndoToken) -> Bool { a === b }
}

/// The finance page's entries in the window's undo manager (Edit → Undo / Redo, ⌘Z / ⇧⌘Z):
/// each change's inverse ops. Undoing one registers the ops that revert the undo as its redo,
/// and redoing that registers the next undo.
final class FinanceUndoRegistry {
    private(set) weak var manager: UndoManager?
    /// Applies ops (`redoing`: from Redo); returns the ops that revert them, nil on failure.
    var apply: (_ ops: [JSONValue], _ redoing: Bool) async -> [JSONValue]? = { _, _ in nil }
    /// An entry was undone or redone from the menu (its toast goes away).
    var used: (FinanceUndoToken) -> Void = { _ in }
    /// The undo or redo the menu started last (tests wait for it).
    private(set) var running: Task<[JSONValue]?, Never>?
    private var tokens: [FinanceUndoToken] = []

    /// Uses the window's undo manager; the entries of another one are taken out of it.
    func attach(_ manager: UndoManager?) {
        guard manager !== self.manager else { return }
        forgetAll()
        self.manager = manager
    }

    /// Registers the ops that undo a change; nil without an undo manager.
    func register(_ ops: [JSONValue]) -> FinanceUndoToken? {
        register(Task { ops })
    }

    private func register(_ ops: Task<[JSONValue]?, Never>) -> FinanceUndoToken? {
        guard let manager, manager.isUndoRegistrationEnabled else { return nil }
        let token = FinanceUndoToken()
        tokens.append(token)
        manager.registerUndo(withTarget: token) { [weak self, weak manager, token] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let redoing = manager?.isRedoing ?? false
                self.tokens.removeAll { $0 === token }
                self.used(token)
                let apply = self.apply
                let next = Task { @MainActor () -> [JSONValue]? in
                    guard let ops = await ops.value else { return nil }
                    return await apply(ops, redoing)
                }
                self.running = next
                // Registered while undoing, this is the redo (and while redoing, the undo).
                _ = self.register(next)
            }
        }
        return token
    }

    /// Takes one entry out (its toast undid it).
    func forget(_ token: FinanceUndoToken) {
        manager?.removeAllActions(withTarget: token)
        tokens.removeAll { $0 === token }
    }

    /// Takes all of the page's entries out: when it closes, the Edit menu shouldn't change
    /// finances that aren't shown.
    func forgetAll() {
        for token in tokens { manager?.removeAllActions(withTarget: token) }
        tokens = []
    }
}

/// Counted phrases: `^[\(n) transaction](inflect: true)` becomes "1 transaction" or "3
/// transactions" in English; German has plural variants in the catalog
/// (Localization/finance.de.json).
enum FinanceText {
    static func inflected(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value).characters)
    }
}

struct FinanceProgress: Equatable {
    var done: Int
    var total: Int
}

/// The open family's finances (web/components/finance/finance-store.ts): accounts, categories
/// and settings, the transactions of the chosen period (filtered), the summary and its
/// comparisons. Changes go straight to the API; each one can be undone from its toast with the
/// inverse ops the API returns.
@Observable
final class FinanceStore {
    static let page = 200
    /// The most ops POST /finance/transactions takes.
    static let maxOps = 2000
    /// Transactions per categorize request (the server takes at most 200).
    static let categorizeBatch = 200

    let family: FamilyContext
    var api: FamilyAPI { family.api }
    var canEdit: Bool { family.canEdit }

    var overview: FinanceOverview? {
        didSet {
            if oldValue?.categories != overview?.categories { tree = FinanceCategoryTree(overview?.categories ?? []) }
        }
    }
    private(set) var tree = FinanceCategoryTree([])
    var list: FinanceTransactionList?
    var summary: FinanceSummary?
    /// The columns the overview compares, for the period of `summary`.
    var comparisons: [FinanceComparison]?
    var balances: FinanceBalances?
    var shoppingLinks = FinanceShoppingLinks.none
    /// Whether the assistant is set up: auto-categorize uses the AI too.
    var aiConfigured = false
    var loadingList = false
    var error: String?
    var period = FinancePeriod.current()
    var filter = FinanceFilter()
    var limit = FinanceStore.page
    /// Transactions ticked in the list.
    var selected: Set<String> = []
    var categorizing: FinanceProgress?
    var toast: FinanceToast?
    /// Changes register their undo in the window's undo manager too (Edit → Undo, ⌘Z); the
    /// page attaches it.
    @ObservationIgnored let undoRegistry = FinanceUndoRegistry()

    private var knownRevision = -1
    /// The page is open (not only the settings): what it shows reloads after changes.
    private var opened = false
    private var summaryWanted = false
    private var listSeq = 0
    private var summarySeq = 0
    private var balancesSeq = 0
    private var categorizeQueue: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(family: FamilyContext) {
        self.family = family
        undoRegistry.apply = { [weak self] ops, redoing in
            await self?.apply(ops, message: redoing ? String(localized: "Redone") : String(localized: "Undone"))
        }
        undoRegistry.used = { [weak self] token in
            if self?.toast?.undoToken === token { self?.toast = nil }
        }
    }

    var currency: String { overview?.currency ?? "EUR" }
    var categories: [FinanceCategory] { overview?.categories ?? [] }
    var accounts: [FinanceAccount] { overview?.accounts ?? [] }

    func category(_ id: String?) -> FinanceCategory? { tree.category(id) }
    func account(_ id: String?) -> FinanceAccount? { id.flatMap { id in accounts.first { $0.id == id } } }

    /// The account's balance on the period's balance day, else now.
    func balance(of account: FinanceAccount) -> Int {
        balances?.cents[account.id] ?? account.balanceCents
    }

    func money(_ cents: Int, sign: Bool = false, whole: Bool = false) -> String {
        FinanceMoney.format(cents, currency: currency, sign: sign, whole: whole)
    }

    // MARK: Loading

    /// Loads what the page shows when the family's finances changed elsewhere (the assistant,
    /// another screen), or the first time; not after this store's own changes.
    func revisionChanged(_ revision: Int) async {
        guard revision != knownRevision else { return }
        knownRevision = revision
        await reloadAll()
    }

    func reloadAll() async {
        opened = true
        async let overview: Void = loadOverview()
        async let list: Void = loadList()
        async let balances: Void = loadBalances()
        async let extras: Void = loadExtras()
        async let summary: Void = summaryWanted ? loadSummary() : ()
        _ = await (overview, list, balances, extras, summary)
    }

    /// Loads only the overview (categories, accounts, settings): the settings page.
    func openSettings(_ revision: Int) async {
        guard revision != knownRevision else { return }
        knownRevision = revision
        await loadOverview()
    }

    func loadOverview() async {
        do {
            overview = try await api.get("/finance")
            error = nil
        } catch is CancellationError {
        } catch {
            if overview == nil { self.error = error.localizedDescription } else { ErrorBanner.shared.show(error) }
        }
    }

    /// The assistant's status and the shopping links: nice to have, so failures stay quiet.
    private func loadExtras() async {
        if let status = try? await api.get("/ai/settings", as: FinanceAIStatus.self) { aiConfigured = status.configured }
        if let links = try? await api.get("/finance/shopping-links", as: FinanceShoppingLinks.self) { shoppingLinks = links }
    }

    func loadList() async {
        listSeq += 1
        let seq = listSeq
        loadingList = true
        var query = period.query
        query["limit"] = String(limit)
        let q = filter.q.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { query["q"] = q }
        if !filter.category.isEmpty { query["category"] = filter.category }
        if !filter.account.isEmpty { query["account"] = filter.account }
        if filter.kind != .all { query["kind"] = filter.kind.rawValue }
        do {
            let list = try await api.get("/finance/transactions", query: query, as: FinanceTransactionList.self)
            guard seq == listSeq else { return } // a newer request is on its way
            self.list = list
            error = nil
            // Keep only what is still shown ticked.
            let ids = Set(list.transactions.map(\.id))
            selected = selected.intersection(ids)
        } catch is CancellationError {
        } catch {
            guard seq == listSeq else { return }
            if list == nil { self.error = error.localizedDescription } else { ErrorBanner.shared.show(error) }
        }
        if seq == listSeq { loadingList = false }
    }

    func loadBalances() async {
        balancesSeq += 1
        let seq = balancesSeq
        guard let at = period.balanceDay() else {
            balances = nil
            return
        }
        do {
            let res = try await api.get("/finance/accounts", query: ["at": at], as: FinanceAccountsAt.self)
            guard seq == balancesSeq else { return }
            balances = FinanceBalances(at: res.at ?? at,
                                       cents: Dictionary(res.accounts.map { ($0.id, $0.balanceCents) }) { a, _ in a })
        } catch {}
    }

    /// The summary of the period and the comparison columns.
    func loadSummary() async {
        summaryWanted = true
        summarySeq += 1
        let seq = summarySeq
        let period = self.period
        do {
            async let summary = fetchSummary(period.query)
            async let comparisons = loadComparisons(period)
            let (s, c) = try await (summary, comparisons)
            guard seq == summarySeq else { return }
            self.summary = s
            self.comparisons = c
        } catch is CancellationError {
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    private func fetchSummary(_ query: [String: String?]) async throws -> FinanceSummary {
        try await api.get("/finance/summary", query: query, as: FinanceSummary.self)
    }

    private func loadComparisons(_ period: FinancePeriod) async throws -> [FinanceComparison] {
        var out: [FinanceComparison] = []
        for range in period.comparisonRanges() {
            if let from = range.from, range.to < from {
                out.append(.none(range)) // no completed month yet
                continue
            }
            let summary = try await fetchSummary(["from": range.from, "to": range.to])
            out.append(.from(summary, range: range))
        }
        return out
    }

    /// What is shown, after the period or the data changed.
    private func reload() async {
        guard opened else { return }
        async let list: Void = loadList()
        async let balances: Void = loadBalances()
        async let summary: Void = summaryWanted ? loadSummary() : ()
        _ = await (list, balances, summary)
    }

    /// After transactions or settings changed here: everything shown, and the other screens.
    private func changed() async {
        family.didChange(.finance)
        knownRevision = family.revision(.finance)
        async let overview: Void = loadOverview()
        async let rest: Void = reload()
        _ = await (overview, rest)
    }

    // MARK: Period, filter, selection

    func setPeriod(_ period: FinancePeriod) async {
        guard period != self.period else { return }
        self.period = period
        comparisons = nil // they belong to the period before
        limit = Self.page
        selected = []
        await reload()
    }

    func step(_ step: Int) async { await setPeriod(period.stepped(step)) }

    /// The month or year with today in it (all time becomes this month).
    func goToToday() async {
        let now = FinancePeriod.current()
        await setPeriod(FinancePeriod(mode: period.mode == .all ? .month : period.mode, year: now.year, month: now.month))
    }

    func clearFilters() async {
        await setFilter { $0.category = ""; $0.account = ""; $0.kind = .all }
    }

    func setFilter(_ change: (inout FinanceFilter) -> Void) async {
        var next = filter
        change(&next)
        guard next != filter else { return }
        filter = next
        limit = Self.page
        selected = []
        await loadList()
    }

    /// The period's transactions of one category (with its subcategories) or all of them,
    /// without the other filters (`AppRoute.financeTransactions`).
    func showTransactions(category: String?) async {
        await setFilter { $0 = FinanceFilter(category: category ?? "") }
    }

    func showMore() async {
        limit += Self.page
        await loadList()
    }

    var selectedTransactions: [FinanceTransaction] {
        list?.transactions.filter { selected.contains($0.id) } ?? []
    }

    // MARK: Toasts and undo

    func show(_ message: String, undo: [JSONValue]? = nil) {
        var toast = FinanceToast(message: message, undo: undo)
        if let undo, !undo.isEmpty { toast.undoToken = undoRegistry.register(undo) }
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 8))
            if !Task.isCancelled, self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    /// Runs the toast's undo ops; its entry leaves the undo manager.
    func undoToast() async {
        guard let toast, let inverse = toast.undo else { return }
        self.toast = nil
        if let token = toast.undoToken { undoRegistry.forget(token) }
        await apply(inverse, message: String(localized: "Undone"))
    }

    /// Applies undo (or redo) ops in chunks the API takes; returns the ops that revert them
    /// (the last chunk's first), nil on failure.
    @discardableResult
    private func apply(_ ops: [JSONValue], message: String) async -> [JSONValue]? {
        do {
            var inverse: [JSONValue] = []
            var start = 0
            while start < ops.count {
                let chunk = Array(ops[start..<min(start + Self.maxOps, ops.count)])
                let res: FinanceChangeResult = try await api.send(.post, "/finance/transactions",
                                                                  body: JSONValue.object(["ops": .array(chunk)]))
                inverse = res.inverse + inverse
                start += Self.maxOps
            }
            await changed()
            show(message)
            return inverse
        } catch {
            ErrorBanner.shared.show(error)
            return nil
        }
    }

    // MARK: Transactions

    /// Applies transaction ops; the toast offers to undo them. Returns the new ids, nil on error.
    @discardableResult
    func change(_ ops: [JSONValue], message: String) async -> [String]? {
        do {
            let res: FinanceChangeResult = try await api.send(.post, "/finance/transactions",
                                                              body: JSONValue.object(["ops": .array(ops)]))
            await changed()
            show(message, undo: res.inverse)
            return res.added
        } catch {
            ErrorBanner.shared.show(error)
            return nil
        }
    }

    func setCategory(_ ids: [String], to categoryId: String?) async {
        guard !ids.isEmpty else { return }
        await change(ids.map { FinanceOp.setCategory($0, categoryId) }, message: String(localized: "Saved"))
        selected = []
    }

    func delete(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let message = ids.count == 1 ? String(localized: "Transaction deleted")
            : FinanceText.inflected("^[\(ids.count) transaction](inflect: true) deleted")
        if await change([FinanceOp.delete(ids)], message: message) != nil { selected = [] }
    }

    /// Combines transactions into one transfer: they count once, as their sum.
    func link(_ ids: [String]) async {
        if await change([FinanceOp.link(ids)], message: String(localized: "Combined into a transfer")) != nil {
            selected = []
        }
    }

    /// Combines each pair into a transfer of its own, in one undoable step.
    @discardableResult
    func linkPairs(_ pairs: [FinanceTransferPair]) async -> Bool {
        await change(pairs.map { FinanceOp.link([$0.out.id, $0.incoming.id]) },
                     message: FinanceText.inflected("^[\(pairs.count) transfer](inflect: true) combined")) != nil
    }

    func unlink(_ id: String) async {
        await change([FinanceOp.unlink(id)], message: String(localized: "Transfer split up"))
    }

    /// Makes transactions parts of a booking: they count on their own, the booking only with
    /// what they leave over.
    func split(booking: String, parts: [String]) async {
        if await change([FinanceOp.split(booking: booking, parts: parts)],
                        message: String(localized: "Combined into a split booking")) != nil {
            selected = []
        }
    }

    /// Takes a part out of its booking, or (on a booking) all of its parts.
    func unsplit(_ transaction: FinanceTransaction) async {
        await change([FinanceOp.unsplit(transaction.id)],
                     message: transaction.splitOf != nil ? String(localized: "Taken out of the split")
                         : String(localized: "Split booking undone"))
    }

    /// The selection as a split: the largest one is the booking (the first of equal ones).
    static func splitBooking(of selected: [FinanceTransaction]) -> FinanceTransaction? {
        selected.reduce(nil) { best, t in
            guard let best else { return t }
            return abs(t.amountCents) > abs(best.amountCents) ? t : best
        }
    }

    /// Parts and split bookings can't be transfer legs; a split takes only plain transactions.
    static func canLink(_ selected: [FinanceTransaction]) -> Bool {
        selected.count >= 2 && selected.allSatisfy { $0.splitOf == nil && $0.split == nil }
    }

    static func canSplit(_ selected: [FinanceTransaction]) -> Bool {
        canLink(selected) && selected.allSatisfy { $0.transferId == nil }
    }

    /// Combines the period's split bookings with their parts, then every likely transfer.
    func autoCombine() async {
        let (from, to) = period.range
        do {
            let res: FinanceChangeResult = try await api.send(
                .post, "/finance/transfers/auto",
                body: JSONValue.object(["from": FinanceJSON.string(from), "to": FinanceJSON.string(to)]))
            let linked = res.linked ?? 0, splits = res.splits ?? 0
            if linked == 0 && splits == 0 {
                show(String(localized: "No transfers or split bookings found"))
                return
            }
            await changed()
            show(Self.combinedText(transfers: linked, splits: splits), undo: res.inverse)
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// "2 transfers, 1 split booking combined".
    static func combinedText(transfers: Int, splits: Int) -> String {
        var parts: [String] = []
        if transfers > 0 { parts.append(FinanceText.inflected("^[\(transfers) transfer](inflect: true)")) }
        if splits > 0 { parts.append(FinanceText.inflected("^[\(splits) split booking](inflect: true)")) }
        return String(localized: "\(parts.joined(separator: ", ")) combined")
    }

    /// Transactions of the period that look like transfers between two accounts.
    func suggestions() async throws -> [FinanceTransferPair] {
        try await api.get("/finance/transfers/suggestions", query: period.query, as: FinanceTransferSuggestions.self).pairs
    }

    // MARK: Import

    private func importBody(_ rows: [FinanceParsedRow], accountId: String?, auto: Bool, dryRun: Bool) -> JSONValue {
        var body: [String: JSONValue] = ["rows": .array(rows.map(\.json)), "dryRun": .bool(dryRun)]
        if let accountId { body["accountId"] = .string(accountId) }
        if auto { body["autoTransfers"] = .bool(true) }
        return .object(body)
    }

    /// A dry run of an import: which rows are there already, how much would be combined.
    func checkImport(_ rows: [FinanceParsedRow], accountId: String?, auto: Bool) async throws -> FinanceImportResult {
        try await api.send(.post, "/finance/import", body: importBody(rows, accountId: accountId, auto: auto, dryRun: true))
    }

    func importRows(_ rows: [FinanceParsedRow], accountId: String?, auto: Bool) async throws -> FinanceImportResult {
        let res: FinanceImportResult = try await api.send(
            .post, "/finance/import", body: importBody(rows, accountId: accountId, auto: auto, dryRun: false))
        await changed()
        let skipped = res.duplicates.count
        if !res.ids.isEmpty {
            var message = FinanceText.inflected("Imported ^[\(res.added) transaction](inflect: true)")
            if skipped > 0 { message += " " + String(localized: "(\(skipped) already there)") }
            let transfers = res.transfers ?? 0, splits = res.splits ?? 0
            if transfers > 0 || splits > 0 { message += " · " + Self.combinedText(transfers: transfers, splits: splits) }
            show(message, undo: [FinanceOp.delete(res.ids)])
        } else {
            show(FinanceText.inflected("Nothing new: ^[\(skipped) transaction](inflect: true) already there"))
        }
        return res
    }

    /// Remembers how a bank's files map (by their header), newest first.
    func saveMapping(_ mapping: FinanceCSVMapping) async {
        guard !mapping.signature.isEmpty else { return }
        let rest = (overview?.csvMappings ?? []).filter { $0["signature"]?.stringValue != mapping.signature }
        await saveSettings(["csvMappings": .array(Array(([mapping.json] + rest).prefix(20)))])
    }

    func deleteMapping(_ signature: String) async {
        let rest = (overview?.csvMappings ?? []).filter { $0["signature"]?.stringValue != signature }
        await saveSettings(["csvMappings": .array(rest)])
    }

    // MARK: Auto-categorize

    private var language: String { Locale.current.language.languageCode?.identifier == "de" ? "de" : "en" }

    /// Sorts the period's uncategorized transactions into categories (like similar ones, the
    /// rest with the AI), in batches. Does nothing while a run is going on.
    func autoCategorize() async {
        guard categorizing == nil else { return }
        let (from, to) = period.range
        await categorize { call in
            var skip = 0, done = 0, total = 0
            while true {
                let res = try await call(["from": FinanceJSON.string(from), "to": FinanceJSON.string(to),
                                          "skip": FinanceJSON.int(skip)])
                done += res.considered
                if total == 0 { total = res.considered + res.remaining }
                self.categorizing = FinanceProgress(done: done, total: total)
                if res.considered == 0 || res.remaining == 0 { return }
                skip += res.considered - res.changed
            }
        }
    }

    /// Sorts the given transactions (e.g. just imported) into categories.
    func categorize(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await categorize { call in
            self.categorizing = FinanceProgress(done: 0, total: ids.count)
            var start = 0
            while start < ids.count {
                let batch = Array(ids[start..<min(start + Self.categorizeBatch, ids.count)])
                _ = try await call(["ids": FinanceJSON.ids(batch)])
                start += Self.categorizeBatch
                self.categorizing = FinanceProgress(done: min(start, ids.count), total: ids.count)
            }
        }
    }

    /// Runs one categorize job after the ones before it; reports with a toast whose undo
    /// reverts all of the job's calls.
    private func categorize(_ run: @escaping (_ call: @escaping ([String: JSONValue]) async throws -> FinanceCategorizeResult) async throws -> Void) async {
        let previous = categorizeQueue
        let job = Task { [self] in
            await previous?.value
            categorizing = FinanceProgress(done: 0, total: 0)
            var inverses: [[JSONValue]] = []
            var changedCount = 0, matched = 0
            var failure: (any Error)?
            do {
                try await run { body in
                    var body = body
                    body["lang"] = .string(self.language)
                    let res: FinanceCategorizeResult = try await self.api.send(.post, "/ai/categorize", body: JSONValue.object(body))
                    inverses.append(res.inverse)
                    changedCount += res.changed
                    matched += res.matched
                    return res
                }
            } catch {
                failure = error
            }
            categorizing = nil
            if changedCount > 0 {
                await changed()
                var text = FinanceText.inflected("Sorted ^[\(changedCount) transaction](inflect: true) into categories")
                if matched > 0 { text += " " + String(localized: "(\(matched) like similar ones)") }
                // The last call's inverse first.
                show(text, undo: inverses.reversed().flatMap { $0 })
            }
            if let failure, !(failure is CancellationError) {
                ErrorBanner.shared.show(String(localized: "The AI couldn’t sort: \(failure.localizedDescription)"))
            } else if changedCount == 0 {
                show(String(localized: "No transaction could be sorted"))
            }
        }
        categorizeQueue = job
        await job.value
    }

    // MARK: Categories, accounts, settings

    /// Runs a settings change, then reloads the overview (also after a failure).
    @discardableResult
    private func withOverview<T>(_ work: () async throws -> T) async -> T? {
        do {
            let out = try await work()
            await changed()
            return out
        } catch {
            ErrorBanner.shared.show(error)
            await loadOverview()
            return nil
        }
    }

    private func saveSettings(_ patch: [String: JSONValue]) async {
        await withOverview {
            overview = try await api.send(.patch, "/finance/settings", body: JSONValue.object(patch), as: FinanceOverview.self)
        }
    }

    func setCurrency(_ currency: String) async { await saveSettings(["currency": .string(currency)]) }

    /// The category the shopping lists read their spending from; nil: the default.
    func setGroceriesCategory(_ id: String?) async { await saveSettings(["groceriesCategoryId": FinanceJSON.string(id)]) }

    /// Sets the statistic average the overview compares with; nil removes it.
    func setBenchmark(_ benchmark: FinanceBenchmark?) async {
        await saveSettings(["benchmark": benchmark.map { FinanceJSON.encode($0) } ?? .null])
    }

    /// The default category, as lib/finance/groceries.ts picks it.
    var defaultGroceries: FinanceCategory? {
        categories.filter { $0.id == "groceries" || ["groceries", "lebensmittel"].contains($0.name.trimmingCharacters(in: .whitespaces).lowercased()) }
            .sorted { ($0.parentId == nil ? 0 : 1, $0.position) < ($1.parentId == nil ? 0 : 1, $1.position) }
            .first
    }

    /// A new category at the top level or (with its color and kind) under `parent`.
    @discardableResult
    func addCategory(name: String, parent: FinanceCategory? = nil, kind: FinanceCategoryKind = .expense,
                     color: String? = nil, icon: String = "") async -> FinanceCategory? {
        await withOverview {
            try await api.send(.post, "/finance/categories", body: JSONValue.object([
                "name": .string(name),
                "color": .string(color ?? parent?.color ?? FinanceColor.next(used: categories.map(\.color))),
                "icon": .string(icon),
                "kind": .string((parent?.kind ?? kind).rawValue),
                "parentId": FinanceJSON.string(parent?.id),
            ]), as: FinanceCategory.self)
        }
    }

    /// Changes any of name, color, icon, kind, parentId (`.null`: top level), position; false
    /// when it failed (the banner says why).
    @discardableResult
    func updateCategory(_ id: String, _ patch: [String: JSONValue]) async -> Bool {
        let saved: FinanceCategory? = await withOverview {
            try await api.send(.patch, "/finance/categories/\(id)", body: JSONValue.object(patch))
        }
        return saved != nil
    }

    /// Moves the category up or down among its siblings.
    func moveCategory(_ id: String, by step: Int) async {
        let changes = tree.reorder(id, by: step)
        guard !changes.isEmpty else { return }
        await withOverview {
            for (id, position) in changes {
                let _: FinanceCategory = try await api.send(.patch, "/finance/categories/\(id)",
                                                            body: JSONValue.object(["position": FinanceJSON.int(position)]))
            }
        }
    }

    /// Deletes the category; its subcategories and transactions move to its parent.
    func deleteCategory(_ id: String) async {
        await withOverview {
            let _: JSONValue = try await api.send(.delete, "/finance/categories/\(id)")
        }
        if filter.category == id { await setFilter { $0.category = "" } }
    }

    func addDefaultCategories() async {
        await withOverview {
            let _: [FinanceCategory] = try await api.send(.post, "/finance/categories/defaults",
                                                          body: JSONValue.object(["lang": .string(language)]))
        }
    }

    @discardableResult
    func addAccount(name: String, color: String? = nil, icon: String = "", openingCents: Int = 0) async -> FinanceAccount? {
        await withOverview {
            try await api.send(.post, "/finance/accounts", body: JSONValue.object([
                "name": .string(name),
                "color": .string(color ?? FinanceColor.next(used: accounts.map(\.color))),
                "icon": .string(icon),
                "openingCents": FinanceJSON.int(openingCents),
            ]), as: FinanceAccount.self)
        }
    }

    /// Changes any of name, color, icon, openingCents, position; false when it failed.
    @discardableResult
    func updateAccount(_ id: String, _ patch: [String: JSONValue]) async -> Bool {
        let saved: FinanceAccount? = await withOverview {
            try await api.send(.patch, "/finance/accounts/\(id)", body: JSONValue.object(patch))
        }
        return saved != nil
    }

    /// Swaps the account with its neighbor.
    func moveAccount(_ id: String, by step: Int) async {
        var list = accounts
        guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + step) else { return }
        list.swapAt(i, i + step)
        let a = list[i], b = list[i + step]
        await withOverview {
            let _: FinanceAccount = try await api.send(.patch, "/finance/accounts/\(a.id)",
                                                       body: JSONValue.object(["position": FinanceJSON.int(i)]))
            let _: FinanceAccount = try await api.send(.patch, "/finance/accounts/\(b.id)",
                                                       body: JSONValue.object(["position": FinanceJSON.int(i + step)]))
        }
    }

    /// Deletes the account with its transactions; there is no undo.
    func deleteAccount(_ id: String) async {
        await withOverview {
            let _: JSONValue = try await api.send(.delete, "/finance/accounts/\(id)")
        }
        if filter.account == id { await setFilter { $0.account = "" } }
    }

    /// Deletes all transactions, accounts, categories and settings; there is no undo.
    func clearAll() async {
        let done: Void? = await withOverview {
            overview = try await api.send(.delete, "/finance", as: FinanceOverview.self)
        }
        if done != nil { show(String(localized: "All finance data deleted")) }
    }
}

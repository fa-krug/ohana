import Foundation

extension DemoServer {
    /// The demo's finance routes that depend on the query; the rest are files. Everything is
    /// worked out from `demo-finance.json` (settings, categories, accounts) and
    /// `demo-finance-transactions.json` (every transaction, none after today) the way
    /// server/lib/finance/finance.ts does it: balances, the list's filters and paging, net counting
    /// of transfers in the totals and the summary, and the suggested transfers.
    static func finance(_ request: Request) -> JSONValue? {
        guard let path = request.familyPath,
              path == "/finance" || path.hasPrefix("/finance/"),
              let data = DemoFinance(request) else { return nil }
        switch path {
        case "/finance": return encoded(data.overview())
        case "/finance/accounts": return encoded(data.accountsAt(request.query["at"]))
        case "/finance/transactions": return encoded(data.list(request.query))
        case "/finance/summary": return encoded(data.summary(from: request.query["from"], to: request.query["to"]))
        case "/finance/transfers/suggestions":
            return encoded(data.suggestions(from: request.query["from"], to: request.query["to"]))
        default: return nil
        }
    }

    private static func encoded(_ value: some Encodable) -> JSONValue? {
        guard let data = try? APIClient.encoder.encode(value) else { return nil }
        return try? APIClient.decoder.decode(JSONValue.self, from: data)
    }
}

/// The demo's finances, loaded for one request.
private struct DemoFinance {
    private struct File: Decodable {
        var transactions: [FinanceTransaction]
    }

    /// One transaction as the totals count it (netItems).
    private struct NetItem {
        var date: String
        var amountCents: Int
        var categoryId: String?
    }

    let base: FinanceOverview
    /// Newest first; within a day in the file's order.
    let transactions: [FinanceTransaction]
    /// The legs of each transfer (≥ 2), earliest first.
    let groups: [String: [FinanceTransaction]]

    init?(_ request: DemoServer.Request) {
        guard let overview = request.fixture("finance"),
              let base = try? APIClient.decoder.decode(FinanceOverview.self, from: overview),
              let file = request.fixture("finance-transactions"),
              let all = try? APIClient.decoder.decode(File.self, from: file).transactions else { return nil }
        let today = request.today.description
        self.base = base
        transactions = all.enumerated()
            .filter { $0.element.date <= today }
            .sorted { a, b in a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset }
            .map(\.element)
        var groups: [String: [FinanceTransaction]] = [:]
        for t in transactions {
            if let id = t.transferId { groups[id, default: []].append(t) }
        }
        self.groups = groups.filter { $0.value.count >= 2 }
            .mapValues { $0.sorted { ($0.date, $0.id) < ($1.date, $1.id) } }
    }

    // MARK: Routes

    /// GET /finance: the accounts with their balances now.
    func overview() -> FinanceOverview {
        var overview = base
        overview.accounts = accounts(at: nil)
        return overview
    }

    /// GET /finance/accounts?at=
    func accountsAt(_ at: String?) -> FinanceAccountsAt {
        FinanceAccountsAt(at: at, accounts: accounts(at: at))
    }

    /// GET /finance/transactions?from&to&account&category&q&kind&limit&offset (findTransactions).
    func list(_ query: [String: String]) -> FinanceTransactionList {
        var rows = inRange(query["from"], query["to"])
        if let account = query["account"], !account.isEmpty {
            rows = rows.filter { account == "none" ? $0.accountId == nil : $0.accountId == account }
        }
        if let category = query["category"], !category.isEmpty {
            if category == "none" {
                rows = rows.filter { $0.categoryId == nil }
            } else {
                let ids = subtree(category)
                rows = rows.filter { t in t.categoryId.map { ids.contains($0) } ?? false }
            }
        }
        if let q = query["q"]?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty {
            rows = rows.filter {
                $0.payee.lowercased().contains(q) || $0.description.lowercased().contains(q)
                    || $0.note.lowercased().contains(q)
            }
        }
        switch query["kind"] {
        case "transfer": rows = rows.filter { group(of: $0) != nil }
        case "income": rows = rows.filter { net(of: $0) > 0 }
        case "expense": rows = rows.filter { net(of: $0) < 0 }
        default: break
        }
        let (income, expense) = totals(netItems(rows))
        let limit = min(1000, max(1, query["limit"].flatMap { Int($0) } ?? 200))
        let offset = max(0, query["offset"].flatMap { Int($0) } ?? 0)
        let page = offset < rows.count ? Array(rows[offset..<min(rows.count, offset + limit)]) : []
        return FinanceTransactionList(transactions: page.map(linked), total: rows.count,
                                      incomeCents: income, expenseCents: expense)
    }

    /// GET /finance/summary?from&to (financeSummary).
    func summary(from: String?, to: String?) -> FinanceSummary {
        var months: [String: FinanceSummaryMonth] = [:]
        var categories: [FinanceSummaryCategory] = []
        var income = 0, expense = 0
        let items = netItems(inRange(from, to))
        for item in items {
            let month = String(item.date.prefix(7))
            var m = months[month] ?? FinanceSummaryMonth(month: month, incomeCents: 0, expenseCents: 0)
            if !categories.contains(where: { $0.categoryId == item.categoryId }) {
                categories.append(FinanceSummaryCategory(categoryId: item.categoryId, incomeCents: 0, expenseCents: 0, count: 0))
            }
            let index = categories.firstIndex { $0.categoryId == item.categoryId }!
            if item.amountCents > 0 {
                m.incomeCents += item.amountCents
                categories[index].incomeCents += item.amountCents
                income += item.amountCents
            } else {
                m.expenseCents -= item.amountCents
                categories[index].expenseCents -= item.amountCents
                expense -= item.amountCents
            }
            categories[index].count += 1
            months[month] = m
        }
        let byExpense = categories.enumerated()
            .sorted { a, b in a.element.expenseCents != b.element.expenseCents
                ? a.element.expenseCents > b.element.expenseCents : a.offset < b.offset }
            .map(\.element)
        return FinanceSummary(currency: base.currency, incomeCents: income, expenseCents: expense, count: items.count,
                              months: months.values.sorted { $0.month < $1.month }, categories: byExpense)
    }

    /// GET /finance/transfers/suggestions?from&to (matchTransfers over the transactions that
    /// aren't legs of a transfer yet; the demo has no split bookings).
    func suggestions(from: String?, to: String?) -> FinanceTransferSuggestions {
        let rows = inRange(from, to).filter { group(of: $0) == nil }
        func lead(_ a: FinanceTransaction, _ b: FinanceTransaction) -> Bool { (a.date, a.id) < (b.date, b.id) }
        var candidates: [(out: FinanceTransaction, in: FinanceTransaction, gap: Int)] = []
        for out in rows where out.amountCents < 0 {
            for into in rows where into.amountCents == -out.amountCents && into.accountId != out.accountId {
                guard let a = Day(out.date), let b = Day(into.date) else { continue }
                let gap = abs(FinanceDates.days(from: a, to: b))
                if gap <= 4 { candidates.append((out, into, gap)) }
            }
        }
        candidates.sort { a, b in
            if a.gap != b.gap { return a.gap < b.gap }
            if a.out.date != b.out.date { return a.out.date > b.out.date }
            if a.out.id != b.out.id { return lead(a.out, b.out) }
            return lead(a.in, b.in)
        }
        var used = Set<String>()
        var pairs: [FinanceTransferPair] = []
        for c in candidates where !used.contains(c.out.id) && !used.contains(c.in.id) {
            used.formUnion([c.out.id, c.in.id])
            pairs.append(FinanceTransferPair(out: unlinked(c.out), incoming: unlinked(c.in)))
        }
        func latest(_ p: FinanceTransferPair) -> String { max(p.out.date, p.incoming.date) }
        pairs.sort { a, b in latest(a) != latest(b) ? latest(a) > latest(b) : a.out.date > b.out.date }
        return FinanceTransferSuggestions(pairs: Array(pairs.prefix(200)))
    }

    // MARK: Helpers

    /// The accounts with their balances at the end of `at` (now without it).
    private func accounts(at: String?) -> [FinanceAccount] {
        base.accounts.map { account in
            var account = account
            account.balanceCents = account.openingCents + transactions
                .filter { t in t.accountId == account.id && (at.map { t.date <= $0 } ?? true) }
                .reduce(0) { $0 + $1.amountCents }
            return account
        }
    }

    private func inRange(_ from: String?, _ to: String?) -> [FinanceTransaction] {
        transactions.filter { t in
            (from.map { $0.isEmpty || t.date >= $0 } ?? true) && (to.map { $0.isEmpty || t.date <= $0 } ?? true)
        }
    }

    /// A category with its subcategories.
    private func subtree(_ id: String) -> Set<String> {
        var ids: Set<String> = [id]
        var added = true
        while added {
            added = false
            for c in base.categories where c.parentId.map({ ids.contains($0) }) == true && !ids.contains(c.id) {
                ids.insert(c.id)
                added = true
            }
        }
        return ids
    }

    private func group(of t: FinanceTransaction) -> [FinanceTransaction]? {
        t.transferId.flatMap { groups[$0] }
    }

    /// What a transaction counts as: its amount, or the net of its transfer.
    private func net(of t: FinanceTransaction) -> Int {
        group(of: t).map { $0.reduce(0) { $0 + $1.amountCents } } ?? t.amountCents
    }

    /// Net counting: a transfer counts once, on its lead leg, with its net (nothing when 0).
    private func netItems(_ rows: [FinanceTransaction]) -> [NetItem] {
        rows.compactMap { t in
            guard let legs = group(of: t) else { return NetItem(date: t.date, amountCents: t.amountCents, categoryId: t.categoryId) }
            let net = net(of: t)
            guard legs.first?.id == t.id, net != 0 else { return nil }
            return NetItem(date: t.date, amountCents: net, categoryId: legs.first { $0.categoryId != nil }?.categoryId)
        }
    }

    private func totals(_ items: [NetItem]) -> (income: Int, expense: Int) {
        items.reduce((0, 0)) { sum, item in
            item.amountCents > 0 ? (sum.0 + item.amountCents, sum.1) : (sum.0, sum.1 - item.amountCents)
        }
    }

    /// As the list shows it: the transfer id only on legs of a transfer.
    private func linked(_ t: FinanceTransaction) -> FinanceTransaction {
        var t = t
        if group(of: t) == nil { t.transferId = nil }
        return t
    }

    private func unlinked(_ t: FinanceTransaction) -> FinanceTransaction {
        var t = t
        t.transferId = nil
        return t
    }
}

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
        case "/finance/payees": return encoded(data.payees(request.query))
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
        var payee = ""
        var description = ""
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
            .sorted { lhs, rhs in lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset < rhs.offset }
            .map(\.element)
        var groups: [String: [FinanceTransaction]] = [:]
        for txn in transactions {
            if let id = txn.transferId { groups[id, default: []].append(txn) }
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

    /// GET /finance/transactions?from&to&account&category&payee&q&kind&source&limit&offset (findTransactions).
    func list(_ query: [String: String]) -> FinanceTransactionList {
        let rows = filtered(query)
        let (income, expense) = totals(netItems(rows))
        let limit = min(1000, max(1, query["limit"].flatMap { Int($0) } ?? 200))
        let offset = max(0, query["offset"].flatMap { Int($0) } ?? 0)
        let page = offset < rows.count ? Array(rows[offset..<min(rows.count, offset + limit)]) : []
        return FinanceTransactionList(transactions: page.map(linked), total: rows.count,
                                      incomeCents: income, expenseCents: expense)
    }

    /// GET /finance/payees?…the list's filters…&limit (payeeTotals): by payee key, largest first.
    func payees(_ query: [String: String]) -> FinancePayeeList {
        var byKey: [String: (payee: FinancePayee, date: String)] = [:]
        for item in netItems(filtered(query)) {
            let key = Self.payeeKey(payee: item.payee, description: item.description)
            var entry = byKey[key] ?? (FinancePayee(key: key, name: "", count: 0, incomeCents: 0, expenseCents: 0), "")
            entry.payee.count += 1
            if item.amountCents > 0 { entry.payee.incomeCents += item.amountCents } else { entry.payee.expenseCents -= item.amountCents }
            if item.date >= entry.date {
                entry.date = item.date
                let name = item.payee.trimmingCharacters(in: .whitespaces)
                entry.payee.name = name.isEmpty ? item.description.trimmingCharacters(in: .whitespaces) : name
            }
            byKey[key] = entry
        }
        let income = query["kind"] == "income"
        let all = byKey.values.map(\.payee).sorted { lhs, rhs in
            let (lhsCents, rhsCents) = income ? (lhs.incomeCents, rhs.incomeCents) : (lhs.expenseCents, rhs.expenseCents)
            return lhsCents != rhsCents ? lhsCents > rhsCents : lhs.key < rhs.key
        }
        let limit = min(100, max(1, query["limit"].flatMap { Int($0) } ?? 20))
        return FinancePayeeList(payees: Array(all.prefix(limit)), more: max(0, all.count - limit))
    }

    /// server/lib/finance/finance.ts similarKey: the first three words (two letters or more) of
    /// the payee, else of the description, lower case, without numbers and punctuation.
    static func payeeKey(payee: String, description: String) -> String {
        func words(_ text: String) -> [String] {
            let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
                CharacterSet.letters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) ? Character(scalar) : " "
            }
            return String(kept).split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count > 1 }
        }
        let own = words(payee)
        return (own.isEmpty ? words(description) : own).prefix(3).joined(separator: " ")
    }

    /// The transactions matching the list's filters, newest first.
    private func filtered(_ query: [String: String]) -> [FinanceTransaction] {
        var rows = inRange(query["from"], query["to"])
        if let account = query["account"], !account.isEmpty {
            rows = rows.filter { account == "none" ? $0.accountId == nil : $0.accountId == account }
        }
        if let category = query["category"], !category.isEmpty {
            if category == "none" {
                rows = rows.filter { $0.categoryId == nil }
            } else {
                let ids = subtree(category)
                rows = rows.filter { row in row.categoryId.map { ids.contains($0) } ?? false }
            }
        }
        if let payee = query["payee"]?.trimmingCharacters(in: .whitespaces), !payee.isEmpty {
            rows = rows.filter { Self.payeeKey(payee: $0.payee, description: $0.description) == payee }
        }
        if let searchText = query["q"]?.trimmingCharacters(in: .whitespaces).lowercased(), !searchText.isEmpty {
            rows = rows.filter {
                $0.payee.lowercased().contains(searchText) || $0.description.lowercased().contains(searchText)
                    || $0.note.lowercased().contains(searchText)
            }
        }
        if let source = query["source"], !source.isEmpty {
            let wanted = Set(source.split(separator: ",").map { String($0) })
            rows = rows.filter { wanted.contains($0.source ?? ($0.imported ? "csv" : "manual")) }
        }
        switch query["kind"] {
        case "transfer": rows = rows.filter { group(of: $0) != nil }
        case "income": rows = rows.filter { net(of: $0) > 0 }
        case "expense": rows = rows.filter { net(of: $0) < 0 }
        default: break
        }
        return rows
    }

    /// GET /finance/summary?from&to (financeSummary): within a category money in and out cancel
    /// out, over the range for the totals and the categories, within the month for the months.
    func summary(from: String?, to: String?) -> FinanceSummary {
        let items = netItems(inRange(from, to))
        var byMonth: [String: [NetItem]] = [:]
        var byCategory: [String?: [NetItem]] = [:]
        var order: [String?] = []
        for item in items {
            byMonth[String(item.date.prefix(7)), default: []].append(item)
            if byCategory[item.categoryId] == nil { order.append(item.categoryId) }
            byCategory[item.categoryId, default: []].append(item)
        }
        let months = byMonth.map { month, list -> FinanceSummaryMonth in
            let (income, expense) = totals(list)
            return FinanceSummaryMonth(month: month, incomeCents: income, expenseCents: expense)
        }
        let categories = order.map { id -> FinanceSummaryCategory in
            let list = byCategory[id] ?? []
            let (income, expense) = totals(list)
            return FinanceSummaryCategory(categoryId: id, incomeCents: income, expenseCents: expense, count: list.count)
        }
        let byExpense = categories.enumerated()
            .sorted { lhs, rhs in lhs.element.expenseCents != rhs.element.expenseCents
                ? lhs.element.expenseCents > rhs.element.expenseCents : lhs.offset < rhs.offset }
            .map(\.element)
        let (income, expense) = totals(items)
        return FinanceSummary(currency: base.currency, incomeCents: income, expenseCents: expense, count: items.count,
                              months: months.sorted { $0.month < $1.month }, categories: byExpense)
    }

    /// GET /finance/transfers/suggestions?from&to (matchTransfers over the transactions that
    /// aren't legs of a transfer yet; the demo has no split bookings).
    func suggestions(from: String?, to: String?) -> FinanceTransferSuggestions {
        let rows = inRange(from, to).filter { group(of: $0) == nil }
        func lead(_ lhs: FinanceTransaction, _ rhs: FinanceTransaction) -> Bool { (lhs.date, lhs.id) < (rhs.date, rhs.id) }
        var candidates: [(out: FinanceTransaction, in: FinanceTransaction, gap: Int)] = []
        for out in rows where out.amountCents < 0 {
            for into in rows where into.amountCents == -out.amountCents && into.accountId != out.accountId {
                guard let outDay = Day(out.date), let intoDay = Day(into.date) else { continue }
                let gap = abs(FinanceDates.days(from: outDay, to: intoDay))
                if gap <= 4 { candidates.append((out, into, gap)) }
            }
        }
        candidates.sort { left, right in
            if left.gap != right.gap { return left.gap < right.gap }
            if left.out.date != right.out.date { return left.out.date > right.out.date }
            if left.out.id != right.out.id { return lead(left.out, right.out) }
            return lead(left.in, right.in)
        }
        var used = Set<String>()
        var pairs: [FinanceTransferPair] = []
        for candidate in candidates where !used.contains(candidate.out.id) && !used.contains(candidate.in.id) {
            used.formUnion([candidate.out.id, candidate.in.id])
            pairs.append(FinanceTransferPair(out: unlinked(candidate.out), incoming: unlinked(candidate.in)))
        }
        func latest(_ pair: FinanceTransferPair) -> String { max(pair.out.date, pair.incoming.date) }
        pairs.sort { lhs, rhs in latest(lhs) != latest(rhs) ? latest(lhs) > latest(rhs) : lhs.out.date > rhs.out.date }
        return FinanceTransferSuggestions(pairs: Array(pairs.prefix(200)))
    }

    // MARK: Helpers

    /// The accounts with their balances at the end of `at` (now without it).
    private func accounts(at: String?) -> [FinanceAccount] {
        base.accounts.map { account in
            var account = account
            account.balanceCents = account.openingCents + transactions
                .filter { txn in txn.accountId == account.id && (at.map { txn.date <= $0 } ?? true) }
                .reduce(0) { $0 + $1.amountCents }
            return account
        }
    }

    private func inRange(_ from: String?, _ to: String?) -> [FinanceTransaction] {
        transactions.filter { txn in
            (from.map { $0.isEmpty || txn.date >= $0 } ?? true) && (to.map { $0.isEmpty || txn.date <= $0 } ?? true)
        }
    }

    /// A category with its subcategories.
    private func subtree(_ id: String) -> Set<String> {
        var ids: Set<String> = [id]
        var added = true
        while added {
            added = false
            for node in base.categories where node.parentId.map({ ids.contains($0) }) == true && !ids.contains(node.id) {
                ids.insert(node.id)
                added = true
            }
        }
        return ids
    }

    private func group(of txn: FinanceTransaction) -> [FinanceTransaction]? {
        txn.transferId.flatMap { groups[$0] }
    }

    /// What a transaction counts as: its amount, or the net of its transfer.
    private func net(of txn: FinanceTransaction) -> Int {
        group(of: txn).map { $0.reduce(0) { $0 + $1.amountCents } } ?? txn.amountCents
    }

    /// Net counting: a transfer counts once, on its lead leg, with its net (nothing when 0).
    private func netItems(_ rows: [FinanceTransaction]) -> [NetItem] {
        rows.compactMap { txn in
            guard let legs = group(of: txn) else {
                return NetItem(date: txn.date, amountCents: txn.amountCents, categoryId: txn.categoryId,
                               payee: txn.payee, description: txn.description)
            }
            let net = net(of: txn)
            guard legs.first?.id == txn.id, net != 0 else { return nil }
            return NetItem(date: txn.date, amountCents: net, categoryId: legs.first { $0.categoryId != nil }?.categoryId,
                           payee: txn.payee, description: txn.description)
        }
    }

    /// Income and expenses, money in and out within a category cancelling out (netTotals);
    /// uncategorized money as it is.
    private func totals(_ items: [NetItem]) -> (income: Int, expense: Int) {
        var income = 0, expense = 0
        var byCategory: [String: (moneyIn: Int, moneyOut: Int)] = [:]
        for item in items {
            if item.amountCents > 0 { income += item.amountCents } else { expense -= item.amountCents }
            guard let id = item.categoryId else { continue }
            var sums = byCategory[id] ?? (moneyIn: 0, moneyOut: 0)
            if item.amountCents > 0 { sums.moneyIn += item.amountCents } else { sums.moneyOut -= item.amountCents }
            byCategory[id] = sums
        }
        let overlap = byCategory.values.reduce(0) { $0 + min($1.moneyIn, $1.moneyOut) }
        return (income - overlap, expense - overlap)
    }

    /// As the list shows it: the transfer id only on legs of a transfer.
    private func linked(_ txn: FinanceTransaction) -> FinanceTransaction {
        var updated = txn
        if group(of: updated) == nil { updated.transferId = nil }
        return updated
    }

    private func unlinked(_ txn: FinanceTransaction) -> FinanceTransaction {
        var stripped = txn
        stripped.transferId = nil
        return stripped
    }
}

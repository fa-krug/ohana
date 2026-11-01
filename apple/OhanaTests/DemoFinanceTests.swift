import Foundation
import Testing
@testable import Ohana

/// The demo's finances: what FinanceStore GETs, decoded into the models the screens use.
struct DemoFinanceTests {
    private let today = Day("2026-10-30")!
    private let october: [String: String] = ["from": "2026-10-01", "to": "2026-10-31"]

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], today: Day? = nil,
                                   as type: T.Type) throws -> T {
        var server = DemoServer()
        let day = today ?? self.today
        server.today = { day }
        server.now = { day.date }
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo" + path)
        if !query.isEmpty {
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        let (data, response) = server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200)
        return try APIClient.decoder.decode(T.self, from: data)
    }

    private func list(_ query: [String: String], today: Day? = nil) throws -> FinanceTransactionList {
        try get("/finance/transactions", query, today: today, as: FinanceTransactionList.self)
    }

    @Test func theOverviewHasCategoriesAccountsAndBalances() throws {
        let overview = try get("/finance", as: FinanceOverview.self)
        #expect(overview.currency == "EUR")
        #expect(overview.categories.first { $0.id == "groceries" }?.label == "🛒 Groceries")
        #expect(overview.categories.filter { $0.parentId == "kids" }.count == 3)
        #expect(overview.accounts.map(\.name) == ["Checking", "Savings"])
        // Savings: opening 8,500 + four monthly 500 + interest 38.12 − 600 for the vacation.
        #expect(overview.accounts[1].balanceCents == 850_000 + 4 * 50_000 + 3_812 - 60_000)
        #expect(overview.accounts[0].balanceCents > 0)
        #expect(overview.benchmark?.categories.isEmpty == false)

        // The balances at today are those of now; at the end of September, before October's.
        let now = try get("/finance/accounts", ["at": today.description], as: FinanceAccountsAt.self)
        #expect(now.at == "2026-10-30")
        #expect(now.accounts.map(\.balanceCents) == overview.accounts.map(\.balanceCents))
        let september = try get("/finance/accounts", ["at": "2026-09-30"], as: FinanceAccountsAt.self)
        #expect(september.accounts[1].balanceCents == 850_000 + 3 * 50_000 + 3_812)
    }

    @Test func theListFiltersByPeriodAndCountsTransfersOnce() throws {
        let all = try list(["limit": "1000"])
        #expect(all.total == all.transactions.count)
        #expect(all.transactions.allSatisfy { $0.date <= "2026-10-30" })
        #expect(all.transactions.map(\.date) == all.transactions.map(\.date).sorted(by: >))
        // Months of data before this one.
        #expect(all.transactions.last.map { $0.date < "2026-08-01" } == true)

        let month = try list(october)
        #expect(month.transactions.allSatisfy { $0.date.hasPrefix("2026-10") })
        // Two salaries, child benefit, a refund and the vacation money from savings (not combined
        // yet); the 500 to savings is a transfer and counts nothing.
        #expect(month.incomeCents == 312_000 + 164_000 + 51_800 + 2_499 + 60_000)
        let legs = month.transactions.filter { $0.transferId != nil }
        #expect(legs.count == 2 && Set(legs.compactMap(\.accountId)) == ["acc-checking", "acc-savings"])

        let transfers = try list(october.merging(["kind": "transfer"]) { a, _ in a })
        #expect(transfers.total == 2 && transfers.incomeCents == 0 && transfers.expenseCents == 0)

        let income = try list(october.merging(["kind": "income"]) { a, _ in a })
        #expect(income.transactions.allSatisfy { $0.amountCents > 0 && $0.transferId == nil })
        #expect(income.incomeCents == month.incomeCents && income.expenseCents == 0)
    }

    @Test func theListFiltersByCategoryAccountSearchAndPages() throws {
        // Four big shops and four small ones in October.
        let groceries = try list(october.merging(["category": "groceries"]) { a, _ in a })
        #expect(groceries.total == 8)
        #expect(groceries.expenseCents == 14_230 + 9_865 + 16_112 + 12_744 + 1_460 + 3_215 + 1_185 + 4_120)

        // A category with its subcategories: swimming lessons and Kita.
        let kids = try list(october.merging(["category": "kids"]) { a, _ in a })
        #expect(kids.total == 2 && kids.expenseCents == 4_500 + 2_300)

        let savings = try list(["account": "acc-savings"])
        #expect(savings.transactions.allSatisfy { $0.accountId == "acc-savings" })
        let uncategorized = try list(october.merging(["category": "none"]) { a, _ in a })
        #expect(uncategorized.transactions.allSatisfy { $0.categoryId == nil })
        #expect(uncategorized.total == 4)

        let rewe = try list(["q": "rewe"])
        #expect(rewe.total > 0 && rewe.transactions.allSatisfy { $0.payee == "REWE" })

        let first = try list(["limit": "5"])
        let second = try list(["limit": "5", "offset": "5"])
        #expect(first.transactions.count == 5 && second.transactions.count == 5)
        #expect(first.total == second.total)
        #expect(Set(first.transactions.map(\.id)).isDisjoint(with: second.transactions.map(\.id)))
    }

    @Test func theSummaryMatchesTheList() throws {
        let summary = try get("/finance/summary", october, as: FinanceSummary.self)
        let month = try list(october)
        #expect(summary.currency == "EUR")
        #expect(summary.incomeCents == month.incomeCents && summary.expenseCents == month.expenseCents)
        #expect(summary.months.map(\.month) == ["2026-10"])
        #expect(summary.categories.first?.categoryId == "rent") // the biggest expense
        #expect(summary.categories.first { $0.categoryId == "groceries" }?.count == 8)
        #expect(summary.count == month.total - 2) // the transfer's two legs count nothing

        // The comparisons: last month and the averages over completed months.
        let september = try get("/finance/summary", ["from": "2026-09-01", "to": "2026-09-30"], as: FinanceSummary.self)
        #expect(september.incomeCents == 312_000 + 164_000 + 51_800)
        let all = try get("/finance/summary", ["to": "2026-09-30"], as: FinanceSummary.self)
        #expect(all.months.map(\.month) == ["2026-07", "2026-08", "2026-09"])
        #expect(all.months.allSatisfy { $0.incomeCents > $0.expenseCents })
    }

    @Test func theVacationMoneyIsASuggestedTransfer() throws {
        let suggestions = try get("/finance/transfers/suggestions", october, as: FinanceTransferSuggestions.self)
        #expect(suggestions.pairs.count == 1)
        let pair = try #require(suggestions.pairs.first)
        #expect(pair.out.id == "tx-vacation-out" && pair.incoming.id == "tx-vacation-in")
        #expect(pair.out.accountId == "acc-savings" && pair.incoming.accountId == "acc-checking")
        let none = try get("/finance/transfers/suggestions", ["from": "2026-09-01", "to": "2026-09-30"],
                           as: FinanceTransferSuggestions.self)
        #expect(none.pairs.isEmpty)
    }

    @Test func earlyInTheMonthNothingIsInTheFuture() throws {
        let day = Day("2026-11-03")!
        let all = try list(["limit": "1000"], today: day)
        #expect(all.transactions.allSatisfy { $0.date <= "2026-11-03" })
        let november = try list(["from": "2026-11-01", "to": "2026-11-30"], today: day)
        #expect(november.transactions.contains { $0.id == "tx-m0-rent" })
        #expect(!november.transactions.contains { $0.id == "tx-m0-salary-ben" })
    }
}

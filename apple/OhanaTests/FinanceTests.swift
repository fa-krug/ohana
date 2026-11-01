import Foundation
import Testing
@testable import Ohana

/// The finance API's JSON as server/lib/finance/finance.ts writes it (dumped from the server's
/// routes), decoded by the app's models.
struct FinanceDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesTheOverview() throws {
        let json = """
        {"currency":"EUR","csvMappings":[{"signature":"Datum;Betrag","encoding":"utf-8","delimiter":";","skipRows":0,
        "hasHeader":true,"date":0,"dateFormat":"DD.MM.YYYY","amount":1,"debit":null,"credit":null,"decimal":",",
        "payee":null,"description":[]},{"signature":"odd","something":"else"}],
        "benchmark":{"label":"Destatis","income":{"lowCents":400000,"highCents":400000},
        "expense":{"lowCents":250000,"highCents":320000},"categories":[{"categoryId":"groceries","lowCents":50000,"highCents":70000}]},
        "groceriesCategoryId":null,
        "categories":[{"id":"salary","name":"Salary","color":"#22c55e","icon":"💼","kind":"income","position":0,"parentId":null},
        {"id":"groceries","name":"Groceries","color":"#f97316","icon":"🛒","kind":"expense","position":2,"parentId":null},
        {"id":"bakery","name":"Bakery","color":"#f97316","icon":"","kind":"expense","position":0,"parentId":"groceries"}],
        "accounts":[{"id":"giro","name":"Giro","color":"#3b82f6","icon":"","openingCents":10000,"position":0,"balanceCents":-5000}]}
        """
        let overview = try decode(FinanceOverview.self, json)
        #expect(overview.currency == "EUR")
        #expect(overview.categories.count == 3)
        #expect(overview.categories[2].parentId == "groceries")
        #expect(overview.categories[0].kind == .income)
        #expect(overview.accounts[0].balanceCents == -5000)
        #expect(overview.benchmark?.expense == FinanceCentsRange(lowCents: 250000, highCents: 320000))
        #expect(overview.benchmark?.categories.first?.categoryId == "groceries")
        #expect(overview.groceriesCategoryId == nil)
        // The mapping the app can't read is kept as JSON but not offered.
        #expect(overview.csvMappings.count == 2)
        #expect(overview.mappings.count == 1)
        #expect(overview.mappings[0].amount == 1)
        #expect(overview.mappings[0].dateFormat == .german)
    }

    @Test func decodesTransactionsWithTheirLinks() throws {
        let json = """
        {"transactions":[
        {"id":"693795f2-ec25-4c50-af60-3527fcd4b75e","date":"2026-10-04","amountCents":-4250,"payee":"Rewe","description":"",
         "categoryId":"groceries","accountId":null,"transferId":null,"splitOf":null,"split":null,"note":"weekly","imported":false},
        {"id":"04272196-fca1-44de-a5aa-39aab8291e9a","date":"2026-10-03","amountCents":-10000,"payee":"Amazon",
         "description":"Splitbuchung","categoryId":"shopping","accountId":"giro","transferId":null,"splitOf":null,
         "split":{"parts":1,"remainderCents":-7000},"note":"","imported":false},
        {"id":"9894fd66-f1d4-4840-b6af-c28f740def84","date":"2026-10-03","amountCents":-3000,"payee":"","description":"Book",
         "categoryId":"leisure","accountId":"giro","transferId":null,"splitOf":"04272196-fca1-44de-a5aa-39aab8291e9a",
         "split":null,"note":"","imported":true},
        {"id":"fbdcd996-2084-4b3f-b5ae-253c8f9b4ce8","date":"2026-10-02","amountCents":5000,"payee":"Savings in","description":"",
         "categoryId":null,"accountId":"savings","transferId":"31f57e70-c0b0-423a-84ce-87fe3f2deda6","splitOf":null,
         "split":null,"note":"","imported":false}],
        "total":5,"incomeCents":0,"expenseCents":14250}
        """
        let list = try decode(FinanceTransactionList.self, json)
        #expect(list.total == 5)
        #expect(list.expenseCents == 14250)
        #expect(list.transactions[1].split == FinanceSplitInfo(parts: 1, remainderCents: -7000))
        #expect(list.transactions[2].splitOf == "04272196-fca1-44de-a5aa-39aab8291e9a")
        #expect(list.transactions[2].title == "Book")
        #expect(list.transactions[2].imported)
        #expect(list.transactions[3].transferId != nil)
        #expect(list.transactions[0].accountId == nil)
        #expect(list.transactions[0].day == Day(year: 2026, month: 10, day: 4))

        let groups = FinanceDayGroup.groups(list.transactions)
        #expect(groups.map(\.date) == ["2026-10-04", "2026-10-03", "2026-10-02"])
        #expect(groups[1].items.map(\.payee) == ["Amazon", ""])
    }

    @Test func decodesSummaryAndBalances() throws {
        let summary = try decode(FinanceSummary.self, """
        {"currency":"EUR","incomeCents":0,"expenseCents":14250,"count":3,
         "months":[{"month":"2026-10","incomeCents":0,"expenseCents":14250}],
         "categories":[{"categoryId":"shopping","incomeCents":0,"expenseCents":7000,"count":1},
                       {"categoryId":null,"incomeCents":100,"expenseCents":0,"count":1}]}
        """)
        #expect(summary.months.first?.month == "2026-10")
        #expect(summary.categories[1].categoryId == nil)

        let at = try decode(FinanceAccountsAt.self, """
        {"at":"2026-10-02","accounts":[{"id":"giro","name":"Giro","color":"#3b82f6","icon":"","openingCents":10000,
         "position":0,"balanceCents":5000}]}
        """)
        #expect(at.at == "2026-10-02")
        let now = try decode(FinanceAccountsAt.self, #"{"at":null,"accounts":[]}"#)
        #expect(now.at == nil)
    }

    @Test func decodesChangesAndTheirUndo() throws {
        let change = try decode(FinanceChangeResult.self, """
        {"ok":true,"changed":2,"added":[],"inverse":[{"action":"add","id":"f7c0de00-8fb4-4453-ad26-553842852f51",
         "date":"2026-10-01","amountCents":-5000,"payee":"Giro out","description":"","categoryId":null,"accountId":"giro",
         "transferId":null,"splitOf":null,"note":""}]}
        """)
        #expect(change.changed == 2)
        #expect(change.linked == nil)
        // The inverse goes back as it came: amounts as whole numbers, nulls as null.
        let body = try APIClient.encoder.encode(JSONValue.object(["ops": .array(change.inverse)]))
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""amountCents":-5000"#))
        #expect(text.contains(#""categoryId":null"#))

        let auto = try decode(FinanceChangeResult.self,
                              #"{"ok":true,"changed":0,"added":[],"inverse":[],"linked":3,"splits":1}"#)
        #expect(auto.linked == 3 && auto.splits == 1)

        let imported = try decode(FinanceImportResult.self,
                                  #"{"added":2,"duplicates":[0,3],"ids":["a","b"],"transfers":1,"splits":0}"#)
        #expect(imported.duplicates == [0, 3])
        let dry = try decode(FinanceImportResult.self, #"{"added":0,"duplicates":[],"ids":[]}"#)
        #expect(dry.transfers == nil)

        let categorized = try decode(FinanceCategorizeResult.self, """
        {"changed":1,"matched":1,"considered":2,"remaining":0,"ai":false,
         "inverse":[{"action":"add","id":"x","date":"2026-10-01","amountCents":-1}],
         "assignments":[{"id":"x","categoryId":"groceries","source":"similar"}]}
        """)
        #expect(categorized.matched == 1 && categorized.inverse.count == 1)
    }

    @Test func decodesTransferSuggestions() throws {
        let tx = { (id: String, cents: Int, account: String) in
            """
            {"id":"\(id)","date":"2026-10-01","amountCents":\(cents),"payee":"","description":"Umbuchung","categoryId":null,
             "accountId":"\(account)","transferId":null,"splitOf":null,"split":null,"note":"","imported":true}
            """
        }
        let res = try decode(FinanceTransferSuggestions.self,
                             #"{"pairs":[{"out":\#(tx("a", -5000, "giro")),"in":\#(tx("b", 5000, "savings"))}]}"#)
        #expect(res.pairs.first?.out.id == "a")
        #expect(res.pairs.first?.incoming.accountId == "savings")
        #expect(res.pairs.first?.id == "a|b")
    }

    @Test func buildsOps() throws {
        let fields = FinanceOp.Fields(date: "2026-10-01", amountCents: -1250, payee: "Bakery", description: "",
                                      categoryId: nil, accountId: "giro", note: "")
        let add = try #require(FinanceOp.add(fields).objectValue)
        #expect(add["action"] == .string("add"))
        #expect(add["amountCents"] == .number(-1250))
        #expect(add["categoryId"] == .null)
        let update = try #require(FinanceOp.update("id-1", fields).objectValue)
        #expect(update["action"] == .string("update") && update["id"] == .string("id-1"))
        let split = try #require(FinanceOp.split(booking: "b", parts: ["p1", "p2"]).objectValue)
        #expect(split["id"] == .string("b"))
        #expect(split["ids"] == .array([.string("p1"), .string("p2")]))
        #expect(FinanceOp.unlink("x").objectValue?["ids"] == .array([.string("x")]))
    }

    @Test func linksGroceriesToShoppingLists() throws {
        let links = try decode(FinanceShoppingLinks.self, """
        {"categoryIds":["groceries","bakery"],"lists":[{"id":"mon","date":"2026-06-01"},{"id":"thu","date":"2026-06-04"}]}
        """)
        #expect(links.list(for: "2026-06-05", categoryId: "groceries")?.id == "thu")
        #expect(links.list(for: "2026-06-02", categoryId: "bakery")?.id == "mon")
        #expect(links.list(for: "2026-06-07", categoryId: "groceries") == nil)
        #expect(links.list(for: "2026-06-04", categoryId: "housing") == nil)
        #expect(links.list(for: "2026-06-04", categoryId: nil) == nil)
    }
}

struct FinanceCategoryTreeTests {
    private func category(_ id: String, _ name: String, parent: String? = nil, position: Int = 0,
                          kind: FinanceCategoryKind = .expense) -> FinanceCategory {
        FinanceCategory(id: id, name: name, color: "#000000", icon: "", kind: kind, position: position, parentId: parent)
    }

    @Test func ordersDepthFirstBySiblingPosition() {
        let tree = FinanceCategoryTree([
            category("food", "Food", position: 1),
            category("bakery", "Bakery", parent: "groceries", position: 0),
            category("groceries", "Groceries", parent: "food", position: 1),
            category("out", "Eating out", parent: "food", position: 0),
            category("salary", "Salary", position: 0, kind: .income),
            category("orphan", "Orphan", parent: "gone", position: 2),
        ])
        #expect(tree.ordered.map(\.id) == ["salary", "food", "out", "groceries", "bakery", "orphan"])
        #expect(tree.ordered.map(\.depth) == [0, 0, 1, 1, 2, 0])
        #expect(tree.roots == ["salary", "food", "orphan"])
        #expect(tree.path("bakery") == "Food › Groceries › Bakery")
        #expect(tree.subtree("food") == ["food", "out", "groceries", "bakery"])
        #expect(tree.top(of: "bakery") == "food")
        #expect(tree.top(of: nil) == "")
        #expect(tree.top(of: "gone") == "")
        #expect(tree.parent(of: "groceries")?.id == "food")
        #expect(tree.moveTargets(for: "food").map(\.id) == ["salary", "orphan"])
    }

    @Test func survivesLoops() {
        let tree = FinanceCategoryTree([category("a", "A", parent: "b"), category("b", "B", parent: "a")])
        #expect(tree.ordered.count == 2)
        #expect(tree.roots.count == 1)
    }

    @Test func reordersSiblings() {
        let tree = FinanceCategoryTree([
            category("a", "A", position: 0), category("b", "B", position: 1), category("c", "C", position: 5),
        ])
        #expect(tree.reorder("c", by: -1).map { "\($0.0)=\($0.1)" } == ["c=1", "b=2"])
        #expect(tree.reorder("a", by: -1).isEmpty)
    }

    @Test func fitsTheSign() {
        #expect(FinanceCategoryTree.fits(category("x", "X", kind: .both), income: true))
        #expect(FinanceCategoryTree.fits(category("x", "X", kind: .income), income: true))
        #expect(!FinanceCategoryTree.fits(category("x", "X", kind: .income), income: false))
    }

    @Test func breaksDownByCategoryWithSubcategories() {
        let tree = FinanceCategoryTree([
            category("food", "Food"), category("groceries", "Groceries", parent: "food"), category("car", "Car", position: 1),
        ])
        let summary = FinanceSummary(currency: "EUR", incomeCents: 0, expenseCents: 1000, count: 4, months: [], categories: [
            FinanceSummaryCategory(categoryId: "groceries", incomeCents: 0, expenseCents: 400, count: 1),
            FinanceSummaryCategory(categoryId: "food", incomeCents: 0, expenseCents: 100, count: 1),
            FinanceSummaryCategory(categoryId: "car", incomeCents: 0, expenseCents: 300, count: 1),
            FinanceSummaryCategory(categoryId: nil, incomeCents: 0, expenseCents: 200, count: 1),
        ])
        let rows = FinanceCategoryBreakdown.rows(summary, tree: tree, income: false)
        #expect(rows.map(\.id) == ["food", "car", "none"])
        #expect(rows[0].cents == 500)
        #expect(rows[0].children.map(\.id) == ["groceries", "food:direct"])
    }
}

struct FinanceMoneyTests {
    @Test func parsesAmountsAsTypedOrExported() {
        let cases: [(String, Int?)] = [
            ("12", 1200), ("12.5", 1250), ("12,50", 1250), ("-1.234,56", -123456), ("1,234.56", 123456),
            ("-3,20 €", -320), ("€ 1 234,00", 123400), ("(45.00)", -4500), ("12,50-", -1250), ("+7", 700),
            ("1.234", 123400), ("abc", nil), ("", nil),
        ]
        for (input, cents) in cases {
            #expect(FinanceMoney.parse(input) == cents, "\(input)")
        }
        #expect(FinanceMoney.parse("1.234", decimal: ".") == nil)
        #expect(FinanceMoney.parse("1,5", decimal: ",") == 150)
    }

    @Test func writesEditableAmounts() {
        #expect(FinanceMoney.input(-123456, locale: Locale(identifier: "de_DE")) == "1234,56")
        #expect(FinanceMoney.input(5, locale: Locale(identifier: "en_US")) == "0.05")
        let formatted = FinanceMoney.format(-4250, currency: "EUR", locale: Locale(identifier: "en_US"))
        #expect(formatted.contains("42.50") && formatted.contains("-"))
        #expect(FinanceMoney.format(4250, currency: "EUR", sign: true, locale: Locale(identifier: "en_US")).contains("+"))
        #expect(!FinanceMoney.format(4250, currency: "EUR", whole: true, locale: Locale(identifier: "en_US")).contains("."))
    }

    @Test func roundTripsColors() {
        #expect(FinanceColor.hex(FinanceColor.color("#22c55e")) == "#22c55e")
        #expect(FinanceColor.hex(FinanceColor.color("#3B82F6")) == "#3b82f6")
        #expect(FinanceColor.next(used: ["#3b82f6", "#EC4899"]) == "#8b5cf6")
    }

    @Test func readsRangeDrafts() {
        #expect(FinanceRangeDraft(low: "", high: "").parsed == .ok(nil))
        #expect(FinanceRangeDraft(low: "100", high: "").parsed == .ok(FinanceCentsRange(lowCents: 10000, highCents: 10000)))
        #expect(FinanceRangeDraft(low: "200", high: "100").parsed == .invalid)
        #expect(FinanceRangeDraft(low: "x", high: "").parsed == .invalid)
        #expect(FinanceRangeDraft(low: "-5", high: "").parsed == .invalid)
    }
}

struct FinancePeriodTests {
    @Test func coversMonthsAndYears() {
        let month = FinancePeriod(mode: .month, year: 2024, month: 2)
        #expect(month.range.from == "2024-02-01" && month.range.to == "2024-02-29")
        #expect(month.stepped(-2) == FinancePeriod(mode: .month, year: 2023, month: 12))
        #expect(month.stepped(11) == FinancePeriod(mode: .month, year: 2025, month: 1))
        let year = FinancePeriod(mode: .year, year: 2026, month: 5)
        #expect(year.range.from == "2026-01-01" && year.range.to == "2026-12-31")
        #expect(year.stepped(1).year == 2027)
        #expect(FinancePeriod(mode: .all, year: 2026, month: 5).range.from == nil)
    }

    @Test func picksTheBalanceDay() {
        let today = Day(year: 2026, month: 10, day: 30)
        #expect(FinancePeriod(mode: .month, year: 2026, month: 10).balanceDay(today: today) == "2026-10-30")
        #expect(FinancePeriod(mode: .month, year: 2026, month: 9).balanceDay(today: today) == "2026-09-30")
        #expect(FinancePeriod(mode: .all, year: 2026, month: 9).balanceDay(today: today) == nil)
    }

    @Test func comparesWithOtherPeriods() {
        let today = Day(year: 2026, month: 10, day: 30)
        let month = FinancePeriod(mode: .month, year: 2026, month: 1).comparisonRanges(today: today)
        #expect(month.map(\.key) == [.month, .lastMonth])
        #expect(month[1].from == "2025-12-01" && month[1].to == "2025-12-31")
        let year = FinancePeriod(mode: .year, year: 2026, month: 1).comparisonRanges(today: today)
        #expect(year.map(\.key) == [.year, .lastYear])
        // Averages end with the last completed month.
        #expect(year[0].to == "2026-09-30" && year[1].to == "2025-12-31")
        #expect(FinancePeriod(mode: .all, year: 2026, month: 1).comparisonRanges(today: today)[0].from == nil)
        #expect(financeMonthsBetween("2025-11", "2026-02") == 4)
    }

    @Test func averagesPerMonth() {
        let summary = FinanceSummary(currency: "EUR", incomeCents: 3000, expenseCents: 1001, count: 2,
                                     months: [FinanceSummaryMonth(month: "2026-07", incomeCents: 3000, expenseCents: 1001)],
                                     categories: [FinanceSummaryCategory(categoryId: nil, incomeCents: 0, expenseCents: 1001, count: 1)])
        let column = FinanceComparison.from(summary, range: FinanceComparisonRange(key: .year, average: true, from: "2026-01-01", to: "2026-09-30"))
        #expect(column.first == "2026-07" && column.months == 3)
        #expect(column.incomeCents == 1000 && column.expenseCents == 334)
        #expect(column.categories[""]?.expense == 334)
    }

    @Test func measuresAgainstTheBenchmark() {
        let range = FinanceCentsRange(lowCents: 1000, highCents: 2000)
        #expect(FinanceStanding.of(500, range: range) == .below(50))
        #expect(FinanceStanding.of(3000, range: range) == .above(50))
        #expect(FinanceStanding.of(1200, range: range) == .lowerHalf)
        #expect(FinanceStanding.of(1800, range: range) == .upperHalf)
        #expect(FinanceStanding.of(1000, range: FinanceCentsRange(lowCents: 1000, highCents: 1000)) == .on)
        #expect(FinanceStanding.of(5, range: FinanceCentsRange(lowCents: 0, highCents: 0)) == .aboveZero)
        #expect(FinanceStanding.below(5).tone(higherIsGood: false) == true)
    }
}

struct FinanceSelectionTests {
    private func tx(_ id: String, _ cents: Int, transfer: String? = nil, splitOf: String? = nil,
                    split: FinanceSplitInfo? = nil) -> FinanceTransaction {
        FinanceTransaction(id: id, date: "2026-10-01", amountCents: cents, payee: id, description: "", categoryId: nil,
                           accountId: nil, transferId: transfer, splitOf: splitOf, split: split, note: "", imported: false)
    }

    @Test func picksTheBookingAndWhatCanBeCombined() {
        let plain = [tx("a", -300), tx("b", -1000), tx("c", 1000)]
        #expect(FinanceStore.splitBooking(of: plain)?.id == "b")
        #expect(FinanceStore.canLink(plain) && FinanceStore.canSplit(plain))
        let leg = [tx("a", -300), tx("b", -1000, transfer: "t")]
        #expect(FinanceStore.canLink(leg) && !FinanceStore.canSplit(leg))
        let part = [tx("a", -300, splitOf: "x"), tx("b", -1000)]
        #expect(!FinanceStore.canLink(part))
        #expect(!FinanceStore.canLink([tx("a", 1)]))
    }
}

/// Counted phrases in English (the tests run in English).
struct FinanceTextTests {
    @Test func countsInTheRightNumber() {
        #expect(FinanceText.inflected("^[\(1) transaction](inflect: true) deleted") == "1 transaction deleted")
        #expect(FinanceText.inflected("^[\(3) transaction](inflect: true) deleted") == "3 transactions deleted")
        #expect(FinanceStore.combinedText(transfers: 1, splits: 0) == "1 transfer combined")
        #expect(FinanceStore.combinedText(transfers: 2, splits: 1) == "2 transfers, 1 split booking combined")
    }

    @Test func namesTheMonthsOfAnAverage() {
        func column(first: String) -> FinanceComparison {
            let summary = FinanceSummary(currency: "EUR", incomeCents: 0, expenseCents: 100, count: 1,
                                         months: [FinanceSummaryMonth(month: first, incomeCents: 0, expenseCents: 100)],
                                         categories: [])
            return FinanceComparison.from(summary, range: FinanceComparisonRange(key: .year, average: true,
                                                                                 from: "2026-01-01", to: "2026-09-30"))
        }
        #expect(column(first: "2026-09").detail?.hasSuffix(" · 1 month") == true)
        #expect(column(first: "2026-07").detail?.hasSuffix(" · 3 months") == true)
    }
}

struct FinanceMonthlyTests {
    @Test func aYearHasAllItsMonths() {
        let summary = FinanceSummary(currency: "EUR", incomeCents: 500, expenseCents: 200, count: 2,
                                     months: [FinanceSummaryMonth(month: "2026-03", incomeCents: 500, expenseCents: 200)],
                                     categories: [])
        let year = FinanceMonthlyChart.months(summary, period: FinancePeriod(mode: .year, year: 2026, month: 0))
        #expect(year.count == 12)
        #expect(year.first?.month == "2026-01" && year.last?.month == "2026-12")
        #expect(year[2].incomeCents == 500 && year[3].incomeCents == 0)
        // All time: only the months with transactions.
        #expect(FinanceMonthlyChart.months(summary, period: FinancePeriod(mode: .all, year: 2026, month: 0)).map(\.month) == ["2026-03"])
    }
}

/// Edit → Undo / Redo: each change's inverse ops in the undo manager, undo and redo chained.
@MainActor
struct FinanceUndoTests {
    private final class Log {
        var calls: [(ops: [JSONValue], redoing: Bool)] = []
        var used = 0
    }

    private func registry(_ manager: UndoManager, log: Log) -> FinanceUndoRegistry {
        let registry = FinanceUndoRegistry()
        registry.attach(manager)
        registry.apply = { ops, redoing in
            log.calls.append((ops, redoing))
            // What reverts it: the ops marked once more.
            return ops.map { .string("not " + ($0.stringValue ?? "")) }
        }
        registry.used = { _ in log.used += 1 }
        return registry
    }

    private func manager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private func register(_ registry: FinanceUndoRegistry, _ manager: UndoManager, _ ops: [JSONValue]) -> FinanceUndoToken? {
        manager.beginUndoGrouping()
        defer { manager.endUndoGrouping() }
        return registry.register(ops)
    }

    @Test func undoesAndRedoes() async {
        let manager = manager(), log = Log()
        let registry = registry(manager, log: log)
        #expect(register(registry, manager, [.string("delete a")]) != nil)
        #expect(manager.canUndo && !manager.canRedo)

        manager.undo()
        _ = await registry.running?.value
        #expect(log.calls.count == 1 && log.calls[0].ops == [.string("delete a")] && !log.calls[0].redoing)
        #expect(log.used == 1)
        #expect(manager.canRedo && !manager.canUndo)

        manager.redo()
        _ = await registry.running?.value
        #expect(log.calls.count == 2 && log.calls[1].ops == [.string("not delete a")] && log.calls[1].redoing)
        #expect(manager.canUndo && !manager.canRedo)

        manager.undo()
        _ = await registry.running?.value
        #expect(log.calls.last?.ops == [.string("not not delete a")])
    }

    @Test func theToastTakesItsEntryOut() {
        let manager = manager(), log = Log()
        let registry = registry(manager, log: log)
        let first = register(registry, manager, [.string("a")])
        let second = register(registry, manager, [.string("b")])
        #expect(first != nil && second != nil)
        registry.forget(second!)
        #expect(manager.canUndo) // the first one is still there
        registry.forgetAll()
        #expect(!manager.canUndo)
        #expect(log.calls.isEmpty)
    }

    @Test func nothingWithoutAnUndoManager() {
        let registry = FinanceUndoRegistry()
        #expect(registry.register([.string("a")]) == nil)
    }
}

/// The finance page's reads kept on the device: shown at once, kept while the server is down,
/// dropped when it refuses; changes wait meanwhile.
@MainActor
struct FinanceSavedCopyTests {
    /// One answer for every read (the stub answers a host with one body): the overview's, the
    /// list's, the balances' and the summary's fields side by side.
    private static let body = """
    {"currency":"EUR","csvMappings":[],"categories":[],"accounts":[],"transactions":[],"total":7,
     "incomeCents":100,"expenseCents":0,"count":1,"months":[],"configured":false,"pairs":[]}
    """

    private func store(_ host: String, cache: ResponseCache) -> FinanceStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FinanceStubProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://\(host)")!, token: nil,
                               session: URLSession(configuration: config), cache: cache)
        let family = FamilySummary(id: "f1", name: "Family", role: .editor, memberCount: 1)
        return FinanceStore(family: FamilyContext(family: family, api: FamilyAPI(client: client, familyID: "f1")))
    }

    @Test func showsTheCopyWhileTheServerIsDown() async {
        let host = "finance-copy.example"
        let cache = ResponseCache(directory: FileManager.default.temporaryDirectory
            .appending(path: "ohana-finance-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
        FinanceStubProtocol.answer(host, status: 200, body: Self.body)
        let first = store(host, cache: cache)
        await first.reloadAll()
        await first.loadSummary()
        #expect(first.savedCopy == nil && first.canEdit)
        ResponseCache.waitForWrites()

        FinanceStubProtocol.answer(host, status: 503, body: #"{"error":"down"}"#)
        let offline = store(host, cache: cache)
        await offline.reloadAll()
        await offline.loadSummary()
        #expect(offline.overview?.currency == "EUR")
        #expect(offline.list?.total == 7)
        #expect(offline.summary?.incomeCents == 100)
        #expect(offline.comparisons != nil)
        #expect(offline.savedCopy?.updating == false)
        #expect(offline.error == nil)
        #expect(!offline.canEdit)

        // Back again: the server's answers, changes allowed.
        FinanceStubProtocol.answer(host, status: 200, body: Self.body)
        await offline.reloadAll()
        #expect(offline.savedCopy == nil && offline.canEdit)

        // Refused: as if nothing had been kept.
        FinanceStubProtocol.answer(host, status: 404, body: #"{"error":"Not found"}"#)
        let refused = store(host, cache: cache)
        await refused.reloadAll()
        #expect(refused.overview == nil && refused.list == nil)
        #expect(refused.savedCopy == nil)
        #expect(refused.error != nil)
    }
}

/// Answers every request with what `answer` set (`ResponseCacheTests`' stub isn't in the
/// generated project yet).
nonisolated final class FinanceStubProtocol: URLProtocol {
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

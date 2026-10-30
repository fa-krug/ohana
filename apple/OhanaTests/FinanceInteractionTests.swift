import Foundation
import Testing
@testable import Ohana

/// The import's shortcut for a known bank: a saved mapping for the file's header skips the
/// mapping step.
struct FinanceImportStepTests {
    private let csv = "Datum;Empfänger;Verwendungszweck;Betrag\n02.03.2026;REWE;Einkauf;-45,99\n03.03.2026;Arbeitgeber;Gehalt;2500,00\n"

    @Test func findsTheSavedMappingByTheHeader() {
        let guess = FinanceCSV.guessMapping(csv, encoding: .utf8)
        #expect(guess.signature == "Datum;Empfänger;Verwendungszweck;Betrag")
        var saved = guess
        saved.description = []
        saved.accountId = "giro"
        let other = FinanceCSVMapping(signature: "Date,Amount", encoding: .utf8, delimiter: ",", skipRows: 0, hasHeader: true,
                                      date: 0, dateFormat: .iso, amount: 1, debit: nil, credit: nil, decimal: ".",
                                      payee: nil, description: [])
        #expect(FinanceImportStep.savedMapping(for: guess, in: [other, saved]) == saved)
        #expect(FinanceImportStep.savedMapping(for: guess, in: [other]) == nil)
    }

    @Test func aFileWithoutHeaderNeverMatches() {
        var guess = FinanceCSV.guessMapping(csv, encoding: .utf8)
        guess.signature = ""
        var saved = guess
        saved.accountId = "giro"
        #expect(FinanceImportStep.savedMapping(for: guess, in: [saved]) == nil)
    }

    @Test func skipsToTheReviewOnlyWhenTheSavedMappingReadsRows() throws {
        let guess = FinanceCSV.guessMapping(csv, encoding: .utf8)
        let saved = try #require(FinanceImportStep.savedMapping(for: guess, in: [guess]))
        let rows = FinanceCSV.map(FinanceCSV.table(csv, mapping: saved).rows, mapping: saved).ok
        #expect(rows.count == 2)
        #expect(FinanceImportStep.first(saved: saved, readableRows: rows.count) == .review)
        #expect(FinanceImportStep.first(saved: saved, readableRows: 0) == .map)
        #expect(FinanceImportStep.first(saved: nil, readableRows: rows.count) == .map)
    }
}

/// The transaction table's sort orders.
struct FinanceTableSortTests {
    private func row(_ id: String, _ date: String, _ cents: Int, payee: String, category: String = "") -> FinanceTableRow {
        FinanceTableRow(transaction: FinanceTransaction(id: id, date: date, amountCents: cents, payee: payee, description: "",
                                                        categoryId: nil, accountId: nil, transferId: nil, splitOf: nil,
                                                        split: nil, note: "", imported: false),
                        category: category)
    }

    /// The server's order: newest day first, within a day the newest booked first.
    private var rows: [FinanceTableRow] {
        [row("c", "2026-10-03", -500, payee: "bäcker", category: "Food"),
         row("b2", "2026-10-02", 2000, payee: "Arbeit", category: "Salary"),
         row("b1", "2026-10-02", -1500, payee: "Zoo", category: "Fun"),
         row("a", "2026-10-01", -1500, payee: "apotheke", category: "Health")]
    }

    @Test func newestFirstKeepsTheServersOrderAndOldestFirstReversesIt() {
        #expect(FinanceTableSort.sorted(rows, by: FinanceTableSort.newestFirst).map(\.id) == ["c", "b2", "b1", "a"])
        let oldest = [KeyPathComparator(\FinanceTableRow.date)]
        #expect(FinanceTableSort.sorted(rows, by: oldest).map(\.id) == ["a", "b1", "b2", "c"])
        #expect(FinanceTableSort.sorted(rows, by: []).map(\.id) == ["c", "b2", "b1", "a"])
    }

    @Test func sortsByAmountStably() {
        let up = [KeyPathComparator(\FinanceTableRow.amountCents)]
        // b1 and a are both −15,00: they keep the server's order.
        #expect(FinanceTableSort.sorted(rows, by: up).map(\.id) == ["b1", "a", "c", "b2"])
        let down = [KeyPathComparator(\FinanceTableRow.amountCents, order: .reverse)]
        #expect(FinanceTableSort.sorted(rows, by: down).map(\.id) == ["b2", "c", "b1", "a"])
    }

    @Test func sortsNamesLikeTheFinder() {
        let byPayee = [KeyPathComparator(\FinanceTableRow.title, comparator: .localizedStandard)]
        #expect(FinanceTableSort.sorted(rows, by: byPayee).map(\.title) == ["apotheke", "Arbeit", "bäcker", "Zoo"])
        let byCategory = [KeyPathComparator(\FinanceTableRow.category, comparator: .localizedStandard, order: .reverse)]
        #expect(FinanceTableSort.sorted(rows, by: byCategory).map(\.category) == ["Salary", "Health", "Fun", "Food"])
    }
}

/// The editor's draft: what counts as a change, and what Save sends.
struct FinanceTransactionDraftTests {
    @Test func theSameDayIsNoChange() {
        let t = FinanceTransaction(id: "t", date: "2026-10-05", amountCents: -1250, payee: "REWE", description: "",
                                   categoryId: "food", accountId: "giro", transferId: nil, splitOf: nil, split: nil,
                                   note: "", imported: false)
        let original = FinanceTransactionDraft(t)
        var draft = original
        draft.date = Day.calendar.date(byAdding: .hour, value: 5, to: draft.date)!
        #expect(draft == original)
        draft.date = Day(year: 2026, month: 10, day: 6).date
        #expect(draft != original)
        draft = original
        draft.note = "Wocheneinkauf"
        #expect(draft != original)
    }

    @Test func theKindSignsTheAmount() {
        var draft = FinanceTransactionDraft()
        #expect(draft.cents == nil && !draft.amountInvalid)
        draft.amount = "12,50"
        #expect(draft.cents == -1250)
        draft.income = true
        #expect(draft.cents == 1250)
        #expect(draft.fields?.amountCents == 1250)
        draft.amount = "0"
        #expect(draft.cents == nil && draft.amountInvalid && draft.fields == nil)
        draft.amount = "abc"
        #expect(draft.amountInvalid)
    }
}

struct FinanceFilterCountTests {
    @Test func countsTheFiltersThatAreOn() {
        var filter = FinanceFilter()
        #expect(filter.activeCount == 0 && !filter.isActive)
        filter.q = "rewe"
        #expect(filter.activeCount == 0)
        filter.category = "none"
        filter.kind = .expense
        #expect(filter.activeCount == 2 && filter.isActive)
        filter.account = "giro"
        #expect(filter.activeCount == 3)
    }
}

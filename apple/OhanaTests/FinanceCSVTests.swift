import Foundation
import Testing
@testable import Ohana

/// Bank statement CSV files (the web's tests/finance-csv.test.ts, ported).
struct FinanceCSVTests {
    @Test func splitsCellsWithQuotesAndNewlines() {
        let text = "a;\"b;c\";\"say \"\"hi\"\"\"\r\n1;\"two\nlines\";3\n\n"
        #expect(FinanceCSV.parse(text, delimiter: ";") == [["a", "b;c", "say \"hi\""], ["1", "two\nlines", "3"]])
        #expect(FinanceCSV.detectDelimiter("a,b,c\n1,2,3\n4,5,6") == ",")
        #expect(FinanceCSV.detectDelimiter("a;b;c\n1,5;2;3\n4;5,5;6") == ";")
        #expect(FinanceCSV.detectDelimiter("a\tb\n1\t2") == "\t")
    }

    @Test func readsDatesInTheCommonBankFormats() {
        #expect(FinanceCSV.parseDate("31.12.2026", format: .german) == "2026-12-31")
        #expect(FinanceCSV.parseDate("1.2.26", format: .germanShort) == "2026-02-01")
        #expect(FinanceCSV.parseDate("2026-02-30", format: .iso) == nil)
        #expect(FinanceCSV.parseDate("12/31/2026", format: .american) == "2026-12-31")
        #expect(FinanceCSV.detectDateFormat(["01.03.2026", "15.03.2026"]) == .german)
        #expect(FinanceCSV.detectDateFormat(["03/04/2026", "03/25/2026"]) == .american)
        #expect(FinanceCSV.detectDateFormat(["03/04/2026", "25/03/2026"]) == .european)
        #expect(FinanceCSV.detectDateFormat(["x"]) == nil)
    }

    @Test func decodesUTF8AndFallsBackToWindows1252() throws {
        #expect(try FinanceCSV.decode(Data("\u{FEFF}Empfänger".utf8)).text == "Empfänger")
        let latin = Data([0x45, 0x6d, 0x70, 0x66, 0xe4, 0x6e, 0x67, 0x65, 0x72])
        let decoded = try FinanceCSV.decode(latin)
        #expect(decoded.text == "Empfänger" && decoded.encoding == .windows1252)
        #expect(throws: FinanceCSV.DecodeError.self) { try FinanceCSV.decode(latin, encoding: .utf8) }
    }

    @Test func mapsAGermanBankExportWithAPreamble() {
        let text = [
            "\"Kontonummer:\";\"DE12 3456\";",
            "\"Zeitraum:\";\"01.03.2026 - 31.03.2026\";",
            "",
            "\"Buchungstag\";\"Valuta\";\"Auftraggeber/Empfänger\";\"Verwendungszweck\";\"Betrag (EUR)\"",
            "\"02.03.2026\";\"02.03.2026\";\"REWE Markt\";\"Einkauf Karte\";\"-45,99\"",
            "\"03.03.2026\";\"03.03.2026\";\"Arbeitgeber GmbH\";\"Gehalt März\";\"3.250,00\"",
            "\"04.03.2026\";\"04.03.2026\";\"Stadtwerke\";\"Abschlag\";\"-89,00\"",
        ].joined(separator: "\n")
        let m = FinanceCSV.guessMapping(text, encoding: .utf8)
        #expect(m.delimiter == ";" && m.skipRows == 2 && m.hasHeader && m.date == 0)
        #expect(m.dateFormat == .german && m.amount == 4 && m.payee == 2)
        #expect(m.description == [3] && m.decimal == ",")
        let table = FinanceCSV.table(text, mapping: m)
        #expect(table.header.first == "Buchungstag")
        let result = FinanceCSV.map(table.rows, mapping: m)
        #expect(result.errors.isEmpty)
        #expect(result.ok.map { "\($0.date)|\($0.amountCents)|\($0.payee)|\($0.description)" } == [
            "2026-03-02|-4599|REWE Markt|Einkauf Karte",
            "2026-03-03|325000|Arbeitgeber GmbH|Gehalt März",
            "2026-03-04|-8900|Stadtwerke|Abschlag",
        ])
    }

    @Test func mapsDebitCreditColumnsAndEnglishFormats() {
        let text = [
            "Date,Description,Debit,Credit,Balance",
            "03/01/2026,Coffee shop,3.50,,996.50",
            "03/02/2026,Paycheck,,2000.00,2996.50",
            "03/15/2026,Rent,1200.00,,1796.50",
        ].joined(separator: "\n")
        var m = FinanceCSV.guessMapping(text, encoding: .utf8)
        #expect(m.delimiter == "," && m.dateFormat == .american)
        #expect(m.amount == nil && m.debit == 2 && m.credit == 3)
        m.payee = nil
        m.description = [1]
        let ok = FinanceCSV.map(FinanceCSV.table(text, mapping: m).rows, mapping: m).ok
        #expect(ok.map { "\($0.date)|\($0.amountCents)|\($0.description)" } == [
            "2026-03-01|-350|Coffee shop", "2026-03-02|200000|Paycheck", "2026-03-15|-120000|Rent",
        ])
    }

    @Test func reportsRowsThatDontParse() {
        let good = (1...8).map { "0\($0).03.2026;-\($0),00;ok" }
        let text = (["Datum;Betrag;Text"] + good + ["kein Datum;-2,00;x", "10.03.2026;abc;y"]).joined(separator: "\n")
        let m = FinanceCSV.guessMapping(text, encoding: .utf8)
        #expect(m.date == 0 && m.amount == 1)
        let result = FinanceCSV.map(FinanceCSV.table(text, mapping: m).rows, mapping: m)
        #expect(result.ok.count == 8)
        #expect(result.errors.map(\.line) == [8, 9])
        #expect(result.errors.map(\.reason) == [.date, .amount])
    }

    @Test func savesMappingsAsTheWebReadsThem() throws {
        let mapping = FinanceCSVMapping(signature: "Date,Debit,Credit", encoding: .windows1252, delimiter: ",", skipRows: 1,
                                        hasHeader: true, date: 0, dateFormat: .american, amount: nil, debit: 1, credit: 2,
                                        decimal: ".", payee: nil, description: [3], accountId: "giro", autoTransfers: false)
        let object = try #require(mapping.json.objectValue)
        // Nullable columns are written as null (the web reads `amount: null` as debit and credit).
        #expect(object["amount"] == .null)
        #expect(object["payee"] == .null)
        #expect(object["encoding"] == .string("windows-1252"))
        #expect(object["dateFormat"] == .string("MM/DD/YYYY"))
        #expect(object["accountId"] == .string("giro"))
        #expect(FinanceCSVMapping(json: mapping.json) == mapping)
        let fresh = FinanceCSVMapping(signature: "", encoding: .utf8, delimiter: ";", skipRows: 0, hasHeader: false, date: 0,
                                      dateFormat: .german, amount: 1, debit: nil, credit: nil, decimal: ",", payee: 2,
                                      description: [])
        #expect(fresh.json.objectValue?["accountId"] == nil)
    }

    @Test func limitsTextsAsTheServerCounts() {
        #expect(FinanceCSV.limit("abc", 2) == "ab")
        #expect(FinanceCSV.limit("a😀b", 2) == "a")
        #expect(FinanceCSV.limit("a😀b", 3) == "a😀")
    }

    @Test func parsesRowsForTheImport() {
        let row = FinanceParsedRow(line: 0, date: "2026-03-02", amountCents: -4599, payee: "REWE", description: "")
        #expect(row.json.objectValue?["amountCents"] == .number(-4599))
        #expect(row.json.objectValue?["line"] == nil)
    }
}

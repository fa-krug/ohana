import Foundation
import Testing
@testable import Ohana

/// Reading a scanned receipt: the total paid, the day and the shop.
struct ReceiptParserTests {
    private let today = Day(year: 2026, month: 10, day: 20)

    private func parse(_ lines: [String], monthFirst: Bool = false) -> ReceiptScan {
        ReceiptParser.parse(lines, today: today, monthFirst: monthFirst)
    }

    @Test func readsAGermanSupermarketReceipt() {
        let scan = parse([
            "REWE",
            "REWE Markt GmbH",
            "Hauptstraße 12",
            "10115 Berlin",
            "Tel.: 030 1234567",
            "UID Nr.: DE812706034",
            "EUR",
            "BIO VOLLMILCH  1,19 B",
            "BROT  2,49 B",
            "WEIN ROT  8,99 A",
            "KAFFEE  10,80 A",
            "--------------------",
            "SUMME  EUR 23,47",
            "====================",
            "Geg. BAR  EUR 50,00",
            "Rückgeld BAR  EUR 26,53",
            "Steuer  %  Netto  Steuer  Brutto",
            "A=  19,0%  15,61  2,97  18,58",
            "B=  7,0%  4,57  0,32  4,89",
            "Gesamtbetrag  20,18  3,29  23,47",
            "12.10.26 18:43  Bon-Nr.:4711",
            "Markt:1234  Kasse:2  Bed.:123456",
        ])
        #expect(scan == ReceiptScan(amountCents: 2347, date: Day(year: 2026, month: 10, day: 12), shop: "REWE"))
    }

    @Test func readsAnAldiSuedReceipt() {
        let scan = parse([
            "ALDI SÜD",
            "ALDI SE & Co. KG",
            "Musterweg 5",
            "80331 München",
            "Bananen  1,49 A",
            "Butter  2,29 A",
            "Spülmittel  0,95 B",
            "Toilettenpapier  7,85 B",
            "Summe  12,58",
            "Kartenzahlung  12,58",
            "Datum: 14.10.2026  Uhrzeit: 09:15",
        ])
        #expect(scan == ReceiptScan(amountCents: 1258, date: Day(year: 2026, month: 10, day: 14), shop: "Aldi Süd"))
    }

    @Test func readsAnAmericanReceiptMonthFirst() {
        let scan = parse([
            "Walmart",
            "(555) 123-4567  Mgr: Jane Doe",
            "123 Main St",
            "Springfield, IL 62701",
            "BANANAS  0.58 N",
            "MILK 1 GAL  3.48 F",
            "TV STAND  38.49 X",
            "SUBTOTAL  42.55",
            "TAX 1  7.000 %  3.12",
            "TOTAL  $45.67",
            "CASH TEND  50.00",
            "CHANGE DUE  4.33",
            "10/12/2026  14:22:05",
        ], monthFirst: true)
        #expect(scan == ReceiptScan(amountCents: 4567, date: Day(year: 2026, month: 10, day: 12), shop: "Walmart"))
    }

    @Test func readsABritishReceiptDayFirst() {
        let scan = parse([
            "TESCO",
            "Express",
            "VAT No: GB 220 4302 31",
            "MILK  £1.45",
            "BREAD  £1.10",
            "SUBTOTAL  £12.30",
            "BALANCE DUE  £12.30",
            "VISA  £12.30",
            "05/10/2026 08:01",
        ])
        #expect(scan == ReceiptScan(amountCents: 1230, date: Day(year: 2026, month: 10, day: 5), shop: "Tesco"))
    }

    @Test func aSmallBakeryKeepsItsOwnNameCapitalized() {
        let scan = parse([
            "Kassenbon",
            "BAECKEREI MUELLER",
            "Kirchgasse 3",
            "35037 Marburg",
            "Tel. 06421 12345",
            "2x Brötchen  0,90",
            "1x Kuchen  3,20",
            "Summe  4,10",
            "Bar  5,00",
            "Rückgeld  0,90",
            "08.10.2026 07:12",
        ])
        #expect(scan == ReceiptScan(amountCents: 410, date: Day(year: 2026, month: 10, day: 8), shop: "Baeckerei Mueller"))
    }

    @Test func aDepositReturnIsNeverTheTotal() {
        let withTotal = parse(["EDEKA Schulze", "Wasser 6x1,5l  2,94 B", "Pfand  1,50 A", "Leergut  -3,00 A", "SUMME  1,44"])
        #expect(withTotal.amountCents == 144)
        #expect(withTotal.shop == "EDEKA")

        // Without a total line, the largest amount bought; the deposit return isn't one.
        let withoutTotal = parse(["Kiosk am Markt", "Zeitung  2,80", "Leergut  -0,25", "Kaugummi  1,20"])
        #expect(withoutTotal.amountCents == 280)
        #expect(withoutTotal.shop == "Kiosk am Markt")

        // A trailing minus counts too, and a refund has no total paid.
        #expect(parse(["Leergutbon", "Leergut  3,00-", "SUMME  3,00-"]).amountCents == nil)
    }

    @Test func zuZahlenTakesTheAmountOnTheNextLine() {
        let scan = parse([
            "LIDL",
            "Hafermilch  1,19 A",
            "Äpfel 1kg  2,49 A",
            "Zwischensumme  3,68",
            "zu zahlen",
            "3,68",
            "Bar  20,00",
            "Rückgeld  16,32",
        ])
        #expect(scan.amountCents == 368)
        #expect(scan.shop == "Lidl")
    }

    @Test func readsAmountsWithThousandsSeparatorsAndCurrencies() {
        #expect(parse(["Endbetrag  EUR 1.234,56"]).amountCents == 123_456)
        #expect(parse(["Grand Total  $1,234.56"]).amountCents == 123_456)
        #expect(parse(["Total  12.34 B"]).amountCents == 1234)
        #expect(parse(["Betrag  12,34€"]).amountCents == 1234)
        #expect(parse(["Keine Beträge hier"]).amountCents == nil)
    }

    @Test func aStrongTotalWinsOverAPlainOne() {
        let scan = parse(["Summe Artikel  3", "Gesamt  4,00", "Rabatt  -1,00", "Zahlbetrag  3,00"])
        #expect(scan.amountCents == 300)
    }

    @Test func skipsFutureImpossibleAndOldDates() {
        let scan = parse([
            "Gutschein gültig bis 31.12.2026",
            "Druck 31.02.2026",
            "Kunde seit 01.01.2020",
            "Datum 2026-10-19 12:00",
        ])
        #expect(scan.date == Day(year: 2026, month: 10, day: 19))
        #expect(parse(["21.10.2026"]).date == Day(year: 2026, month: 10, day: 21))
        #expect(parse(["22.10.2026"]).date == nil)
    }

    @Test func readsSlashDatesByWhichPartCanBeAMonth() {
        #expect(parse(["13/10/2026"], monthFirst: true).date == Day(year: 2026, month: 10, day: 13))
        #expect(parse(["10/13/2026"], monthFirst: false).date == Day(year: 2026, month: 10, day: 13))
        #expect(parse(["05/10/26"], monthFirst: true).date == Day(year: 2026, month: 5, day: 10))
        #expect(parse(["05/10/26"], monthFirst: false).date == Day(year: 2026, month: 10, day: 5))
    }

    @Test func findsTheChainBelowAGreeting() {
        #expect(parse(["Willkommen", "Ihr dm-drogerie markt", "Musterstr. 1"]).shop == "dm")
        #expect(parse(["Vielen Dank für Ihren Einkauf", "Netto Marken-Discount"]).shop == "Netto")
        #expect(parse(["Café Sonnenschein", "Netto  Steuer  Brutto"]).shop == "Café Sonnenschein")
        #expect(parse(["12.10.2026", "www.example.de", "Welcome"]).shop == nil)
    }

    @Test func groupsPiecesIntoLines() {
        let pieces = [
            ReceiptTextPiece(text: "23,47", x: 0.80, y: 0.505, height: 0.02),
            ReceiptTextPiece(text: "BROT", x: 0.10, y: 0.470, height: 0.02),
            ReceiptTextPiece(text: " REWE ", x: 0.40, y: 0.100, height: 0.04),
            ReceiptTextPiece(text: "SUMME", x: 0.10, y: 0.500, height: 0.02),
            ReceiptTextPiece(text: "  ", x: 0.50, y: 0.300, height: 0.02),
            ReceiptTextPiece(text: "2,49 B", x: 0.80, y: 0.472, height: 0.02),
            ReceiptTextPiece(text: "EUR", x: 0.50, y: 0.497, height: 0.02),
        ]
        let lines = ReceiptParser.lines(pieces)
        #expect(lines == ["REWE", "BROT  2,49 B", "SUMME  EUR  23,47"])
        #expect(ReceiptParser.parse(lines, today: today, monthFirst: false).amountCents == 2347)
    }
}

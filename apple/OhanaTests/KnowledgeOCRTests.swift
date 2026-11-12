import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Ohana

/// A real scan, read two ways: a school timetable photographed sideways (its text runs down the
/// page). Vision's document reader read it upright (no table, cells lost or read as "2") and
/// turned to the left (one table, the whole grid). Lines with Vision's confidences as recorded.
enum TimetableScan {
    static let upright: [KnowledgeOCRLine] = [
        .init("Name:", 0.47), .init("Klosse:", 0.47), .init("25", 0.45), .init("Zeit", 0.55),
        .init("1. Stunde", 0.62), .init("800 -845", 0.64), .init("2. Stunde", 0.63), .init("85- 930", 0.38),
        .init("3. Stunde", 0.63), .init("927-1022", 0.62), .init("4. Shunde", 0.48), .init("10% - 1130", 0.57),
        .init("5. Stunde", 0.44), .init("1180-2스", 0.28), .init("12 As tna 3°0", 0.13), .init("Hontag", 0.36),
        .init("2", 0.32), .init("2", 0.44), .init("Denstag", 0.34), .init("Religion/Ethik", 0.58),
        .init("Religion/Ethik", 0.58), .init("Hiffwoch", 0.25), .init("2", 0.38), .init("2", 0.40),
        .init("WG", 0.23), .init("WG", 0.28), .init("Sport", 0.63), .init("Sport", 0.63),
        .init("Donnerstag", 0.65), .init("2", 0.43), .init("2", 0.42), .init("Sport", 0.64),
        .init("Freitag", 0.67), .init("GU", 0.42), .init("2", 0.45), .init("2", 0.39), .init("2", 0.37),
    ]

    static let turned: [KnowledgeOCRLine] = [
        .init("Nome:", 0.93), .init("Klosse:", 0.78), .init("2 b", 0.51), .init("Zeit", 0.96),
        .init("Hontag", 0.47), .init("Dienstag", 0.47), .init("Hitíwoch", 0.36), .init("Donnerstag", 0.55),
        .init("Freitag", 0.97), .init("1. Stunde", 0.67), .init("200 - 845", 0.50), .init("GU", 0.95),
        .init("GU", 0.96), .init("GU", 0.96), .init("GU", 0.76), .init("GU", 0.79), .init("2. Stunde", 0.68),
        .init("845 - 930", 0.73), .init("GU", 0.89), .init("GU", 0.90), .init("GU", 0.94), .init("GU", 0.74),
        .init("GU", 0.95), .init("3. Stunde", 0.57), .init("937 - 1022", 0.86), .init("GU", 0.85),
        .init("GU", 0.88), .init("WG", 0.96), .init("GU", 0.96), .init("GU", 0.96), .init("4. Stunde", 0.60),
        .init("1045- 1150", 0.55), .init("GU", 0.64), .init("Religion/Ethik", 0.71), .init("WG", 0.97),
        .init("귀", 0.08), .init("GU", 0.88), .init("5. Sturde", 0.35), .init("1180.", 0.46),
        .init("- 122", 0.56), .init("Religion/Ethik", 0.72), .init("Sport", 0.99), .init("Sport", 0.94),
        .init("12 /5Stunde", 0.19), .init("- 13.0", 0.54), .init("Sport", 0.99),
    ]

    /// The table of the turned reading, row by row.
    static let rows: [[String]] = [
        ["Zeit", "Hontag", "Dienstag", "Hitíwoch", "Donnerstag", "Freitag"],
        ["1. Stunde\n200 - 845", "GU", "GU", "GU", "GU", "GU"],
        ["2. Stunde\n845 - 930", "GU", "GU", "GU", "GU", "GU"],
        ["3. Stunde\n937 - 1022", "GU", "GU", "WG", "GU", "GU"],
        ["4. Stunde\n1045- 1150", "GU", "Religion/Ethik", "WG", "귀", "GU"],
        ["5. Sturde\n1180.\n- 122", "", "Religion/Ethik", "Sport", "Sport", ""],
        ["12 /5Stunde\n- 13.0", "", "", "Sport", "", ""],
    ]

    static var cells: [KnowledgeOCRCell] {
        rows.enumerated().flatMap { row, texts in
            texts.enumerated().map { KnowledgeOCRCell(row: row, column: $0.offset, text: $0.element) }
        }
    }

    /// The ink the page has (dark pixels).
    static let ink = 0.039

    /// The words the system's spell checker knew of these (German or English), as it answered.
    static let known: Set<String> = ["Name", "Zeit", "Stunde", "Dienstag", "Donnerstag", "Freitag", "Religion",
                                     "Ethik", "Sport"]
}

struct KnowledgeOCRQualityTests {
    private func judge(_ lines: [KnowledgeOCRLine], tables: [[KnowledgeOCRCell]] = [], ink: Double? = nil,
                       known: Set<String>? = TimetableScan.known) -> KnowledgeOCRQuality.Verdict {
        KnowledgeOCRQuality.judge(lines: lines, tables: tables, ink: ink, known: known.map { set in { set.contains($0) } })
    }

    @Test func theTimetableReadUprightIsPoorTurnedGood() {
        let upright = KnowledgeOCRQuality.measure(lines: TimetableScan.upright, tables: [],
                                                  known: { TimetableScan.known.contains($0) })
        #expect(upright.confidence > 0.45 && upright.confidence < 0.6)
        #expect(upright.weakShare > 0.2)
        #expect(judge(TimetableScan.upright, ink: TimetableScan.ink) == .poor(.lowConfidence))

        // Turned, the table is right but for its handwritten times and one cell: still for the AI.
        let turned = KnowledgeOCRQuality.measure(lines: TimetableScan.turned, tables: [TimetableScan.cells],
                                                 known: { TimetableScan.known.contains($0) })
        #expect(turned.confidence > 0.6 && turned.confidence < 0.85)
        #expect(turned.weakShare > 0.05)
        #expect(judge(TimetableScan.turned, tables: [TimetableScan.cells], ink: TimetableScan.ink) == .poor(.lowConfidence))
        // Without a spell checker too.
        #expect(judge(TimetableScan.turned, tables: [TimetableScan.cells], ink: TimetableScan.ink, known: nil).isPoor)
    }

    @Test func oneGarbledCellIsEnough() {
        // Every line sure, but one cell read as Hangul (a smudge): the table goes to the AI.
        let sure = TimetableScan.turned.map { KnowledgeOCRLine($0.text, 0.95) }
        #expect(judge(sure, tables: [TimetableScan.cells], known: nil).isPoor)
        var clean = TimetableScan.cells
        for index in clean.indices where clean[index].text.unicodeScalars.contains(where: { $0.value >= 0x1100 && $0.value <= 0xD7FF }) {
            clean[index].text = "FF"
        }
        let sureClean = sure.map { KnowledgeOCRLine(String($0.text.unicodeScalars.filter { !($0.value >= 0x1100 && $0.value <= 0xD7FF) }), 0.95) }
        #expect(judge(sureClean, tables: [clean], known: nil) == .good)
    }

    @Test func aMiddlingConfidenceIsUnsure() {
        // Unsure (below 0.85) with many letters on weak lines: poor.
        let lower = TimetableScan.turned.map { KnowledgeOCRLine($0.text, max(0.3, $0.confidence - 0.16)) }
        #expect(judge(lower, tables: [TimetableScan.cells], ink: TimetableScan.ink).isPoor)
        // Below the floor: poor whatever else.
        let low = TimetableScan.turned.map { KnowledgeOCRLine($0.text, 0.55) }
        #expect(judge(low, tables: [TimetableScan.cells]) == .poor(.lowConfidence))
    }

    @Test func cleanPrintIsGood() {
        let lines = [
            KnowledgeOCRLine("Sehr geehrte Damen und Herren,", 0.98),
            KnowledgeOCRLine("hiermit kündige ich den Vertrag zum nächsten möglichen Termin.", 0.96),
            KnowledgeOCRLine("Mit freundlichen Grüßen", 0.99),
        ]
        let known: Set<String> = ["Sehr", "geehrte", "Damen", "und", "Herren", "hiermit", "kündige", "ich", "den",
                                  "Vertrag", "zum", "nächsten", "möglichen", "Termin", "Mit", "freundlichen", "Grüßen"]
        #expect(judge(lines, ink: 0.03, known: known) == .good)
    }

    @Test func littleTextOnAPageWithInk() {
        // Handwriting the OCR missed: poor; a blank page or a photo without text: nothing to transcribe.
        #expect(judge([KnowledgeOCRLine("Mo", 0.9)], ink: 0.06) == .poor(.littleText))
        #expect(judge([], ink: 0.001) == .good)
        #expect(judge([], ink: nil) == .good)
    }

    @Test func garbageIsPoor() {
        let foreign = [KnowledgeOCRLine("귀스 쓰귀 Termin 스스", 0.9), KnowledgeOCRLine("Vertrag 귀귀 쓰", 0.9),
                       KnowledgeOCRLine("Kündigung zum Monatsende", 0.9)]
        #expect(judge(foreign, known: nil) == .poor(.foreignScript))

        let fragments = (0..<12).map { _ in KnowledgeOCRLine("i l. ,a rn Vertrag", 0.9) }
        #expect(judge(fragments, known: nil) == .poor(.fragments))

        let unknown = ["Vcrtrag Kündlgung Terrnin", "Rcchnung Bctrag Fäl1ig", "Monatscnde Abschlag Zahlurg"]
            .map { KnowledgeOCRLine($0, 0.9) }
        #expect(judge(unknown, known: ["Abschlag"]) == .poor(.unknownWords))

        var table = TimetableScan.cells
        for index in table.indices where index % 3 == 0 { table[index].text = "" }
        for index in table.indices where index % 3 == 1 { table[index].text = "" }
        let sure = TimetableScan.turned.map {
            KnowledgeOCRLine(String($0.text.unicodeScalars.filter { !($0.value >= 0x1100 && $0.value <= 0xD7FF) }), 0.95)
        }
        #expect(judge(sure, tables: [table], known: nil) == .poor(.garbledTable))
    }

    @Test func wordsForTheSpellChecker() {
        let words = KnowledgeOCRQuality.checkableWords([KnowledgeOCRLine("4. Stunde Religion/Ethik GU WG 12 Hitíwoch", 1)])
        #expect(words == ["Stunde", "Religion", "Ethik", "Hitíwoch"])
    }
}

struct KnowledgeOCRLayoutTests {
    @Test func timetableAsMarkdown() {
        #expect(KnowledgeOCRLayout.markdownTable(TimetableScan.cells) == """
            | Zeit | Hontag | Dienstag | Hitíwoch | Donnerstag | Freitag |
            | --- | --- | --- | --- | --- | --- |
            | 1. Stunde 200 - 845 | GU | GU | GU | GU | GU |
            | 2. Stunde 845 - 930 | GU | GU | GU | GU | GU |
            | 3. Stunde 937 - 1022 | GU | GU | WG | GU | GU |
            | 4. Stunde 1045- 1150 | GU | Religion/Ethik | WG | 귀 | GU |
            | 5. Sturde 1180. - 122 |  | Religion/Ethik | Sport | Sport |  |
            | 12 /5Stunde - 13.0 |  |  | Sport |  |  |
            """)
    }

    @Test func tablesLeaveOutEmptyRowsAndColumnsAndEscapePipes() {
        let cells = [
            KnowledgeOCRCell(row: 0, column: 0, text: "A|B"), KnowledgeOCRCell(row: 0, column: 1, text: ""),
            KnowledgeOCRCell(row: 0, column: 2, text: "C"),
            KnowledgeOCRCell(row: 1, column: 0, text: " "), KnowledgeOCRCell(row: 1, column: 1, text: ""),
            KnowledgeOCRCell(row: 2, column: 0, text: "x\ny"), KnowledgeOCRCell(row: 2, column: 2, text: "z"),
        ]
        #expect(KnowledgeOCRLayout.markdownTable(cells) == "| A\\|B | C |\n| --- | --- |\n| x y | z |")
        #expect(KnowledgeOCRLayout.markdownTable([]) == "")
    }

    @Test func paragraphsAndTablesInReadingOrder() {
        // Normalized boxes, origin bottom left: a heading, a table whose cells Vision also lists
        // as paragraphs, a closing line.
        let table = KnowledgeOCRLayout.Block(text: "| A | B |\n| --- | --- |\n| 1 | 2 |",
                                             box: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.3))
        let paragraphs = [
            KnowledgeOCRLayout.Block(text: "Klasse: 2b", box: CGRect(x: 0.1, y: 0.85, width: 0.2, height: 0.03)),
            KnowledgeOCRLayout.Block(text: "Stundenplan", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.03)),
            KnowledgeOCRLayout.Block(text: "A", box: CGRect(x: 0.15, y: 0.65, width: 0.05, height: 0.02)),
            KnowledgeOCRLayout.Block(text: "B", box: CGRect(x: 0.6, y: 0.65, width: 0.05, height: 0.02)),
            KnowledgeOCRLayout.Block(text: "1", box: CGRect(x: 0.15, y: 0.45, width: 0.05, height: 0.02)),
            KnowledgeOCRLayout.Block(text: "Gültig ab Montag", box: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.03)),
        ]
        #expect(KnowledgeOCRLayout.arrange(paragraphs: paragraphs, tables: [table]) == """
            Klasse: 2b
            Stundenplan

            | A | B |
            | --- | --- |
            | 1 | 2 |

            Gültig ab Montag
            """)
        // A table without paragraphs inside: at the end.
        #expect(KnowledgeOCRLayout.arrange(paragraphs: [paragraphs[0]], tables: [table])
            == "Klasse: 2b\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
    }
}

struct KnowledgeOCROrientationTests {
    private func samples(_ angles: [(Double, Int)]) -> [KnowledgeOCROrientation.Sample] {
        angles.map { KnowledgeOCROrientation.Sample(angle: $0.0, weight: $0.1) }
    }

    @Test func theWayMostTextRuns() {
        // The timetable: every line at −90° (text running down the page).
        #expect(KnowledgeOCROrientation.vote(samples([(-90, 5), (-95.2, 7), (-87.7, 14), (-90, 20)])) == .left)
        #expect(KnowledgeOCROrientation.vote(samples([(90, 10), (88, 10)])) == .right)
        #expect(KnowledgeOCROrientation.vote(samples([(180, 10), (-178, 10), (179, 5)])) == .down)
        #expect(KnowledgeOCROrientation.vote(samples([(0, 10), (2, 30)])) == .up)
        // No clear majority (a stamp turned on an upright letter): upright.
        #expect(KnowledgeOCROrientation.vote(samples([(0, 50), (-90, 60)])) == .up)
        #expect(KnowledgeOCROrientation.vote(samples([(0, 30), (-90, 70)])) == .left)
        #expect(KnowledgeOCROrientation.vote([]) == .up)
    }

    @Test func baselineAngles() {
        let size = CGSize(width: 2748, height: 4000)
        #expect(abs(KnowledgeOCROrientation.angle(from: CGPoint(x: 0.8, y: 0.9), to: CGPoint(x: 0.8, y: 0.8), size: size) + 90) < 0.001)
        #expect(abs(KnowledgeOCROrientation.angle(from: CGPoint(x: 0.1, y: 0.5), to: CGPoint(x: 0.4, y: 0.5), size: size)) < 0.001)
    }
}

/// Vision on rendered pages: the page found turned, read upright, its image for the AI.
struct KnowledgeOCRReadingTests {
    /// A white page with `lines` of black text, upright.
    static func page(_ lines: [String], width: Int = 1240, height: Int = 1754) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
        var y = CGFloat(height) - 160
        for line in lines {
            let text = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 120, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            y -= 70
        }
        return context.makeImage()!
    }

    static let letter = ["Stadtwerke Musterstadt", "Abschlagsrechnung für Strom und Gas",
                         "Sehr geehrte Damen und Herren,", "der monatliche Abschlag beträgt ab Januar 84 Euro.",
                         "Bitte überweisen Sie den Betrag bis zum Monatsende.", "Mit freundlichen Grüßen"]

    @Test func aTurnedPageIsReadUpright() async throws {
        let upright = Self.page(Self.letter)
        // Turned a quarter clockwise its text runs down (read with .left), counterclockwise up
        // (.right), half a turn upside down (.down).
        for (turn, expected) in [(CGImagePropertyOrientation.right, CGImagePropertyOrientation.left), (.left, .right), (.down, .down), (.up, .up)] {
            let image = try #require(KnowledgeOCR.turned(upright, turn))
            let page = try #require(await KnowledgeOCR.read(image))
            #expect(page.orientation == expected, "turned \(turn.rawValue)")
            #expect(page.text.contains("Abschlag"), "turned \(turn.rawValue): \(page.text)")
            #expect(page.verdict == .good, "turned \(turn.rawValue): \(page.measures)")
        }
    }

    @Test func theImageForTheAIIsUprightAndSmall() throws {
        let upright = Self.page(Self.letter, width: 2480, height: 3508)
        let sideways = try #require(KnowledgeOCR.turned(upright, .right))
        #expect(sideways.width == 3508 && sideways.height == 2480)
        let jpeg = try #require(KnowledgeOCR.scanJPEG(sideways, orientation: .left))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1414 && image.height == 2000)
        #expect(jpeg.count < KnowledgeOCR.maxScanBytes)
    }

    @Test func inkOnPaperOnly() {
        // A black bar on white: ink; a dark photo: not paper.
        let bar = LetterFilingTests.image(width: 1240, height: 1754, rect: CGRect(x: 100, y: 800, width: 1000, height: 80), fill: 0)
        #expect((KnowledgeOCR.inkShare(bar) ?? 0) > KnowledgeOCRQuality.inkedShare)
        #expect(KnowledgeOCR.inkShare(LetterFilingTests.image(background: 0.3)) == nil)
        #expect(KnowledgeOCR.inkShare(LetterFilingTests.image()) == 0)
    }

    @Test func aPDFScanWithoutTextLayerIsReadAndItsPoorPagesKept() async throws {
        // A page with ink but nothing Vision reads (a black bar, as handwriting it can't): poor.
        let scribbles = LetterFilingTests.image(width: 1240, height: 1754, rect: CGRect(x: 100, y: 800, width: 1000, height: 80), fill: 0)
        let pdf = ScanPDF.make(pages: [ScanPage(image: KnowledgeOCR.turned(Self.page(Self.letter), .right)!, lines: []),
                                       ScanPage(image: scribbles, lines: [])], title: "Brief", tags: [])
        let poor = try #require(await KnowledgeText.pdfPages(pdf, capture: .poor))
        #expect(poor.pages.count == 2 && poor.pages[0].contains("Abschlag"))
        #expect(poor.scans.map(\.page) == [2])
        let all = try #require(await KnowledgeText.pdfPages(pdf, capture: .all))
        #expect(all.scans.map(\.page) == [1, 2])
        #expect(try #require(await KnowledgeText.pdfPages(pdf)).scans.isEmpty)
    }
}

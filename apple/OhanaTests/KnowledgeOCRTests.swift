import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Ohana

/// A real scan: a school timetable photographed sideways, as Vision's document reader read it
/// turned to the left (one table, the whole grid).
enum TimetableScan {
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

    @Test func aPDFScanWithoutTextLayerIsReadAndEveryPageKept() async throws {
        // A second page Vision reads nothing on (a black bar, as handwriting it can't): sent too.
        let blank = LetterFilingTests.image(width: 1240, height: 1754, rect: CGRect(x: 100, y: 800, width: 1000, height: 80), fill: 0)
        let pdf = ScanPDF.make(pages: [ScanPage(image: KnowledgeOCR.turned(Self.page(Self.letter), .right)!, lines: []),
                                       ScanPage(image: blank, lines: [])], title: "Brief", tags: [])
        let all = try #require(await KnowledgeText.pdfPages(pdf, capture: .all))
        #expect(all.pages.count == 2 && all.pages[0].contains("Abschlag"))
        #expect(all.scans.map(\.page) == [1, 2])
        #expect(try #require(await KnowledgeText.pdfPages(pdf)).scans.isEmpty)
    }
}

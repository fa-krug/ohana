import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import Ohana

/// Filing scanned paper: the letter's suggested name, date and tags, file names, Finder tags,
/// the searchable PDF, saving it, the remembered settings, cropping and the receipt's name.
struct LetterFilingTests {
    // MARK: Helpers

    /// A plain image: `background` grey, with a `rect` (pixels, origin bottom left) of `fill`.
    static func image(width: Int = 400, height: Int = 600, background: CGFloat = 1,
                      rect: CGRect? = nil, fill: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let rect {
            context.setFillColor(CGColor(gray: fill, alpha: 1))
            context.fill(rect)
        }
        return context.makeImage()!
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ohana-tests-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func settings() -> ScanFilingSettings {
        let suite = "ohana-tests-\(UUID().uuidString)"
        return ScanFilingSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    static let schoolLetter = """
    Grundschule Nord
    Schulstraße 5
    12345 Berlin
    Familie Krug
    Hauptstr. 3
    12345 Berlin
    Berlin, 28.10.2026
    Elternbrief Klasse 3b – Laternenfest
    Liebe Eltern,
    am Freitag, dem 13. November 2026 laden wir euch zum Laternenfest ein.
    Mia und ihre Klasse basteln schon die Laternen.
    Mit freundlichen Grüßen
    """

    // MARK: The letter's suggestion

    @Test func suggestsFromASchoolLetter() {
        let suggestion = LetterHeuristic.suggest(Self.schoolLetter, names: ["Mia Krug", "Leo", "Sascha"])
        #expect(suggestion.title == "Elternbrief Klasse 3b – Laternenfest")
        #expect(suggestion.date == Day(year: 2026, month: 10, day: 28))
        #expect(suggestion.tags == ["Elternbrief", "Schule", "Einladung", "Mia"])
        #expect(suggestion.fileName(today: Day(year: 2026, month: 11, day: 1))
            == "2026-10-28 Elternbrief Klasse 3b – Laternenfest")
    }

    @Test func takesTheSubjectLine() {
        #expect(LetterHeuristic.suggest("Kita Sonnenschein\nBetreff: Schließtage 2027\nLiebe Eltern,").title
            == "Schließtage 2027")
        #expect(LetterHeuristic.suggest("Betr.: Anmeldung Schwimmkurs").title == "Anmeldung Schwimmkurs")
        #expect(LetterHeuristic.suggest("ACME Ltd\nRe: Your invoice 4711\nDear Mr Krug,").title == "Your invoice 4711")
        #expect(LetterHeuristic.subject("Regards") == nil)
    }

    @Test func headingsAreNotAddressesGreetingsOrDates() {
        #expect(!LetterHeuristic.isHeading("Sehr geehrte Damen und Herren,"))
        #expect(!LetterHeuristic.isHeading("Musterstraße 12"))
        #expect(!LetterHeuristic.isHeading("12345 Berlin-Mitte"))
        #expect(!LetterHeuristic.isHeading("Telefon 030 1234567"))
        #expect(!LetterHeuristic.isHeading("info@schule.example"))
        #expect(!LetterHeuristic.isHeading("13. November 2026"))
        #expect(!LetterHeuristic.isHeading("Kurz"))
        #expect(LetterHeuristic.isHeading("Einladung zum Sommerfest"))
        // Without a greeting, the first heading.
        #expect(LetterHeuristic.title(["Hallo?", "Einladung zum Sommerfest", "Wir feiern am Samstag."])
            == "Einladung zum Sommerfest")
        #expect(LetterHeuristic.title(["1234", "a@b.c"]) == nil)
    }

    @Test func findsTheLettersDate() {
        #expect(LetterHeuristic.date(in: "Berlin, den 3.2.2027") == Day(year: 2027, month: 2, day: 3))
        #expect(LetterHeuristic.date(in: "13.11.26") == Day(year: 2026, month: 11, day: 13))
        #expect(LetterHeuristic.date(in: "München, 13. November 2026") == Day(year: 2026, month: 11, day: 13))
        #expect(LetterHeuristic.date(in: "1. März 2027") == Day(year: 2027, month: 3, day: 1))
        #expect(LetterHeuristic.date(in: "Date: 2026-11-13") == Day(year: 2026, month: 11, day: 13))
        #expect(LetterHeuristic.date(in: "October 5, 2026") == Day(year: 2026, month: 10, day: 5))
        #expect(LetterHeuristic.date(in: "5th October 2026") == Day(year: 2026, month: 10, day: 5))
        #expect(LetterHeuristic.date(in: "31.02.2026") == nil)
        #expect(LetterHeuristic.date(in: "Seite 1 von 2") == nil)
        // The earliest in the line.
        #expect(LetterHeuristic.date(in: "2026-01-02, sent 03.04.2026") == Day(year: 2026, month: 1, day: 2))
        // Only near the top: a date in the body isn't the letter's.
        let lines = Array(repeating: "Text", count: 30) + ["13.11.2026"]
        #expect(LetterHeuristic.date(lines) == nil)
    }

    @Test func tagsFromEnglishKeywordsAndNames() {
        let tags = LetterHeuristic.tags("Dear parents, you are invited to the school play. Leo has a part.",
                                        names: ["Leo", "Mia", "", "A"])
        #expect(tags == ["Parents", "School", "Invitation", "Leo"])
        // A name only as a whole word, and keywords not inside other words.
        #expect(LetterHeuristic.tags("Leonie paid the syntax fee", names: ["Leo"]).isEmpty)
    }

    @Test func noDateNamesTheFileByToday() {
        let today = Day(year: 2026, month: 11, day: 1)
        #expect(LetterSuggestion(title: "Brief").fileName(today: today) == "2026-11-01 Brief")
        #expect(LetterSuggestion().fileName(today: today) == "2026-11-01")
    }

    @Test func cleansTheModelsAnswer() {
        let long = "Elternbrief der Grundschule Nord Klasse 3b zum Laternenfest am Freitag dem dreizehnten"
        let cleaned = LetterSuggestion(title: "  „\(long)“ ", tags: ["Schule", " schule ", "", "Kita", "A", "B", "C"])
            .cleaned()
        #expect(cleaned.title!.count <= LetterSuggestion.maxTitle)
        #expect(long.hasPrefix(cleaned.title!))
        #expect(!cleaned.title!.hasSuffix(" "))
        #expect(cleaned.tags == ["Schule", "Kita", "A", "B", "C"])
        #expect(LetterSuggestion(title: "  ").cleaned().title == nil)
        #expect(LetterModel.prompt("Text", names: ["Mia Krug"]).contains("Mia"))
    }

    @Test func aModelSuggestionKeepsWhatTheUserEdited() {
        let review = LetterReview(images: [Self.image()], offersAssistant: true, settings: Self.settings(),
                                  today: Day(year: 2026, month: 11, day: 1))
        review.apply(LetterSuggestion(title: "Brief", date: Day(year: 2026, month: 10, day: 2), tags: ["Kita"]))
        #expect(review.filing.name == "2026-10-02 Brief")
        #expect(review.filing.tags == ["Kita"])
        review.filing.editName("Mein Name")
        review.filing.addTag("Wichtig")
        review.apply(LetterSuggestion(title: "Besser", tags: ["Schule"]))
        #expect(review.filing.name == "Mein Name")
        #expect(review.filing.tags == ["Kita", "Wichtig"])
        #expect(review.outcome.text == nil)
        #expect(review.outcome.askAssistant == false)
    }

    // MARK: File names and tags

    @Test func sanitizesFileNames() {
        #expect(ScanFileName.sanitized("Betr.: Rechnung 12/2026") == "Betr.- Rechnung 12-2026")
        #expect(ScanFileName.sanitized("  .versteckt  ") == "versteckt")
        #expect(ScanFileName.sanitized("Zeile\neins  zwei") == "Zeile-eins zwei")
        #expect(ScanFileName.sanitized("Brief.PDF") == "Brief")
        #expect(ScanFileName.sanitized("a*b?c\"d<e>f|g\\h") == "a-b-c-d-e-f-g-h")
        #expect(ScanFileName.sanitized("   ") == "Scan")
        #expect(ScanFileName.sanitized("///") == "Scan")
        #expect(ScanFileName.sanitized(String(repeating: "x", count: 200)).count == ScanFileName.maxLength)
    }

    @Test func numbersFileNamesThatAreTaken() {
        let folder = URL(fileURLWithPath: "/tmp/letters", isDirectory: true)
        let taken: Set<String> = ["Brief.pdf", "Brief 2.pdf"]
        #expect(ScanFileName.unique("Brief", in: folder) { taken.contains($0.lastPathComponent) }.lastPathComponent
            == "Brief 3.pdf")
        #expect(ScanFileName.unique("Neu", in: folder) { taken.contains($0.lastPathComponent) }.lastPathComponent
            == "Neu.pdf")
    }

    @Test func encodesFinderTags() throws {
        let data = try FinderTags.encode(["Schule", "Mia"])
        #expect(data.starts(with: Array("bplist".utf8)))
        #expect(FinderTags.decode(data) == ["Schule", "Mia"])
        // A tag's colour after its name is left out.
        #expect(FinderTags.decode(try FinderTags.encode(["Rot\n6"])) == ["Rot"])
        #expect(FinderTags.decode(Data("junk".utf8)).isEmpty)

        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: file)
        try FinderTags.write(["Kita", "Leo"], to: file)
        #expect(FinderTags.read(file) == ["Kita", "Leo"])
        try FinderTags.write([], to: file)
        #expect(FinderTags.read(file).isEmpty)
        try FinderTags.write([], to: file)
    }

    // MARK: The PDF

    @Test func buildsASearchablePDF() throws {
        let pages = [
            ScanPage(image: Self.image(width: 1240, height: 1754), lines: [
                ScanLine(text: "Elternbrief Klasse 3b", box: CGRect(x: 0.1, y: 0.85, width: 0.5, height: 0.03)),
                ScanLine(text: "Laternenfest am Freitag", box: CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.02)),
            ]),
            ScanPage(image: Self.image(width: 3000, height: 2000), lines: [
                ScanLine(text: "Rückseite", box: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.04)),
            ]),
        ]
        let data = ScanPDF.make(pages: pages, title: "2026-10-28 Elternbrief", tags: ["Schule", "Mia"])
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 2)
        let text = document.string ?? ""
        #expect(text.contains("Elternbrief Klasse 3b"))
        #expect(text.contains("Laternenfest am Freitag"))
        #expect(text.contains("Rückseite"))
        let attributes = document.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "2026-10-28 Elternbrief")
        #expect(attributes[PDFDocumentAttribute.creatorAttribute] as? String == "Ohana")
        let keywords = attributes[PDFDocumentAttribute.keywordsAttribute]
        let keywordText = (keywords as? [String])?.joined(separator: " ") ?? (keywords as? String) ?? ""
        #expect(keywordText.contains("Schule") && keywordText.contains("Mia"))
        // A4's long side; the landscape page lies on its side.
        let first = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(first.height == 842)
        #expect(abs(first.width - 595) <= 1)
        let second = try #require(document.page(at: 1)?.bounds(for: .mediaBox))
        #expect(second.width == 842)
        // The image is at most ~200 dpi.
        #expect(ScanPDF.compressed(Self.image(width: 3000, height: 2000)).width == ScanPDF.maxPixels)
    }

    @Test func savesThePDFInTheFolder() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = ScanPDF.make(pages: [ScanPage(image: Self.image(), lines: [])], title: "T", tags: [])
        let first = try ScanFiler.save(data, name: "2026-10-28 Brief: Kita", tags: ["Kita"], in: folder)
        #expect(first.lastPathComponent == "2026-10-28 Brief- Kita.pdf")
        #expect(FinderTags.read(first) == ["Kita"])
        let second = try ScanFiler.save(data, name: "2026-10-28 Brief: Kita", tags: [], in: folder)
        #expect(second.lastPathComponent == "2026-10-28 Brief- Kita 2.pdf")
        #expect(PDFDocument(url: second)?.pageCount == 1)
        #expect(throws: ScanFilingError.self) {
            try ScanFiler.save(data, name: "x", tags: [], in: folder.appendingPathComponent("gone"))
        }
    }

    // MARK: Remembered settings

    @Test func remembersTheSwitchPerKindAndTheRecentTags() {
        let settings = Self.settings()
        #expect(settings.savesPDF(.letter))
        #expect(!settings.savesPDF(.receipt))
        settings.setSavesPDF(false, for: .letter)
        #expect(!settings.savesPDF(.letter))
        #expect(!settings.savesPDF(.receipt))
        settings.setSavesPDF(true, for: .receipt)
        #expect(settings.savesPDF(.receipt))
        #expect(!ScanFiling(kind: .letter, settings: settings).savesPDF)
        #expect(ScanFiling(kind: .receipt, settings: settings).savesPDF)

        settings.remember(tags: ["Schule", "Mia"])
        settings.remember(tags: ["Kita", "schule"])
        #expect(settings.recentTags == ["Kita", "schule", "Mia"])
        settings.remember(tags: (1...20).map { "T\($0)" })
        #expect(settings.recentTags.count == ScanFilingSettings.maxRecentTags)
        #expect(settings.recentTags.first == "T1")
    }

    @Test func remembersTheFolder() throws {
        let settings = Self.settings()
        #expect(settings.folder() == .none)
        let folder = try Self.temporaryFolder()
        try settings.rememberFolder(folder)
        let found = try #require(settings.folder().url)
        #expect(found.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        // Shared by letters and receipts.
        #expect(ScanFiling(kind: .receipt, settings: settings).folder.url != nil)
        try FileManager.default.removeItem(at: folder)
        #expect(settings.folder() == .missing)
        settings.folderBookmark = Data("junk".utf8)
        #expect(settings.folder() == .missing)
    }

    @Test func fillsWhatTheUserHasntEdited() async throws {
        let settings = Self.settings()
        settings.remember(tags: ["Schule", "Arzt"])
        let filing = ScanFiling(kind: .letter, settings: settings)
        filing.suggest(name: "2026-10-28 Brief", tags: ["Schule", "schule", ""])
        #expect(filing.name == "2026-10-28 Brief")
        #expect(filing.tags == ["Schule"])
        #expect(filing.recentTags == ["Arzt"])
        filing.addTag("  ")
        filing.addTag("SCHULE")
        #expect(!filing.tagsEdited)
        filing.addTag("Mia")
        filing.removeTag("Schule")
        filing.suggest(name: "Anders", tags: ["Kita"])
        #expect(filing.tags == ["Mia"])
        #expect(filing.name == "Anders")
        filing.editName("Meins")
        filing.suggest(name: "Wieder anders")
        #expect(filing.name == "Meins")

        // No folder: saving asks for one.
        #expect(filing.needsFolder)
        await #expect(throws: ScanFilingError.noFolder) { try await filing.save([]) }
        filing.savesPDF = false
        #expect(!filing.needsFolder)
        #expect(try await filing.save([]) == nil)
        #expect(!settings.savesPDF(.letter))
    }

    @Test func savesOnceIntoTheRememberedFolder() async throws {
        let settings = Self.settings()
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try settings.rememberFolder(folder)
        let filing = ScanFiling(kind: .letter, settings: settings)
        filing.suggest(name: "Brief.pdf", tags: ["Kita"])
        let page = ScanPage(image: Self.image(), lines: [ScanLine(text: "Hallo", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05))])
        #expect(try await filing.save([page]) == "Brief.pdf")
        #expect(settings.recentTags == ["Kita"])
        // A retry (the transaction after it failed) doesn't save a second copy.
        #expect(try await filing.save([page]) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Brief.pdf"])
    }

    // MARK: Cropping

    @Test func cropsToThePaper() async throws {
        let paper = CGRect(x: 200, y: 150, width: 400, height: 300)
        let photo = Self.image(width: 800, height: 600, background: 0.15, rect: paper, fill: 1)
        let quad = try #require(await ScanCrop.detect(photo))
        #expect(abs(quad.area - 0.25) < 0.05)
        let cropped = await ScanCrop.cropped(photo)
        #expect(abs(cropped.width - 400) <= 40)
        #expect(abs(cropped.height - 300) <= 30)

        // A page without paper on a background stays whole.
        let page = Self.image(width: 800, height: 600)
        let whole = await ScanCrop.cropped(page)
        #expect(whole.width == 800 && whole.height == 600)
    }

    @Test func straightensAQuad() throws {
        let quad = ScanCrop.Quad(topLeft: CGPoint(x: 0.25, y: 0.75), topRight: CGPoint(x: 0.75, y: 0.75),
                                 bottomRight: CGPoint(x: 0.75, y: 0.25), bottomLeft: CGPoint(x: 0.25, y: 0.25))
        #expect(abs(quad.area - 0.25) < 0.001)
        #expect(quad.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(!quad.contains(CGPoint(x: 0.1, y: 0.5)))
        let image = Self.image(width: 800, height: 600, background: 0.15,
                               rect: CGRect(x: 200, y: 150, width: 400, height: 300))
        #expect(ScanCrop.standsOut(quad, in: image))
        #expect(!ScanCrop.standsOut(quad, in: Self.image(width: 800, height: 600)))
        let straight = try #require(ScanCrop.perspectiveCorrected(image, quad: quad))
        #expect(abs(straight.width - 400) <= 2)
        #expect(abs(straight.height - 300) <= 2)
    }

    // MARK: Receipts

    @Test func namesAReceiptsPDF() {
        let german = Locale(identifier: "de_DE")
        #expect(ScannedReceipt.fileName(day: Day(year: 2026, month: 10, day: 12), payee: " REWE ", amountCents: -2347,
                                        currency: "EUR", locale: german) == "2026-10-12 REWE 23,47 EUR")
        #expect(ScannedReceipt.fileName(day: Day(year: 2026, month: 10, day: 12), payee: "", amountCents: nil,
                                        currency: "EUR") == "2026-10-12")
        #expect(ScannedReceipt.tags(category: "Groceries") == ["Receipt", "Groceries"])
        #expect(ScannedReceipt.tags(category: nil) == ["Receipt"])
        #expect(!ScannedReceipt(scan: ReceiptScan(), pages: []).filing.savesPDF
            || ScanFilingSettings().savesPDF(.receipt))
    }

    @Test func readsAReceiptFromItsLines() {
        let page = ScanPage(image: Self.image(), lines: [
            ScanLine(text: "REWE", box: CGRect(x: 0.4, y: 0.9, width: 0.2, height: 0.03)),
            ScanLine(text: "SUMME", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.02)),
            ScanLine(text: "EUR 23,47", box: CGRect(x: 0.6, y: 0.5, width: 0.2, height: 0.02)),
            ScanLine(text: "12.10.26 18:43", box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.02)),
        ])
        let scan = ReceiptParser.scan([page], today: Day(year: 2026, month: 10, day: 20))
        #expect(scan == ReceiptScan(amountCents: 2347, date: Day(year: 2026, month: 10, day: 12), shop: "REWE"))
    }

    // MARK: Opening the scanner

    @Test func asksTheShellToScan() {
        let family = FamilyContext(family: FamilySummary(id: "f1", name: "F", role: .viewer, memberCount: 1), api: FamilyAPI(
            client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil), familyID: "f1"))
        #expect(!family.takeLetterScanRequest())
        family.scanLetter()
        #expect(family.letterScanRequest != nil)
        #expect(family.takeLetterScanRequest())
        #expect(!family.takeLetterScanRequest())

        let inbox = LetterScanInbox()
        #expect(!inbox.take())
        inbox.post()
        #expect(inbox.take())
        #expect(!inbox.take())
    }
}

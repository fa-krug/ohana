import Foundation
import Testing
@testable import Ohana

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// The knowledge base's page: the module, its routes and who sees it.
@MainActor
struct KnowledgeModuleTests {
    @Test func routes() {
        #expect(AppRoute.parse(webPath: "/f/fam1/knowledge")?.route == .module(.knowledge))
        #expect(AppRoute.parse(webPath: "/f/fam1/knowledge/d1")?.route == .knowledgeDocument(id: "d1"))
        #expect(AppRoute.parse(webPath: "/f/fam1/knowledge/d1", page: "3")?.route == .knowledgeDocument(id: "d1", page: 3))
        #expect(AppRoute.parse(webPath: "/f/fam1/knowledge/d1", page: "0")?.route == .knowledgeDocument(id: "d1"))
        #expect(AppRoute.parse(webPath: "/f/fam1/knowledge/d1", page: "two")?.route == .knowledgeDocument(id: "d1"))
        #expect(AppRoute.parse(webPath: "/f/fam1/knowledge/d1")?.familyID == "fam1")
        #expect(AppRoute.knowledgeDocument(id: "d1").module == .knowledge)
        #expect(AppRoute.knowledgeDocument(id: "d1").requiredModule == .knowledge)
    }

    @Test func theModuleInTheShell() {
        #expect(Module.modules.contains(.knowledge))
        #expect(Module.knowledge.title == "Knowledge")
        #expect(Module.knowledge.systemImage == "books.vertical")
        // The others keep their ⌘-numbers; the knowledge base is ⌘9, the search has none.
        #expect(Module.overview.shortcut?.character == "1" && Module.settings.shortcut?.character == "8")
        #expect(Module.knowledge.shortcut?.character == "9")
        #expect(Module.search.shortcut == nil)
    }

    private func context(role: FamilyRole, demo: Bool = false, modules: [String]) -> FamilyContext {
        let client = demo ? APIClient(demo: DemoServer()) : APIClient(baseURL: URL(string: "https://ohana.example")!, token: "t")
        let context = FamilyContext(family: FamilySummary(id: "f", name: "F", role: role, memberCount: 2),
                                    api: FamilyAPI(client: client, familyID: "f"))
        context.serverInfo = ServerInfo(name: "Ohana", version: "1", apiVersion: 1, modules: modules)
        return context
    }

    @Test func onlyEditorsOutsideTheDemoSeeIt() {
        #expect(context(role: .editor, modules: ["calendar", "knowledge"]).isEnabled(.knowledge))
        #expect(!context(role: .viewer, modules: ["calendar", "knowledge"]).isEnabled(.knowledge))
        #expect(!context(role: .editor, modules: ["calendar"]).isEnabled(.knowledge))
        #expect(!context(role: .editor, demo: true, modules: ["calendar", "knowledge"]).isEnabled(.knowledge))
        // A route into it is ignored where it's off.
        let viewer = context(role: .viewer, modules: ["calendar", "knowledge"])
        viewer.open(.knowledgeDocument(id: "d1"))
        viewer.open(.settings(.knowledge))
        #expect(viewer.pendingRoute == nil)
        let editor = context(role: .editor, modules: ["calendar", "knowledge"])
        editor.open(.knowledgeDocument(id: "d1", page: 2))
        #expect(editor.takeRoute(for: .knowledge) == .knowledgeDocument(id: "d1", page: 2))
    }
}

/// The documents as the server sends them, a newer and an older server alike.
struct KnowledgeDocumentDecodingTests {
    static let full = """
    {"document": {"id": "d1", "folderId": "f1", "path": "Versicherungen/Auto/Police 2026.pdf", "name": "Police 2026.pdf",
      "tags": ["Auto", "Versicherung"], "size": 1234, "mtime": 1767225600000, "hash": "abc", "pages": 2,
      "status": "ready", "error": null, "cardStatus": "ready", "summary": "Kfz-Haftpflicht für den Golf.",
      "docDate": "2026-01-01", "person": {"id": "u1", "name": "Anna", "account": true},
      "indexedAt": "2026-01-02T10:00:00.000Z", "missingSince": null,
      "createdAt": "2026-01-02T09:00:00.000Z", "updatedAt": "2026-01-02T10:00:00.000Z",
      "facts": [{"text": "Beitrag 312 € im Jahr", "quote": "Jahresbeitrag: 312,00 €", "chunkId": 7, "page": 2},
                {"quote": "no text"}],
      "chunks": [{"id": 8, "seq": 1, "page": 2, "text": "Jahresbeitrag: 312,00 €"},
                 {"id": 6, "seq": 0, "page": 1, "text": "Police"},
                 {"id": 9, "seq": 2, "page": 2, "text": "Laufzeit ein Jahr"}]}}
    """

    @Test func aDocumentWithItsCard() throws {
        let detail = try decode(KnowledgeDocumentResponse.self, Self.full).document
        let document = detail.document
        #expect(document.id == "d1" && document.name == "Police 2026.pdf")
        #expect(document.tags == ["Auto", "Versicherung"])
        #expect(document.status == .ready && document.cardStatus == .ready)
        #expect(document.person == KnowledgePerson(id: "u1", name: "Anna", account: true))
        #expect(document.docDate == "2026-01-01")
        #expect(document.folderParts == ["Versicherungen", "Auto"])
        #expect(document.kind == .pdf)
        #expect(document.modified == Date(timeIntervalSince1970: 1_767_225_600))
        // A fact without its text is left out.
        #expect(detail.facts == [KnowledgeFact(text: "Beitrag 312 € im Jahr", quote: "Jahresbeitrag: 312,00 €", chunkId: 7, page: 2)])
        #expect(detail.textByPage.map(\.page) == [1, 2])
        #expect(detail.textByPage.last?.text == "Jahresbeitrag: 312,00 €\n\nLaufzeit ein Jahr")
    }

    @Test func aServerFromBeforeTheCards() throws {
        let page = try decode(KnowledgeDocumentsPage.self, """
        {"documents": [{"id": "d2", "folderId": "f1", "path": "Brief.txt", "name": "Brief.txt", "tags": [], "size": 3,
          "mtime": 1, "hash": "h", "pages": 1, "status": "pending", "error": null, "summary": null, "docDate": null,
          "person": null, "indexedAt": null, "missingSince": null, "createdAt": "x", "updatedAt": "x"},
          {"id": "d3", "path": "Sub/Neu.md", "status": "archived"}],
         "nextCursor": "c2"}
        """)
        #expect(page.nextCursor == "c2")
        let old = try #require(page.documents.first)
        #expect(old.cardStatus == nil && old.person == nil && old.summary == nil && old.status == .pending)
        // Missing fields take their defaults; an unknown status shows as an ordinary document.
        let sparse = page.documents[1]
        #expect(sparse.name == "Neu.md" && sparse.tags.isEmpty && sparse.status == .ready && sparse.kind == .text)

        let detail = try decode(KnowledgeDocumentResponse.self, """
        {"document": {"id": "d2", "path": "Brief.txt", "status": "failed", "error": "No text", "facts": null, "chunks": []}}
        """).document
        #expect(detail.facts == nil && detail.chunks.isEmpty && detail.document.error == "No text")
        let last = try decode(KnowledgeDocumentsPage.self, #"{"documents": [], "nextCursor": null}"#)
        #expect(last.nextCursor == nil)
    }

    @Test func theCardsStateAndTheStatus() throws {
        let none = try decode(KnowledgeDocumentSummary.self, #"{"id": "d", "cardStatus": "none"}"#)
        #expect(none.cardStatus == .noCard)
        let status = try decode(KnowledgeStatusInfo.self,
                                #"{"folder": null, "counts": {"pending": 0, "ready": 1, "failed": 0, "missing": 0, "excluded": 0}, "chunks": 3, "cards": true}"#)
        #expect(status.makesCards)
        let older = try decode(KnowledgeStatusInfo.self,
                               #"{"folder": null, "counts": {"pending": 0, "ready": 1, "failed": 0, "missing": 0, "excluded": 0}, "chunks": 3}"#)
        #expect(older.cards == nil && !older.makesCards)
    }
}

/// What the list asks for, and how paths read.
struct KnowledgeListTests {
    @Test func queries() {
        #expect(KnowledgeDocumentQuery().items() == ["limit": "50"])
        #expect(!KnowledgeDocumentQuery().isFiltered)
        var query = KnowledgeDocumentQuery(tag: "Auto", folder: "Versicherungen/Auto", person: "u1")
        #expect(query.isFiltered)
        #expect(query.items(cursor: "c2") == ["limit": "50", "tag": "Auto", "folder": "Versicherungen/Auto",
                                             "person": "u1", "cursor": "c2"])
        query = KnowledgeDocumentQuery(excluded: true)
        #expect(query.isFiltered)
        #expect(query.items() == ["limit": "50", "status": "excluded"])
    }

    @Test func breadcrumbsAndFolders() {
        #expect(KnowledgePath.breadcrumb("Versicherungen/Auto/Police.pdf") == "Versicherungen › Auto › Police.pdf")
        #expect(KnowledgePath.breadcrumb("Police.pdf") == "Police.pdf")
        #expect(KnowledgePath.folderName("Versicherungen/Auto") == "Auto")
        #expect(KnowledgePath.parent("Versicherungen/Auto") == "Versicherungen")
        #expect(KnowledgePath.parent("Versicherungen") == nil)
        let paths = ["Versicherungen/Auto/Police.pdf", "Versicherungen/Haus/Police.pdf", "Versicherungen/Brief.pdf",
                     "Ärzte/Befund.pdf", "Notiz.txt"]
        #expect(KnowledgePath.subfolders(of: paths, under: nil) == ["Ärzte", "Versicherungen"])
        #expect(KnowledgePath.subfolders(of: paths, under: "Versicherungen") == ["Versicherungen/Auto", "Versicherungen/Haus"])
        #expect(KnowledgePath.subfolders(of: paths, under: "Versicherungen/Auto").isEmpty)
    }

    @MainActor
    @Test func datesAndFolders() throws {
        let document = try decode(KnowledgeDocumentSummary.self,
                                  #"{"id": "d", "path": "A/B/c.pdf", "docDate": "2026-03-12", "mtime": 0}"#)
        let date = Day(year: 2026, month: 3, day: 12).date.formatted(date: .abbreviated, time: .omitted)
        #expect(KnowledgeWording.dateText(document) == date)
        #expect(KnowledgeWording.folder(document) == "A › B")
        let top = try decode(KnowledgeDocumentSummary.self, #"{"id": "d", "path": "c.pdf", "mtime": 0}"#)
        #expect(KnowledgeWording.dateText(top) == Date(timeIntervalSince1970: 0).formatted(date: .abbreviated, time: .omitted))
        #expect(KnowledgeWording.folder(top) == nil)
    }
}

/// *Open original*: finding the file on the disk, and the quote in a page's text.
struct KnowledgeOriginalTests {
    @Test func findsTheFileWhateverItsNormalization() throws {
        let root = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Written decomposed (NFD), asked for composed (NFC) as the server keeps it.
        let folder = root.appending(path: "A\u{0308}rzte", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Befund fu\u{0308}r Max.pdf")
        try Data("x".utf8).write(to: file)

        let found = try #require(KnowledgeOriginal.locate("Ärzte/Befund für Max.pdf", in: root))
        #expect(FileManager.default.fileExists(atPath: found.path(percentEncoded: false)))
        #expect(found.lastPathComponent.precomposedStringWithCanonicalMapping == "Befund für Max.pdf")
        #expect(KnowledgeOriginal.locate("Ärzte/Fehlt.pdf", in: root) == nil)
        // A folder isn't a file; nothing leaves the folder.
        #expect(KnowledgeOriginal.locate("Ärzte", in: root) == nil)
        #expect(KnowledgeOriginal.locate("../\(root.lastPathComponent)/Ärzte/Befund für Max.pdf", in: root) == nil)
        #expect(KnowledgeOriginal.locate("", in: root) == nil)
    }

    @Test func aFileICloudKeepsOffTheDeviceIsItsRealName() throws {
        let root = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: ".Police.pdf.icloud"))
        let found = try #require(KnowledgeOriginal.locate("Police.pdf", in: root))
        #expect(found.lastPathComponent == "Police.pdf")
        #expect(KnowledgeOriginal.placeholderName(".Police.pdf.icloud") == "Police.pdf")
        #expect(KnowledgeOriginal.placeholderName("Police.pdf") == nil)
    }

    @Test func copiesForTheViewerAndCleansUp() throws {
        let root = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "Brief.txt")
        try Data("Hallo".utf8).write(to: source)
        let copy = try KnowledgeOriginal.copy(source, name: "Brief.txt")
        #expect(try String(contentsOf: copy.url, encoding: .utf8) == "Hallo")
        #expect(!copy.isPDF)
        copy.discard()
        #expect(!FileManager.default.fileExists(atPath: copy.url.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(KnowledgeOriginal.isPDF(URL(filePath: "/x/Police.PDF")))
    }

    @Test func withoutTheFolderItSaysWhy() {
        #expect(throws: KnowledgeOriginalError.noFolder) { try KnowledgeOriginal.linkedRoot(.none) }
        #expect(throws: KnowledgeOriginalError.folderMissing) { try KnowledgeOriginal.linkedRoot(.missing) }
        #expect(throws: KnowledgeOriginalError.folderReplaced) { try KnowledgeOriginal.linkedRoot(.replaced) }
        #expect((try? KnowledgeOriginal.linkedRoot(.linked(url: URL(filePath: "/k"), folderID: "f"))) == URL(filePath: "/k"))
        #expect(KnowledgeOriginalError.noFolder.offersSettings && !KnowledgeOriginalError.notFound.offersSettings)
        #expect(KnowledgeOriginalError.notFound.localizedDescription == "The file isn’t in the folder any more.")
    }

    @Test func findsTheQuoteAcrossLinesCaseAndAccents() throws {
        let text = "Sehr geehrte Frau Muster,\nIhr Jahresbeitrag\nbeträgt ab dem 1. Januar 312,00 €.\nMit freundlichen Grüßen"
        let range = try #require(KnowledgeQuoteMatch.range(of: "ihr jahresbeitrag betragt ab dem 1. Januar 312,00 €", in: text))
        // Up to its last word (a lone "€" is no word).
        #expect(text[range] == "Ihr Jahresbeitrag\nbeträgt ab dem 1. Januar 312,00")
        // Quotation marks and punctuation around words don't matter.
        let quoted = try #require(KnowledgeQuoteMatch.range(of: "„Mit freundlichen Grüßen“", in: text))
        #expect(text[quoted] == "Mit freundlichen Grüßen")
        let ns = try #require(KnowledgeQuoteMatch.nsRange(of: "Frau Muster", in: text))
        #expect((text as NSString).substring(with: ns) == "Frau Muster")
    }

    @Test func fallsBackToTheQuotesFirstWords() throws {
        let text = "Die Versiche-\nrung endet am 31.12.2026 ohne Kündigung nicht, sondern verlängert sich um ein Jahr."
        // The whole quote isn't there (the model wrote it differently at the end), its first words are.
        let range = try #require(KnowledgeQuoteMatch.range(
            of: "endet am 31.12.2026 ohne Kündigung nicht, sondern verlängert sich automatisch um zwölf Monate", in: text))
        #expect(text[range] == "endet am 31.12.2026 ohne Kündigung nicht, sondern verlängert")
        #expect(KnowledgeQuoteMatch.range(of: "ganz anderer Text", in: text) == nil)
        #expect(KnowledgeQuoteMatch.range(of: "  ", in: text) == nil)
    }

    @MainActor
    @Test func pdfPagesLookedAt() {
        #expect(KnowledgePDFHighlight.pageOrder(page: 2, count: 5) == [1, 0, 2])
        #expect(KnowledgePDFHighlight.pageOrder(page: 1, count: 5) == [0, 1])
        #expect(KnowledgePDFHighlight.pageOrder(page: nil, count: 3) == [0, 1, 2])
        #expect(KnowledgePDFHighlight.pageOrder(page: 9, count: 3).isEmpty)
        #expect(KnowledgePDFHighlight.pageOrder(page: 1, count: 0).isEmpty)
    }
}

/// Review fixes: links keep their query, the AI's card, a list that keeps its pages, loading an
/// original that can be stopped.
struct KnowledgeReviewTests {
    @MainActor
    @Test func linksKeepTheirPage() {
        #expect(AppRoute.parse(link: "/f/fam/knowledge/d1?page=2")?.route == .knowledgeDocument(id: "d1", page: 2))
        #expect(AppRoute.parse(link: "/f/fam/knowledge/d1?page=2#top")?.route == .knowledgeDocument(id: "d1", page: 2))
        #expect(AppRoute.parse(link: "/f/fam/knowledge/d1")?.route == .knowledgeDocument(id: "d1"))
        #expect(AppRoute.parse(link: "/f/fam/chores/c1?day=2026-11-05")?.route == .chore(id: "c1", day: Day("2026-11-05")))
        #expect(AppRoute.parse(link: "/f/fam/settings?tab=knowledge")?.route == .settings(.knowledge))
        #expect(AppRoute.parse(link: "/account?x=1") == nil)
        // A relative link in an answer.
        #expect(AppRoute.parse(url: URL(string: "/f/fam/knowledge/d1?page=3")!)?.route == .knowledgeDocument(id: "d1", page: 3))
        // A tool's result naming the page.
        let call = AssistantToolCall(id: "t", name: "read_knowledge", args: [:], status: "ok", summary: nil,
                                     result: #"{"url":"/f/fam/knowledge/d1?page=2"}"#, interrupted: false)
        #expect(AssistantToolLinks.route(call, familyID: "fam") == .knowledgeDocument(id: "d1", page: 2))
    }

    @Test func theCardsError() throws {
        let failed = try decode(KnowledgeDocumentSummary.self, #"{"id": "d", "cardStatus": "failed", "cardError": "Model timed out"}"#)
        #expect(failed.cardStatus == .failed && failed.cardError == "Model timed out")
        let older = try decode(KnowledgeDocumentSummary.self, #"{"id": "d", "cardStatus": "failed"}"#)
        #expect(older.cardError == nil)
    }

    private func page(_ ids: [String], next: String?) throws -> KnowledgeDocumentsPage {
        let documents = try ids.map { try decode(KnowledgeDocumentSummary.self, #"{"id": "\#($0)"}"#) }
        return KnowledgeDocumentsPage(documents: documents, nextCursor: next)
    }

    @Test func aRefreshKeepsTheLoadedPages() throws {
        #expect(KnowledgeDocumentsPage.refreshLimit(loaded: 0) == 50)
        #expect(KnowledgeDocumentsPage.refreshLimit(loaded: 120) == 120)
        #expect(KnowledgeDocumentsPage.refreshLimit(loaded: 500) == 200)
        // Up to the limit: the fresh answer is the list (with its cursor).
        let loaded = try page(["a", "b", "c"], next: "c3")
        #expect(loaded.refreshed(with: try page(["n", "a", "b"], next: "c4"), limit: 50).documents.map(\.id) == ["n", "a", "b"])
        // Beyond it: the rest stays, without what the fresh part has now.
        let many = try page(["a", "b", "c", "d"], next: "c9")
        let merged = many.refreshed(with: try page(["c", "a"], next: "x"), limit: 2)
        #expect(merged.documents.map(\.id) == ["c", "a", "d"] && merged.nextCursor == "c9")
        let more = loaded.appending(try page(["c", "d"], next: nil))
        #expect(more.documents.map(\.id) == ["a", "b", "c", "d"] && more.nextCursor == nil)
    }

    private func linked(_ root: URL) throws -> KnowledgeFolder {
        let defaults = UserDefaults(suiteName: "ohana-tests-\(UUID().uuidString)")!
        let folder = KnowledgeFolder(location: KnowledgeLocation(server: URL(string: "https://ohana.example")!, familyID: "f"),
                                     defaults: defaults)
        try folder.remember(root, folderID: "k1")
        return folder
    }

    @Test func loadingAnOriginal() async throws {
        let root = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Post"), withIntermediateDirectories: true)
        try Data("Hallo".utf8).write(to: root.appending(path: "Post/Brief.txt"))
        try Data().write(to: root.appending(path: ".Police.pdf.icloud"))
        let folder = try linked(root)

        let copy = try await KnowledgeOriginalLoader().fetch(path: "Post/Brief.txt", folder: folder, online: true)
        #expect(try String(contentsOf: copy.url, encoding: .utf8) == "Hallo" && copy.url.lastPathComponent == "Brief.txt")
        copy.discard()
        // Not on the device and offline: said at once, not waited for.
        await #expect(throws: KnowledgeOriginalError.offline) {
            try await KnowledgeOriginalLoader().fetch(path: "Police.pdf", folder: folder, online: false)
        }
        await #expect(throws: KnowledgeOriginalError.notFound) {
            try await KnowledgeOriginalLoader().fetch(path: "Post/Fehlt.txt", folder: folder, online: true)
        }
        let unlinked = KnowledgeFolder(location: KnowledgeLocation(server: URL(string: "https://ohana.example")!, familyID: "g"),
                                       defaults: UserDefaults(suiteName: "ohana-tests-\(UUID().uuidString)")!)
        await #expect(throws: KnowledgeOriginalError.noFolder) {
            try await KnowledgeOriginalLoader().fetch(path: "Post/Brief.txt", folder: unlinked, online: true)
        }
        // Cancelled: no copy, no error to show.
        let cancelled = KnowledgeOriginalLoader()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.fetch(path: "Post/Brief.txt", folder: folder, online: true)
        }
        #expect(KnowledgeOriginalError.offline.localizedDescription.contains("connection"))
        #expect(!KnowledgeOriginalError.timedOut.offersSettings)
    }

    /// A copy iCloud never finishes (a coordinated read that doesn't return, whatever
    /// `NSFileCoordinator.cancel()` does) ends in an error, never a wait without end.
    @Test func anOriginalICloudNeverLoadsEndsTheWait() async throws {
        let root = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Versicherungen"), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: root.appending(path: "Versicherungen/Beitragsrechnung 2026.pdf"))
        let folder = try linked(root)
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<2 { release.signal() } }
        let hanging: KnowledgeOriginalLoader.Copy = { url, name, coordinator in
            release.wait()
            return try KnowledgeOriginal.copy(url, name: name, coordinator: coordinator)
        }

        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: KnowledgeOriginalError.timedOut) {
            try await KnowledgeOriginalLoader(copy: hanging).fetch(path: "Versicherungen/Beitragsrechnung 2026.pdf",
                                                                   folder: folder, online: true, timeout: .milliseconds(200))
        }
        #expect(clock.now - started < .seconds(5))

        let loader = KnowledgeOriginalLoader(copy: hanging)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            loader.cancel()
        }
        await #expect(throws: CancellationError.self) {
            try await loader.fetch(path: "Versicherungen/Beitragsrechnung 2026.pdf", folder: folder, online: true)
        }
    }

    @Test func leftoverCopiesAreSwept() throws {
        let folder = try LetterFilingTests.temporaryFolder()
        try Data("x".utf8).write(to: folder.appending(path: "old.pdf"))
        KnowledgeOriginal.sweepCopies(in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }
}

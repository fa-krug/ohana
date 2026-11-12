import Foundation

// The knowledge base's documents as the app shows them (server/lib/knowledge/documents.ts, routes
// GET /knowledge/documents[/{id}], …/card, …/exclude). Decoded leniently: a server from before a
// field (the card's status, the person, the facts) still shows its documents.

/// A document's state in the index.
nonisolated enum KnowledgeDocumentStatus: String, Decodable, Hashable, Sendable {
    /// Waiting for the server's worker to read its text.
    case pending
    case ready
    /// Its text couldn't be indexed (`error`).
    case failed
    /// Its file isn't in the folder any more.
    case missing
    /// Left out by an editor.
    case excluded

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A status a newer server knows: shown as an ordinary document.
        self = Self(rawValue: raw) ?? .ready
    }
}

/// The state of a document's card (summary, facts, date, person).
nonisolated enum KnowledgeCardStatus: String, Decodable, Hashable, Sendable {
    /// Waiting for the worker (or for the family's AI to be set up: `KnowledgeStatusInfo.cards`).
    case pending
    case ready
    case failed
    /// No text to make one of.
    case noCard = "none"

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .noCard
    }
}

/// Whose a document is (the card's), while they're in the family: an account or a person.
nonisolated struct KnowledgePerson: Decodable, Hashable, Sendable {
    var id: String
    var name: String
    /// Has an account.
    var account: Bool?
}

/// A document of the list (KnowledgeDocumentSummary).
nonisolated struct KnowledgeDocumentSummary: Decodable, Hashable, Identifiable, Sendable {
    var id: String
    var folderId: String
    /// Relative to the knowledge folder, NFC, "/"-separated.
    var path: String
    var name: String
    var tags: [String]
    var size: Int64
    /// The file's modification date, in ms since 1970.
    var mtime: Int64
    var hash: String
    var pages: Int
    var status: KnowledgeDocumentStatus
    var error: String?
    var summary: String?
    /// The document's own date (the card's), "YYYY-MM-DD".
    var docDate: String?
    var person: KnowledgePerson?
    var missingSince: String?
    /// Nil from a server from before the cards' state.
    var cardStatus: KnowledgeCardStatus?
    /// Why the card failed (`cardStatus` failed).
    var cardError: String?
    /// The pages the family's AI transcribed from their image (from 1); empty from an older server.
    var aiPages: [Int]

    private enum CodingKeys: String, CodingKey {
        case id, folderId, path, name, tags, size, mtime, hash, pages, status, error, summary, docDate, person,
             missingSince, cardStatus, cardError, aiPages
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        let last = path.split(separator: "/").last.map(String.init) ?? path
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? last
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        mtime = (try? c.decodeIfPresent(Int64.self, forKey: .mtime)) ?? 0
        hash = (try? c.decodeIfPresent(String.self, forKey: .hash)) ?? ""
        pages = (try? c.decodeIfPresent(Int.self, forKey: .pages)) ?? 0
        status = try c.decodeIfPresent(KnowledgeDocumentStatus.self, forKey: .status) ?? .ready
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        docDate = try? c.decodeIfPresent(String.self, forKey: .docDate)
        person = try? c.decodeIfPresent(KnowledgePerson.self, forKey: .person)
        missingSince = try? c.decodeIfPresent(String.self, forKey: .missingSince)
        cardStatus = try? c.decodeIfPresent(KnowledgeCardStatus.self, forKey: .cardStatus)
        cardError = try? c.decodeIfPresent(String.self, forKey: .cardError)
        aiPages = (try? c.decodeIfPresent([Int].self, forKey: .aiPages)) ?? []
    }

    /// The folders the file is in (relative to the knowledge folder; empty at its top).
    var folderParts: [String] { Array(KnowledgePath.parts(path).dropLast()) }

    /// The file's modification date.
    var modified: Date { Date(timeIntervalSince1970: Double(mtime) / 1000) }

    /// What the file is, for its icon.
    var kind: KnowledgeFileKind { KnowledgeFileKind(path: path) }
}

/// A fact of a document's card: a short statement and the verbatim quote it rests on, on `page`.
nonisolated struct KnowledgeFact: Decodable, Hashable, Sendable {
    var text: String
    var quote: String
    var chunkId: Int?
    /// From 1.
    var page: Int?

    private enum CodingKeys: String, CodingKey { case text, quote, chunkId, page }

    init(text: String, quote: String, chunkId: Int? = nil, page: Int? = nil) {
        self.text = text
        self.quote = quote
        self.chunkId = chunkId
        self.page = page
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        quote = (try? c.decodeIfPresent(String.self, forKey: .quote)) ?? ""
        chunkId = try? c.decodeIfPresent(Int.self, forKey: .chunkId)
        page = try? c.decodeIfPresent(Int.self, forKey: .page)
    }
}

/// A page image waiting for the family's AI, or one it couldn't transcribe (done ones aren't listed).
nonisolated struct KnowledgePageScanState: Decodable, Hashable, Sendable {
    nonisolated enum Status: String, Decodable, Hashable, Sendable {
        case waiting, running, done, failed

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .waiting
        }
    }

    /// From 1.
    var page: Int
    var status: Status
    var error: String?
}

/// A piece of a document's text (about 1 000 characters, never across pages).
nonisolated struct KnowledgeChunk: Decodable, Hashable, Identifiable, Sendable {
    var id: Int
    var seq: Int
    /// From 1.
    var page: Int
    var text: String
}

/// GET /knowledge/documents/{id}: the document with its card's facts and its text.
nonisolated struct KnowledgeDocumentDetail: Decodable, Hashable, Sendable {
    /// A page of the text.
    nonisolated struct PageText: Hashable, Sendable {
        var page: Int
        var text: String
    }

    var document: KnowledgeDocumentSummary
    /// Nil without a card.
    var facts: [KnowledgeFact]?
    var chunks: [KnowledgeChunk]
    /// The page images not transcribed yet, or that failed; empty from an older server.
    var scans: [KnowledgePageScanState]
    /// The text page by page (chunks joined in order), pages without text left out. Worked out
    /// once, while decoding (off the main thread), not on every redraw of the page.
    let textByPage: [PageText]

    private enum CodingKeys: String, CodingKey { case facts, chunks, scans }

    init(from decoder: any Decoder) throws {
        document = try KnowledgeDocumentSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Facts without their text (an older card) are left out.
        facts = (try? c.decodeIfPresent([KnowledgeFact].self, forKey: .facts))?
            .map { $0.filter { !$0.text.isEmpty } }
        chunks = (try? c.decodeIfPresent([KnowledgeChunk].self, forKey: .chunks)) ?? []
        scans = ((try? c.decodeIfPresent([KnowledgePageScanState].self, forKey: .scans)) ?? [])
            .filter { $0.status != .done }
        textByPage = Self.pages(chunks)
    }

    private static func pages(_ chunks: [KnowledgeChunk]) -> [PageText] {
        let sorted = chunks.sorted { ($0.page, $0.seq) < ($1.page, $1.seq) }
        var pages: [PageText] = []
        for chunk in sorted {
            if let last = pages.last, last.page == chunk.page {
                pages[pages.count - 1].text += "\n\n" + chunk.text
            } else {
                pages.append(PageText(page: chunk.page, text: chunk.text))
            }
        }
        return pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

nonisolated struct KnowledgeDocumentResponse: OffMainDecodable {
    var document: KnowledgeDocumentDetail
}

/// POST …/card and …/exclude answer the document without facts or chunks.
nonisolated struct KnowledgeDocumentSummaryResponse: OffMainDecodable {
    var document: KnowledgeDocumentSummary
}

/// A page of GET /knowledge/documents (decoded off the main thread).
nonisolated struct KnowledgeDocumentsPage: Decodable, Hashable, OffMainDecodable {
    var documents: [KnowledgeDocumentSummary]
    /// Nil on the last page.
    var nextCursor: String?

    private enum CodingKeys: String, CodingKey { case documents, nextCursor }

    init(documents: [KnowledgeDocumentSummary], nextCursor: String?) {
        self.documents = documents
        self.nextCursor = nextCursor
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documents = try c.decode([KnowledgeDocumentSummary].self, forKey: .documents)
        nextCursor = try? c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

extension KnowledgeDocumentsPage {
    /// The most a refresh asks for at once (the server's page limit).
    static let maxRefresh = 200

    /// How many documents a refresh asks for: as many as are loaded (at least a page, at most
    /// `maxRefresh`), so it doesn't cut the list back to its first page.
    static func refreshLimit(loaded: Int) -> Int {
        min(max(loaded, KnowledgeDocumentQuery.pageSize), maxRefresh)
    }

    /// The loaded documents after a refresh that asked for `limit`: `fresh` in place of their
    /// start; beyond `limit` the loaded ones stay (those `fresh` has left out), with their cursor.
    func refreshed(with fresh: KnowledgeDocumentsPage, limit: Int) -> KnowledgeDocumentsPage {
        guard documents.count > limit else { return fresh }
        let ids = Set(fresh.documents.map(\.id))
        return KnowledgeDocumentsPage(documents: fresh.documents + documents.dropFirst(limit).filter { !ids.contains($0.id) },
                                      nextCursor: nextCursor)
    }

    /// A later page after the loaded ones (one already there isn't added twice).
    func appending(_ page: KnowledgeDocumentsPage) -> KnowledgeDocumentsPage {
        let ids = Set(documents.map(\.id))
        return KnowledgeDocumentsPage(documents: documents + page.documents.filter { !ids.contains($0.id) },
                                      nextCursor: page.nextCursor)
    }
}

/// What the list asks for: a tag, a subfolder, whose documents, or the left-out ones.
nonisolated struct KnowledgeDocumentQuery: Hashable, Sendable {
    var tag: String?
    /// A subfolder ("Insurance/Car"), with its subfolders.
    var folder: String?
    /// A member's id (an account's or a person's).
    var person: String?
    /// The left-out documents instead of the others.
    var excluded = false

    static let pageSize = 50

    /// Anything narrows the list.
    var isFiltered: Bool { tag != nil || folder != nil || person != nil || excluded }

    /// The query of GET /knowledge/documents (empty parts left out).
    func items(cursor: String? = nil, limit: Int = pageSize) -> [String: String?] {
        var items: [String: String?] = ["limit": String(limit)]
        if let tag, !tag.isEmpty { items["tag"] = tag }
        if let folder, !folder.isEmpty { items["folder"] = folder }
        if let person, !person.isEmpty { items["person"] = person }
        if excluded { items["status"] = KnowledgeDocumentStatus.excluded.rawValue }
        if let cursor { items["cursor"] = cursor }
        return items
    }
}

/// Paths in the knowledge folder, for people.
nonisolated enum KnowledgePath {
    static func parts(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// "Folder › Sub › file.pdf".
    static func breadcrumb(_ path: String) -> String {
        parts(path).joined(separator: " › ")
    }

    /// The folder's last part ("Insurance/Car" → "Car").
    static func folderName(_ folder: String) -> String {
        parts(folder).last ?? folder
    }

    /// The folder `folder` is in; nil at the top.
    static func parent(_ folder: String) -> String? {
        let parts = parts(folder)
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    /// The subfolders right under `folder` (nil: the top) that `paths` (files) are in, sorted.
    static func subfolders(of paths: some Sequence<String>, under folder: String?) -> [String] {
        let base = folder.map(parts) ?? []
        var found = Set<String>()
        for path in paths {
            let folders = parts(path).dropLast()
            guard folders.count > base.count, Array(folders.prefix(base.count)) == base else { continue }
            found.insert(folders.prefix(base.count + 1).joined(separator: "/"))
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// A file's kind by its extension, for its icon and how *Open original* shows it.
nonisolated enum KnowledgeFileKind: Equatable, Sendable {
    case pdf, image, text, other

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp": self = .image
        case "txt", "md", "markdown", "rtf", "html", "htm", "doc", "docx", "pages", "odt": self = .text
        default: self = .other
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .text: "doc.text"
        case .other: "doc"
        }
    }
}

extension KnowledgeStatusInfo {
    /// The server makes cards (the family's AI is set up); false from a server from before them.
    var makesCards: Bool { cards == true }
}

extension FamilyAPI {
    /// The first page of documents, kept on the device.
    func knowledgeDocuments(_ query: KnowledgeDocumentQuery) -> CachedGet<KnowledgeDocumentsPage> {
        cached("/knowledge/documents", query: query.items())
    }

    /// A later page.
    func knowledgeDocuments(_ query: KnowledgeDocumentQuery, cursor: String) async throws -> KnowledgeDocumentsPage {
        try await get("/knowledge/documents", query: query.items(cursor: cursor))
    }

    /// A document with its card and text, kept on the device.
    func knowledgeDocument(_ id: String) -> CachedGet<KnowledgeDocumentResponse> {
        cached("/knowledge/documents/\(id)")
    }

    /// Asks the server to write the document's card (summary, facts) again (202; 409 where it can't).
    @discardableResult
    func rewriteKnowledgeCard(_ id: String) async throws -> KnowledgeDocumentSummary {
        let answer: KnowledgeDocumentSummaryResponse = try await send(.post, "/knowledge/documents/\(id)/card",
                                                                      body: [String: String]())
        return answer.document
    }

    /// Leaves the document out of the knowledge base, or lets it back in.
    @discardableResult
    func setKnowledgeDocumentExcluded(_ id: String, _ excluded: Bool) async throws -> KnowledgeDocumentSummary {
        let answer: KnowledgeDocumentSummaryResponse = try await send(.post, "/knowledge/documents/\(id)/exclude",
                                                                      body: ["excluded": excluded])
        return answer.document
    }
}

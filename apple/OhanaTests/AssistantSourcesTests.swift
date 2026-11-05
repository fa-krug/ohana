import Foundation
import Testing
@testable import Ohana

/// An answer's knowledge sources: the `[[k:<n>]]` markers, the items' `sources`, the search tab's
/// knowledge hits (server lib/assistant/tools/knowledge.ts, lib/families/search.ts).
struct AssistantSourcesTests {
    private let sources = [
        AssistantSource(ref: "k:12", chunkId: 12, documentId: "d1", name: "Car insurance.pdf",
                        path: "Insurance/Car insurance.pdf", page: 3, quote: "The policy runs until 2027."),
        AssistantSource(ref: "k:40", chunkId: 40, documentId: "d2", name: "Lease.pdf", path: "Lease.pdf"),
    ]

    private func chip(_ text: String) -> String { AssistantSourceMarkers.replace(text, sources: sources) { "<\($0)>" } }

    @Test func markersBecomeNumberedChips() {
        // Numbered by the sources' order, not by where they first appear; the space before a chip goes.
        #expect(chip("It runs until 2027 [[k:12]]. The rent is 900 € [[k:40]].")
                == "It runs until 2027<1>. The rent is 900 €<2>.")
        #expect(chip("Rent first [[k:40]], then the car [[k:12]].") == "Rent first<2>, then the car<1>.")
        // A ref named twice keeps its number; markers side by side each get theirs.
        #expect(chip("A [[k:12]] and B [[k:12]][[k:40]].") == "A<1> and B<1><2>.")
        // Spaces inside the marker are tolerated.
        #expect(chip("A [[k: 12 ]].") == "A<1>.")
    }

    @Test func markersWithoutSourceAreHidden() {
        #expect(chip("Unchecked [[k:99]]. Checked [[k:12]].") == "Unchecked. Checked<1>.")
        #expect(AssistantSourceMarkers.replace("No sources [[k:12]].", sources: []) { "<\($0)>" } == "No sources.")
        // Not a marker: left alone.
        #expect(chip("A [[link]] and [k:12] stay.") == "A [[link]] and [k:12] stay.")
    }

    @Test func partialMarkerAtTheEndIsHidden() {
        for partial in ["[", "[[", "[[k", "[[k:", "[[k:1", "[[k:12", "[[k:12]"] {
            #expect(chip("It runs until 2027 " + partial) == "It runs until 2027", "\(partial)")
        }
        #expect(chip("Done [[k:12]] and [[k:4") == "Done<1> and")
        // Only at the end: inside the text a lone "[" stays.
        #expect(chip("A [ B") == "A [ B")
    }

    @Test func plainAndTranscript() {
        #expect(AssistantSourceMarkers.plain("Until 2027 [[k:12]].", sources: sources) == "Until 2027[1].")
        let transcript = AssistantSourceMarkers.transcript("Until 2027 [[k:12]].", sources: sources)
        #expect(transcript.hasPrefix("Until 2027[1].\n\n"))
        #expect(transcript.contains("[1] Car insurance.pdf"))
        #expect(transcript.contains("(Insurance/Car insurance.pdf)"))
        #expect(transcript.contains("[2] Lease.pdf"))
        #expect(AssistantSourceMarkers.transcript("Plain [[k:3]].", sources: []) == "Plain.")
    }

    @Test func placeholdersBecomeChips() throws {
        let prepared = AssistantSourceMarkers.prepare("It **runs** until 2027 [[k:40]].", sources: sources)
        #expect(prepared == "It **runs** until 2027\u{E000}2\u{E001}.")
        let text = AssistantMarkdownBlock.inline(prepared)
        #expect(String(text.characters) == "It runs until 2027[2].")
        let chip = try #require(text.runs.first { $0.link != nil })
        #expect(chip.link == URL(string: "ohana-source://2"))
        #expect(String(text[chip.range].characters) == "[2]")
        #expect(AssistantSourceMarkers.number(of: URL(string: "ohana-source://2")!) == 2)
        #expect(AssistantSourceMarkers.number(of: URL(string: "https://example.com")!) == nil)
        // The chip's link opens its source; a number without one, or another link, none.
        #expect(AssistantSourceMarkers.source(of: try #require(chip.link), in: sources) == sources[1])
        #expect(AssistantSourceMarkers.source(of: URL(string: "ohana-source://1")!, in: sources) == sources[0])
        #expect(AssistantSourceMarkers.source(of: URL(string: "ohana-source://9")!, in: sources) == nil)
        #expect(AssistantSourceMarkers.source(of: URL(string: "ohana-source://0")!, in: sources) == nil)
        #expect(AssistantSourceMarkers.source(of: URL(string: "https://example.com/1")!, in: sources) == nil)
        // In code no chip can go.
        #expect(AssistantSourceMarkers.stripPlaceholders("let a = 1\u{E000}2\u{E001}") == "let a = 1")
    }

    @Test func highlightExcerpt() {
        let quote = """
        Die Versicherung   beginnt am 1. Januar 2025
        und endet am 31. Dezember 2027, wenn sie nicht vorher gekündigt wird. Weitere Bedingungen folgen.
        """
        let excerpt = AssistantSourceExcerpt.highlight(quote)
        #expect(excerpt == "Die Versicherung beginnt am 1. Januar 2025 und endet am 31. Dezember")
        #expect(AssistantSourceExcerpt.highlight("Short one.") == "Short one.")
        #expect(AssistantSourceExcerpt.highlight("  ") == "")
        // A very long word is cut.
        #expect(AssistantSourceExcerpt.highlight(String(repeating: "x", count: 300)).count == 120)
        // It is found in the page's text like a fact's quote.
        let page = "Seite 3\nDie Versicherung beginnt am 1. Januar 2025 und endet am 31. Dezember 2027."
        #expect(KnowledgeQuoteMatch.range(of: excerpt, in: page) != nil)
    }

    @Test func placeholderCharactersInTheAnswerAreNotChips() {
        // A lone U+E000 doesn't cut off the rest; a fake pair doesn't become a chip.
        let lone = AssistantSourceMarkers.prepare("A \u{E000}lone one [[k:12]] and more.", sources: sources)
        #expect(lone == "A lone one\u{E000}1\u{E001} and more.")
        #expect(String(AssistantMarkdownBlock.inline(lone).characters) == "A lone one[1] and more.")
        let fake = AssistantSourceMarkers.prepare("Fake \u{E000}2\u{E001} chip, \u{E001}stray.", sources: sources)
        #expect(fake == "Fake 2 chip, stray.")
        let rendered = AssistantMarkdownBlock.inline(fake)
        #expect(String(rendered.characters) == "Fake 2 chip, stray.")
        #expect(rendered.runs.allSatisfy { $0.link == nil })
        // Joined to a combining mark it is still left out.
        #expect(AssistantSourceMarkers.prepare("x\u{E000}\u{301}y", sources: []) == "x\u{301}y")
        // The renderer itself drops a placeholder without its pair, or with more than a number in it.
        let broken = AssistantSourceMarkers.chips(in: AttributedString("a\u{E000}b \u{E000}x\u{E001}c \u{E000}3\u{E001}"))
        #expect(String(broken.characters) == "ab xc [3]")
    }

    @Test func excerptMarkedInTheQuote() throws {
        let quote = "Section 4. The policy runs until 31 December 2027. It renews by itself unless cancelled."
        let (text, start) = AssistantSourceExcerpt.marked(quote, excerpt: "The policy runs until 31 December 2027.")
        #expect(String(text.characters) == quote)
        let marked = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(marked.count == 1)
        #expect(String(text[try #require(marked.first).range].characters) == "The policy runs until 31 December 2027")
        let share = try #require(start)
        #expect(share > 0.1 && share < 0.2)
        // Not in the quote: the quote alone.
        let (plain, none) = AssistantSourceExcerpt.marked(quote, excerpt: "Something else entirely")
        #expect(none == nil)
        #expect(plain.runs.allSatisfy { $0.inlinePresentationIntent == nil })
        #expect(AssistantSourceExcerpt.marked(quote, excerpt: "").start == nil)

        // What Open Original and Show in Knowledge Base mark: the excerpt, else the quote's first words.
        var source = AssistantSource(ref: "k:1", documentId: "d", name: "a.pdf", quote: quote, excerpt: "It renews by itself")
        #expect(AssistantSourceExcerpt.highlight(source) == "It renews by itself")
        source.excerpt = ""
        #expect(AssistantSourceExcerpt.highlight(source) == "Section 4. The policy runs until 31 December 2027. It renews by")
        source.quote = ""
        #expect(AssistantSourceExcerpt.highlight(source) == nil)
    }

    @Test func refusedDocumentGoneOrNoAccess() {
        // The knowledge base answers: the document is gone.
        #expect(AssistantSourceAvailability.refused(document: 404, knowledgeBase: nil) == .gone)
        #expect(AssistantSourceAvailability.refused(document: 404, knowledgeBase: 500) == .gone)
        // The knowledge base refused too (module off, no longer an editor).
        #expect(AssistantSourceAvailability.refused(document: 404, knowledgeBase: 404) == .noAccess)
        #expect(AssistantSourceAvailability.refused(document: 404, knowledgeBase: 403) == .noAccess)
        #expect(AssistantSourceAvailability.refused(document: 403, knowledgeBase: nil) == .noAccess)
        #expect(AssistantSourceAvailability.refused(document: 500, knowledgeBase: nil) == nil)
        #expect(AssistantSourceAvailability.gone.message != nil)
        #expect(AssistantSourceAvailability.noAccess.message != nil)
        #expect(AssistantSourceAvailability.available.message == nil)
    }

    @Test func itemsDecodeWithAndWithoutSources() throws {
        let json = """
        [
          { "kind": "assistant", "text": "Until 2027 [[k:12]].", "sources": [
            { "ref": "k:12", "chunkId": 12, "documentId": "d1", "name": "Car insurance.pdf", "path": "Insurance/Car insurance.pdf", "page": 3, "quote": "The policy runs until 2027.", "excerpt": " runs until 2027 " },
            { "ref": "k:12", "chunkId": 12, "documentId": "d1", "name": "Again.pdf" },
            { "ref": "k:7", "chunkId": 7, "name": "No document" },
            { "chunkId": 40, "documentId": "d2", "path": "Lease.pdf", "page": "x" },
            "nonsense"
          ] },
          { "kind": "assistant", "text": "Plain." },
          { "kind": "assistant", "text": "Bad sources.", "sources": { "x": 1 } }
        ]
        """
        let items = try JSONDecoder().decode([AssistantItem].self, from: Data(json.utf8))
        guard case let .assistant(text, sources) = items[0] else { Issue.record("not an answer"); return }
        #expect(text == "Until 2027 [[k:12]].")
        #expect(sources.map(\.ref) == ["k:12", "k:40"])
        // The excerpt is new: trimmed, and "" from an older server.
        #expect(sources[0].excerpt == "runs until 2027")
        var withoutExcerpt = sources[0]
        withoutExcerpt.excerpt = ""
        #expect(withoutExcerpt == self.sources[0])
        #expect(sources[1].excerpt == "")
        // Without a ref: from its chunk; without a name: the path's last part.
        #expect(sources[1].name == "Lease.pdf")
        #expect(sources[1].page == nil)
        #expect(items[1] == .assistant(text: "Plain."))
        #expect(items[2] == .assistant(text: "Bad sources.", sources: []))
    }

    @Test func streamingKeepsSources() {
        let store = AssistantChatStore(api: FamilyAPI(client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil),
                                                      familyID: "f1"))
        store.show(AssistantChat(id: "c1", title: "Hi", status: "running", items: [.user(text: "Hi", attachments: [])],
                                 rev: 1, usage: nil, page: "overview", queued: []))
        store.apply("c1", .items(rev: 2, items: [(1, .assistant(text: "Until", sources: sources))]))
        store.apply("c1", .delta(seq: 1, text: " 2027 [[k:12"))
        #expect(store.current?.items[1] == .assistant(text: "Until 2027 [[k:12", sources: sources))
    }

    @Test func searchDecodesKnowledgeHits() throws {
        let json = """
        {
          "query": "insurance", "currency": "EUR",
          "results": [
            { "kind": "recipe", "id": "r1", "title": "Soup", "detail": "", "day": null },
            { "kind": "knowledge", "id": "d1", "title": "Car insurance.pdf", "detail": "Insurance/Car · policy", "day": "2025-01-02", "page": 3, "snippet": "…the policy runs until 2027…" },
            { "kind": "knowledge", "id": "d2", "title": "Scan.jpg", "detail": "", "day": null },
            { "kind": "chat", "id": "c1", "title": "Insurance?", "detail": "", "day": null },
            { "kind": "later", "id": "x", "title": "?", "detail": "", "day": null }
          ],
          "more": { "knowledge": 4 }
        }
        """
        let result = try APIClient.decoder.decode(FamilySearchResult.self, from: Data(json.utf8))
        #expect(result.groups.map(\.kind) == [.recipe, .chat, .knowledge])
        let hits = result.groups[2].hits
        #expect(hits.map(\.itemID) == ["d1", "d2"])
        #expect(hits[0].page == 3)
        #expect(hits[0].day == Day(year: 2025, month: 1, day: 2))
        #expect(hits[0].snippet == "…the policy runs until 2027…")
        #expect(hits[0].fileKind == .pdf)
        #expect(hits[1].fileKind == .image)
        #expect(hits[0].route == .knowledgeDocument(id: "d1", page: 3))
        #expect(hits[1].route == .knowledgeDocument(id: "d2", page: nil))
        #expect(FamilySearchHit.Kind.knowledge.module == .knowledge)
        #expect(result.more["knowledge"] == 4)
    }

    @Test func toolLabelsAndLinks() {
        func tool(_ name: String, _ args: [String: JSONValue]) -> AssistantToolCall {
            AssistantToolCall(id: "t", name: name, args: args, status: "ok", summary: nil, result: nil, interrupted: false)
        }
        let search = tool("search_knowledge", ["query": .string("Kfz Versicherung"), "folder": .string("Insurance/Car")])
        #expect(AssistantToolLabels.label(search) == String(localized: "Searching the knowledge base"))
        #expect(AssistantToolLabels.detail(search).contains("Kfz Versicherung"))
        #expect(AssistantToolLabels.detail(search).contains("Insurance › Car"))
        #expect(AssistantToolLabels.icon("read_knowledge") == "books.vertical")
        let read = tool("read_knowledge", ["documentId": .string("d1"), "page": .number(2)])
        #expect(AssistantToolLabels.label(read) == String(localized: "Reading a document"))
        #expect(AssistantToolLinks.route(read, familyID: "f") == .knowledgeDocument(id: "d1", page: 2))
        #expect(AssistantToolLinks.route(tool("read_knowledge", ["documentId": .string("d1")]), familyID: "f")
                == .knowledgeDocument(id: "d1"))
    }
}

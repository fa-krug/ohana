import SwiftUI

// The sources of an answer from the knowledge base (server lib/assistant/tools/knowledge.ts): the
// model cites chunks as `[[k:<chunkId>]]` right after a statement; the saved answer keeps only the
// markers a knowledge tool returned in the chat, and carries their `sources`. The app shows each
// marker as a small numbered chip ([1], [2] … in the sources' order), lists the sources below the
// answer, and a tap shows the quote with *Open Original* and *Show in Knowledge Base*.

/// A passage of a knowledge document an answer rests on. Decoded leniently (an entry without its
/// ref or document is left out by `AssistantSource.list`).
nonisolated struct AssistantSource: Decodable, Hashable, Identifiable, Sendable {
    /// "k:<chunkId>", as the answer's markers name it.
    var ref: String
    var chunkId: Int?
    var documentId: String
    var name: String
    /// Relative to the knowledge folder.
    var path: String
    /// From 1.
    var page: Int?
    /// The chunk's text.
    var quote: String
    /// The sentence(s) of the quote the statement rests on; "" from an older server.
    var excerpt: String

    var id: String { ref }

    init(ref: String, chunkId: Int? = nil, documentId: String, name: String, path: String = "", page: Int? = nil,
         quote: String = "", excerpt: String = "") {
        self.ref = ref
        self.chunkId = chunkId
        self.documentId = documentId
        self.name = name
        self.path = path
        self.page = page
        self.quote = quote
        self.excerpt = excerpt
    }

    private enum Keys: String, CodingKey { case ref, chunkId, documentId, name, path, page, quote, excerpt }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            self.init(ref: "", documentId: "", name: "")
            return
        }
        func str(_ key: Keys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        func int(_ key: Keys) -> Int? {
            if let n = try? c.decodeIfPresent(Int.self, forKey: key) { return n }
            return (try? c.decodeIfPresent(Double.self, forKey: key)).flatMap { $0 == $0.rounded() ? Int($0) : nil }
        }
        let path = str(.path)
        let name = str(.name)
        let chunkId = int(.chunkId)
        var ref = str(.ref)
        if ref.isEmpty, let chunkId { ref = "k:\(chunkId)" }
        self.init(ref: ref, chunkId: chunkId, documentId: str(.documentId),
                  name: name.isEmpty ? (KnowledgePath.parts(path).last ?? path) : name, path: path,
                  page: int(.page).flatMap { $0 > 0 ? $0 : nil }, quote: str(.quote),
                  excerpt: str(.excerpt).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The usable sources of an item, in order: those with a ref and a document, each ref once.
    static func list(_ decoded: [AssistantSource]?) -> [AssistantSource] {
        var seen = Set<String>()
        return (decoded ?? []).filter { !$0.ref.isEmpty && !$0.documentId.isEmpty && seen.insert($0.ref).inserted }
    }

    /// What the file is, for its icon.
    var kind: KnowledgeFileKind { KnowledgeFileKind(path: path.isEmpty ? name : path) }
}

/// The `[[k:<n>]]` markers of an answer's text.
nonisolated enum AssistantSourceMarkers {
    /// Around a chip's number in the text handed to the Markdown renderer (private use: never in
    /// an answer), turned into the chip after the Markdown is read.
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    /// The chips' links (`number(of:)`).
    static let scheme = "ohana-source"

    /// Each source's number (from 1), by ref.
    static func numbers(_ sources: [AssistantSource]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for (index, source) in sources.enumerated() where numbers[source.ref] == nil {
            numbers[source.ref] = index + 1
        }
        return numbers
    }

    /// `text` with every marker that has a source replaced by `chip(number)` (the spaces before it
    /// dropped, so it sits on the statement), the others left out, and a marker still being written
    /// at the end (`[[k:12`) hidden.
    static func replace(_ text: String, sources: [AssistantSource], with chip: (Int) -> String) -> String {
        let numbers = numbers(sources)
        var text = text.replacing(/[ \t]*\[(?:\[(?:k(?::\s*\d*\s*\]?)?)?)?\z/, with: "")
        text = text.replacing(/[ \t]*\[\[k:\s*(\d+)\s*\]\]/) { match in
            let ref = "k:" + String(Int(match.output.1) ?? -1)
            return numbers[ref].map(chip) ?? ""
        }
        return text
    }

    /// The text for the Markdown renderer: chips as placeholders (`chips(in:)`); the placeholders'
    /// characters already in the text are left out first, so only the chips make placeholders.
    static func prepare(_ text: String, sources: [AssistantSource]) -> String {
        replace(withoutPlaceholderCharacters(text), sources: sources) { "\(open)\($0)\(close)" }
    }

    private static let openScalar: Unicode.Scalar = "\u{E000}"
    private static let closeScalar: Unicode.Scalar = "\u{E001}"

    /// `text` without U+E000 / U+E001 (by scalar: one joined to a combining mark too).
    static func withoutPlaceholderCharacters(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == openScalar || $0 == closeScalar }) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0 != openScalar && $0 != closeScalar })
        return String(scalars)
    }

    /// The text to copy: chips as "[n]".
    static func plain(_ text: String, sources: [AssistantSource]) -> String {
        replace(text, sources: sources) { "[\($0)]" }
    }

    /// The placeholders left out (code, where no chip can go).
    static func stripPlaceholders(_ text: String) -> String {
        withoutPlaceholderCharacters(text.replacing(/\x{E000}[0-9]+\x{E001}/, with: ""))
    }

    /// The source number a chip's link names; nil for other links.
    static func number(of url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.host() ?? "")
    }

    /// The answer with its sources as footnotes, for the clipboard.
    static func transcript(_ text: String, sources: [AssistantSource]) -> String {
        let body = plain(text, sources: sources)
        guard !sources.isEmpty else { return body }
        let lines = sources.enumerated().map { index, source in
            "[\(index + 1)] " + label(source) + (source.path.isEmpty ? "" : " (\(source.path))")
        }
        return body + "\n\n" + String(localized: "Sources") + ":\n" + lines.joined(separator: "\n")
    }

    /// "Name.pdf, page 3".
    static func label(_ source: AssistantSource) -> String {
        guard let page = source.page else { return source.name }
        return source.name + ", " + String(localized: "Page \(page)")
    }
}

extension AssistantSourceMarkers {
    /// `text` (read from the Markdown) with each placeholder as a chip: "[n]", small and raised,
    /// linking to `ohana-source://n`.
    /// A placeholder without its pair, or with more than a number in it, is dropped (its characters
    /// only, never the text after them).
    static func chips(in text: AttributedString) -> AttributedString {
        var text = text
        while let start = text.unicodeScalars.firstIndex(of: openScalar) {
            let after = text.unicodeScalars.index(after: start)
            let end = text.unicodeScalars[after...].firstIndex(of: closeScalar)
            var digits = String.UnicodeScalarView()
            if let end { digits.append(contentsOf: text.unicodeScalars[after..<end]) }
            guard let end, !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else {
                text.removeSubrange(start..<after)
                continue
            }
            var chip = AttributedString("[\(String(digits))]")
            chip.link = URL(string: "\(scheme)://\(String(digits))")
            chip.font = Font.caption2.weight(.semibold).monospacedDigit()
            chip.baselineOffset = 5
            text.replaceSubrange(start..<text.unicodeScalars.index(after: end), with: chip)
        }
        while let stray = text.unicodeScalars.firstIndex(of: closeScalar) {
            text.removeSubrange(stray..<text.unicodeScalars.index(after: stray))
        }
        return text
    }
}

/// What of a source's quote is marked: its `excerpt` (the sentences the statement rests on), else
/// the quote's first words (the quote is a whole chunk, whose text in the PDF may differ further on);
/// found like a fact's quote (`KnowledgeQuoteMatch`).
nonisolated enum AssistantSourceExcerpt {
    /// What *Open Original* and *Show in Knowledge Base* mark; nil when there is nothing.
    static func highlight(_ source: AssistantSource) -> String? {
        let text = source.excerpt.isEmpty ? highlight(source.quote) : source.excerpt
        return text.isEmpty ? nil : text
    }

    /// The quote with its excerpt marked (bold, on a tinted background), and where the excerpt starts
    /// (0…1 of the quote's length, to scroll it into view); the quote alone when the excerpt isn't in it.
    static func marked(_ quote: String, excerpt: String) -> (text: AttributedString, start: Double?) {
        var result = AttributedString(quote)
        guard !excerpt.isEmpty, !quote.isEmpty, let range = KnowledgeQuoteMatch.range(of: excerpt, in: quote),
              let marked = Range<AttributedString.Index>(range, in: result) else { return (result, nil) }
        result[marked].inlinePresentationIntent = .stronglyEmphasized
        result[marked].backgroundColor = Color.yellow.opacity(0.35)
        let start = Double(quote.distance(from: quote.startIndex, to: range.lowerBound)) / Double(quote.count)
        return (result, start)
    }

    static func highlight(_ quote: String, words: Int = 12, maxLength: Int = 120) -> String {
        var result = ""
        for word in quote.split(whereSeparator: \.isWhitespace).prefix(words) {
            let next = result.isEmpty ? String(word) : result + " " + word
            if next.count > maxLength, !result.isEmpty { break }
            result = next
        }
        return result.count > maxLength ? String(result.prefix(maxLength)) : result
    }
}

// MARK: Views

/// An answer of the assistant: its Markdown with the source chips, and its sources below; a chip
/// or a source shows the source (`AssistantSourceSheet`).
struct AssistantAnswerView: View {
    let text: String
    let sources: [AssistantSource]
    var open: (AppRoute) -> Void = { _ in }
    @Environment(\.openURL) private var openURL
    @State private var shown: AssistantSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssistantMarkdownView(text: text, sources: sources)
            if !sources.isEmpty {
                AssistantSourcesList(sources: sources) { shown = $0 }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let number = AssistantSourceMarkers.number(of: url) {
                if sources.indices.contains(number - 1) { shown = sources[number - 1] }
                return .handled
            }
            openURL(url)
            return .handled
        })
        .sheet(item: $shown) { source in
            AssistantSourceSheet(source: source, number: (sources.firstIndex(of: source) ?? 0) + 1) { route in
                shown = nil
                open(route)
            }
        }
    }
}

/// The sources below an answer: number, the file's icon, its name and page.
struct AssistantSourcesList: View {
    let sources: [AssistantSource]
    let select: (AssistantSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                Button { select(source) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "[\(index + 1)]")
                            .monospacedDigit()
                            .foregroundStyle(ModuleTint.knowledge)
                        Image(systemName: source.kind.systemImage)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: source.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let page = source.page {
                            Text("Page \(page)")
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    }
                    .font(.caption)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows the passage"))
            }
        }
        .padding(.top, 2)
    }
}

/// Whether a source's document can be shown: a 404 for the document is either the document gone
/// from the knowledge base or the knowledge base no longer this account's (the module turned off,
/// no longer an editor: the server answers both 404), told apart by asking for the knowledge base
/// itself.
nonisolated enum AssistantSourceAvailability: Equatable, Sendable {
    case checking, available, gone, noAccess

    /// After the document's request was refused with `document` (an HTTP status): `knowledgeBase` is
    /// the status of `GET /knowledge/status` (nil: it answered).
    static func refused(document: Int, knowledgeBase: Int?) -> Self? {
        if document == 403 { return .noAccess }
        guard document == 404 else { return nil }
        if let status = knowledgeBase, status == 403 || status == 404 { return .noAccess }
        return .gone
    }

    /// Why the buttons are off.
    var message: LocalizedStringKey? {
        switch self {
        case .gone: "This document is no longer in the knowledge base."
        case .noAccess: "The knowledge base isn’t available to you."
        case .checking, .available: nil
        }
    }
}

/// One source: the document, where it is, its page and the passage (the whole chunk, the sentences
/// the statement rests on marked and scrolled into view); *Open Original* opens the file at that
/// page with those sentences marked, *Show in Knowledge Base* the document's page. A document gone
/// from the knowledge base, or a knowledge base no longer this account's, says so.
struct AssistantSourceSheet: View {
    let source: AssistantSource
    let number: Int
    /// Opens a place of the app (the sheet closes first).
    let show: (AppRoute) -> Void
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var opener = KnowledgeOriginalOpener()
    /// The document as the server has it now (its path may have changed).
    @State private var document: KnowledgeDocumentSummary?
    @State private var availability: AssistantSourceAvailability = .checking

    private var refused: Bool { availability == .gone || availability == .noAccess }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if let message = availability.message {
                            Label(message, systemImage: availability == .gone ? "questionmark.folder" : "lock")
                                .foregroundStyle(.orange)
                        }
                        actions
                        if !source.quote.isEmpty {
                            Text(quote.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentCard(cornerRadius: 16, padding: 12, tint: ModuleTint.knowledge)
                                .id(Self.quoteID)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task {
                    // The excerpt in view: the quote's point at the excerpt's share of its length
                    // goes to the same share of the visible height.
                    guard let start = quote.start else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(Self.quoteID, anchor: UnitPoint(x: 0.5, y: start)) }
                }
            }
            .ohanaBackground(ModuleTint.knowledge)
            .navigationTitle(Text("Source \(number)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .knowledgeOriginal(opener)
        .task { await check() }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 480)
        #endif
    }

    private static let quoteID = "quote"

    private var quote: (text: AttributedString, start: Double?) {
        AssistantSourceExcerpt.marked(source.quote, excerpt: source.excerpt)
    }

    private var name: String { document?.name ?? source.name }
    private var path: String { document?.path ?? source.path }

    private var header: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name)
                    .font(.headline)
                if KnowledgePath.parts(path).count > 1 {
                    Text(verbatim: KnowledgePath.breadcrumb(path))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let page = source.page {
                    Text("Page \(page)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        } icon: {
            Image(systemName: KnowledgeFileKind(path: path.isEmpty ? name : path).systemImage)
                .foregroundStyle(ModuleTint.knowledge)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }
            VStack(alignment: .leading, spacing: 10) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Open Original", systemImage: "arrow.up.forward.square") { openOriginal() }
            .buttonStyle(.glassProminent)
            .disabled(refused || opener.loading)
        Button("Show in Knowledge Base", systemImage: "books.vertical") {
            show(.knowledgeDocument(id: source.documentId, page: source.page, quote: AssistantSourceExcerpt.highlight(source)))
        }
        .buttonStyle(.glass)
        .disabled(refused || !family.knowledgeAvailable)
    }

    /// Whether the document is still there (and where); offline the source's own path is used.
    private func check() async {
        guard family.knowledgeAvailable else {
            availability = .noAccess
            return
        }
        do {
            document = try await family.api.knowledgeDocument(source.documentId).fetch().document.document
            availability = .available
        } catch let error as APIError where error.status == 403 || error.status == 404 {
            var knowledgeBase: Int?
            do {
                _ = try await family.api.knowledgeStatus().fetch()
            } catch let error as APIError {
                knowledgeBase = error.status
            } catch {}
            availability = AssistantSourceAvailability.refused(document: error.status ?? 404, knowledgeBase: knowledgeBase)
                ?? .available
        } catch {
            document = family.api.knowledgeDocument(source.documentId).saved()?.value.document.document
            availability = .available
        }
    }

    private func openOriginal() {
        Task {
            if availability == .checking { await check() }
            guard !refused else { return }
            opener.open(path: path, name: name, page: source.page, quote: AssistantSourceExcerpt.highlight(source),
                        folder: family.knowledge.folder)
        }
    }
}

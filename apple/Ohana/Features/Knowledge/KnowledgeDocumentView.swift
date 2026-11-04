import SwiftUI

/// One document of the knowledge base: where it is in the folder, its date, whose it is and its
/// tags; its card (the summary and the facts, each with the quote it rests on: a tap opens the
/// original at that quote); where it stands when it isn't simply there; and its text page by page
/// (collapsed; a route's page open, its quote marked). *Open Original* in the toolbar, the rest in
/// its More menu: *Show in Finder* (Mac), *Read Again*, *Leave Out* / *Include Again*.
struct KnowledgeDocumentView: View {
    let target: KnowledgeDocumentTarget
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<KnowledgeDocumentDetail> = .idle
    @State private var members: [KnowledgeMember] = []
    /// The server makes cards (the family's AI is set up): a missing summary is on its way.
    @State private var makesCards = false
    @State private var opener = KnowledgeOriginalOpener()
    /// The pages whose text is open.
    @State private var expanded: Set<Int> = []
    @State private var leavingOut = false

    var body: some View {
        LoadStateView(state: state, retry: load) { detail in
            content(detail)
        }
        .ohanaBackground(ModuleTint.knowledge)
        .navigationTitle(Text(verbatim: state.value?.document.name ?? ""))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let document = state.value?.document { toolbar(document) }
        }
        .task(id: family.revision(.knowledge)) { await load() }
        .onAppear { if let page = target.page { expanded.insert(page) } }
        .knowledgeOriginal(opener)
        .confirmationDialog(Text("Leave “\(state.value?.document.name ?? "")” out of the knowledge base?"),
                            isPresented: $leavingOut, titleVisibility: .visible) {
            Button("Leave Out", role: .destructive) { setExcluded(true) }
        } message: {
            Text("Its text leaves the index; the file stays in the folder.")
        }
    }

    private func load() async {
        await LoadState.run($state, family.api.knowledgeDocument(target.id)) { $0.document }
        let status = family.api.knowledgeStatus()
        if let saved = status.saved()?.value {
            makesCards = saved.makesCards
        } else if let info = try? await status.fetchOrSaved() {
            makesCards = info.makesCards
        }
        if let found = await KnowledgeMember.load(family.api) { members = found }
    }

    // MARK: Content

    private func content(_ detail: KnowledgeDocumentDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(detail.document)
                    statusNote(detail.document)
                    card(detail)
                    text(detail)
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
            .task {
                // A route's page: its text in view.
                guard let page = target.page else { return }
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation { proxy.scrollTo(page, anchor: .top) }
            }
        }
    }

    private func header(_ document: KnowledgeDocumentSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: KnowledgePath.breadcrumb(document.path))
                    .font(.subheadline)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: document.kind.systemImage)
                    .foregroundStyle(ModuleTint.knowledge)
            }
            RecipeFlowLayout(spacing: 14) {
                Label(KnowledgeWording.dateText(document), systemImage: "calendar")
                if let person = document.person {
                    HStack(spacing: 6) {
                        KnowledgePersonIcon(person: person, members: members, size: 20)
                        Text(verbatim: members.first { $0.id == person.id }?.name ?? person.name)
                    }
                }
                if document.pages > 0 {
                    Label("\(document.pages) pages", systemImage: "doc.on.doc")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !document.tags.isEmpty {
                RecipeFlowLayout(spacing: 6) {
                    ForEach(document.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .font(.caption)
                            .chip()
                    }
                }
            }
        }
        .contentCard()
    }

    /// Where the document stands, when it isn't simply there (and its card, while one is made).
    @ViewBuilder
    private func statusNote(_ document: KnowledgeDocumentSummary) -> some View {
        switch document.status {
        case .failed:
            Label(document.error ?? String(localized: "Its text couldn’t be indexed."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .contentCard()
        case .pending:
            Label("Waiting to be read", systemImage: "clock")
                .foregroundStyle(.secondary)
                .contentCard()
        case .missing:
            Label("The file isn’t in the folder any more.", systemImage: "questionmark.folder")
                .foregroundStyle(.orange)
                .contentCard()
        case .excluded:
            Label("Left out of the knowledge base", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
                .contentCard()
        case .ready:
            switch document.cardStatus {
            case .pending where makesCards && document.summary == nil:
                Label("Summary is being written", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                    .contentCard()
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No summary could be written.")
                    if let reason = document.cardError, !reason.isEmpty {
                        Text(verbatim: reason)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Write Summary Again", systemImage: "sparkles") { rewriteCard() }
                        .disabled(state.isSaved)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            default:
                EmptyView()
            }
        }
    }

    /// The summary and the facts.
    @ViewBuilder
    private func card(_ detail: KnowledgeDocumentDetail) -> some View {
        let summary = detail.document.summary.flatMap { $0.isEmpty ? nil : $0 }
        let facts = detail.facts ?? []
        if summary != nil || !facts.isEmpty {
            // Written by the assistant: said once, quietly; the facts keep their quote and page.
            CardSection("Summary", systemImage: "sparkles", tint: ModuleTint.knowledge) {
                Text("By the assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } content: {
                if let summary {
                    Text(verbatim: summary)
                        .textSelection(.enabled)
                }
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 || summary != nil { Divider() }
                    factRow(fact, document: detail.document)
                }
            }
        }
    }

    private func factRow(_ fact: KnowledgeFact, document: KnowledgeDocumentSummary) -> some View {
        Button {
            opener.open(document, page: fact.page, quote: fact.quote, folder: family.knowledge.folder)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: fact.text)
                        .foregroundStyle(.primary)
                    if !fact.quote.isEmpty {
                        Text(verbatim: "“\(fact.quote)”")
                            .font(.footnote)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    if let page = fact.page {
                        Text("Page \(page)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(ModuleTint.knowledge)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the original at this passage"))
    }

    /// The text by page, collapsed.
    @ViewBuilder
    private func text(_ detail: KnowledgeDocumentDetail) -> some View {
        let pages = detail.textByPage
        if !pages.isEmpty {
            CardSection("Text", systemImage: "doc.plaintext", tint: ModuleTint.knowledge) {
                ForEach(Array(pages.enumerated()), id: \.element.page) { index, page in
                    if index > 0 { Divider() }
                    DisclosureGroup(isExpanded: expandedBinding(page.page)) {
                        Text(marked(page.text, quote: page.page == target.page ? target.quote : nil))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Text("Page \(page.page)")
                    }
                    .id(page.page)
                }
            }
        }
    }

    private func expandedBinding(_ page: Int) -> Binding<Bool> {
        Binding {
            expanded.contains(page)
        } set: { open in
            if open { expanded.insert(page) } else { expanded.remove(page) }
        }
    }

    /// `text` with `quote` marked (`KnowledgeQuoteMatch`).
    private func marked(_ text: String, quote: String?) -> AttributedString {
        var result = AttributedString(text)
        guard let quote, let range = KnowledgeQuoteMatch.range(of: quote, in: text),
              let marked = Range<AttributedString.Index>(range, in: result) else { return result }
        result[marked].backgroundColor = Color.yellow.opacity(0.35)
        return result
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ document: KnowledgeDocumentSummary) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Open Original", systemImage: "arrow.up.forward.square") {
                opener.open(document, page: target.page, quote: target.quote, folder: family.knowledge.folder)
            }
            .disabled(opener.loading)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                #if os(macOS)
                Button("Show in Finder", systemImage: "folder") { showInFinder(document) }
                #endif
                Button("Read Again", systemImage: "arrow.clockwise") { reindex() }
                    .disabled(state.isSaved || document.status == .excluded || document.status == .missing)
                if document.status == .ready, makesCards {
                    Button("Write Summary Again", systemImage: "sparkles") { rewriteCard() }
                        .disabled(state.isSaved || document.cardStatus == .pending)
                }
                if document.status == .excluded {
                    Button("Include Again", systemImage: "eye") { setExcluded(false) }
                        .disabled(state.isSaved)
                } else {
                    Button("Leave Out", systemImage: "eye.slash", role: .destructive) { leavingOut = true }
                        .disabled(state.isSaved)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    #if os(macOS)
    private func showInFinder(_ document: KnowledgeDocumentSummary) {
        do {
            try KnowledgeOriginal.showInFinder(path: document.path, folder: family.knowledge.folder)
        } catch let error as KnowledgeOriginalError {
            opener.failure = error
        } catch {
            ErrorBanner.shared.show(error)
        }
    }
    #endif

    private func reindex() {
        perform {
            try await family.api.reindexKnowledgeDocument(target.id)
            family.didChange(.knowledge)
        }
    }

    /// The card written again (the server's 409, e.g. without the assistant, goes to the banner).
    private func rewriteCard() {
        perform {
            try await family.api.rewriteKnowledgeCard(target.id)
            family.didChange(.knowledge)
        }
    }

    private func setExcluded(_ excluded: Bool) {
        perform {
            try await family.api.setKnowledgeDocumentExcluded(target.id, excluded)
            family.didChange(.knowledge)
        }
    }
}

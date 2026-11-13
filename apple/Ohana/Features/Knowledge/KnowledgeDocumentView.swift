import SwiftUI

/// One document of the knowledge base: where it is in the folder, its date, whose it is and its
/// tags; its card (the summary and the facts, each with the quote it rests on: a tap opens the
/// original at that quote; the values it reports, by their section, a tap opens the original at
/// their page); where it stands when it isn't simply there; and its text page by page
/// (collapsed; a route's page open, its quote marked; pages the family's AI transcribed from their
/// image marked "Read by the assistant"). *Open Original* in the toolbar, the rest in its More menu:
/// *Show in Finder* (Mac), *Read Again* and *Read Again with the Assistant* (this device reads the
/// file now and sends it, `KnowledgeIndexer.reread`; the latter sends every page's image to the
/// family's AI too), *Leave Out* / *Include Again*.
struct KnowledgeDocumentView: View {
    let target: KnowledgeDocumentTarget
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<KnowledgeDocumentDetail> = .idle
    @State private var members: [KnowledgeMember] = []
    /// The server makes cards (the family's AI is set up): a missing summary is on its way.
    @State private var makesCards = false
    /// The family's AI can transcribe page images (*Read Again with the Assistant*).
    @State private var readsScans = false
    /// *Read Again* runs.
    @State private var rereading = false
    /// What the last *Read Again* came to, said quietly.
    @State private var rereadNote: String?
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

    /// The document, whether cards are made (the status' copy on the device, else the server's)
    /// and the members, side by side.
    private func load() async {
        async let status = statusInfo()
        async let found = loadMembers()
        await LoadState.run($state, family.api.knowledgeDocument(target.id)) { $0.document }
        if let status = await status {
            makesCards = status.makesCards
            readsScans = status.readsScans
        }
        if let found = await found { members = found }
    }

    /// The index's status: the copy on the device, else the server's.
    private func statusInfo() async -> KnowledgeStatusInfo? {
        let status = family.api.knowledgeStatus()
        if let saved = await status.savedOffMain() { return saved.value }
        return try? await status.fetchOrSaved()
    }

    private func loadMembers() async -> [KnowledgeMember]? {
        await KnowledgeMember.load(family.api)
    }

    // MARK: Content

    private func content(_ detail: KnowledgeDocumentDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(detail.document)
                    statusNote(detail.document)
                    rereadStatus
                    scansNote(detail)
                    card(detail)
                    values(detail)
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

    /// *Read Again* under way, or what it came to.
    @ViewBuilder
    private var rereadStatus: some View {
        if rereading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the file again…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        } else if let rereadNote {
            Label(rereadNote, systemImage: "arrow.clockwise")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    /// The pages' images the family's AI hasn't transcribed yet, or couldn't: said quietly.
    @ViewBuilder
    private func scansNote(_ detail: KnowledgeDocumentDetail) -> some View {
        let waiting = detail.scans.filter { $0.status == .waiting || $0.status == .running }.map(\.page).sorted()
        let failed = detail.scans.filter { $0.status == .failed }.sorted { $0.page < $1.page }
        if !waiting.isEmpty || !failed.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !waiting.isEmpty {
                    Label("Pages waiting for the assistant: \(Self.pageList(waiting))", systemImage: "sparkles")
                }
                ForEach(failed, id: \.page) { scan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The assistant couldn’t read page \(scan.page).")
                        if let error = scan.error, !error.isEmpty {
                            Text(verbatim: error)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    /// "1, 3, 4".
    private static func pageList(_ pages: [Int]) -> String {
        pages.map { $0.formatted() }.joined(separator: ", ")
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

    /// The values the document reports (lab results, grades, readings …), by their section in
    /// the document's order.
    @ViewBuilder
    private func values(_ detail: KnowledgeDocumentDetail) -> some View {
        if !detail.values.isEmpty {
            CardSection("Values", systemImage: "list.number", tint: ModuleTint.knowledge) {
                Text("By the assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } content: {
                ForEach(Array(Self.valueGroups(detail.values).enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    if let title = group.title {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(group.values.enumerated()), id: \.offset) { _, value in
                        valueRow(value, document: detail.document)
                    }
                }
            }
        }
    }

    /// Values one after the other under the same section, together.
    private static func valueGroups(_ values: [KnowledgeValue]) -> [(title: String?, values: [KnowledgeValue])] {
        var groups: [(title: String?, values: [KnowledgeValue])] = []
        for value in values {
            let title = value.group.flatMap { $0.isEmpty ? nil : $0 }
            if let last = groups.last, last.title == title {
                groups[groups.count - 1].values.append(value)
            } else {
                groups.append((title, [value]))
            }
        }
        return groups
    }

    private func valueRow(_ value: KnowledgeValue, document: KnowledgeDocumentSummary) -> some View {
        Button {
            opener.open(document, page: value.page, quote: value.name, folder: family.knowledge.folder)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: value.name)
                        .foregroundStyle(.primary)
                    let details = Self.valueDetails(value)
                    if !details.isEmpty {
                        Text(verbatim: details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: value.valueWithUnit)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(value.note == nil ? Color.primary : ModuleTint.knowledge)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the original at this passage"))
    }

    /// "Range 12–16 · H · 3 Mar 2026 · Page 2".
    private static func valueDetails(_ value: KnowledgeValue) -> String {
        var parts: [String] = []
        if let range = value.range, !range.isEmpty { parts.append(String(localized: "Range \(range)")) }
        if let note = value.note, !note.isEmpty { parts.append(note) }
        if let day = value.date.flatMap({ Day($0) }) {
            parts.append(day.date.formatted(date: .abbreviated, time: .omitted))
        }
        if let page = value.page { parts.append(String(localized: "Page \(page)")) }
        return parts.joined(separator: " · ")
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
                        // Only an open page's text is made (and marked): not every page's on each redraw.
                        if expanded.contains(page.page) {
                            Text(marked(page.text, quote: page.page == target.page ? target.quote : nil))
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Page \(page.page)")
                            if detail.document.aiPages.contains(page.page) {
                                Label("Read by the assistant", systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                if document.status != .excluded, document.status != .missing {
                    Button("Read Again", systemImage: "arrow.clockwise") { reread(document, assistant: false) }
                        .disabled(state.isSaved || rereading)
                    if readsScans {
                        Button("Read Again with the Assistant", systemImage: "sparkles") { reread(document, assistant: true) }
                            .disabled(state.isSaved || rereading)
                    }
                }
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
                Label("More", systemImage: "ellipsis")
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

    /// Reads the file again on this device now and sends it (`assistant`: every page's image to the
    /// family's AI too). Without this device's folder or the file in it: the original's alert, which
    /// offers Settings → Knowledge.
    private func reread(_ document: KnowledgeDocumentSummary, assistant: Bool) {
        guard !rereading else { return }
        rereading = true
        rereadNote = nil
        Task {
            defer { rereading = false }
            do {
                switch try await family.knowledge.reread(path: document.path, assistant: assistant) {
                case .sent:
                    rereadNote = assistant ? String(localized: "Read again. The assistant reads its pages next.")
                        : String(localized: "Read again on this device.")
                    family.didChange(.knowledge)
                case .waiting:
                    rereadNote = String(localized: "Read again. It’s sent once there’s a connection.")
                case let .unreadable(reason):
                    rereadNote = reason.reason
                }
            } catch let error as KnowledgeOriginalError {
                opener.failure = error
            } catch {
                ErrorBanner.shared.show(error)
            }
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

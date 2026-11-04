import SwiftUI

/// The knowledge base: the family's documents (the files of its knowledge folder the server has
/// read), newest first, as cards with their date, whose they are, their tags and the start of
/// their summary; searched (`q`) and narrowed by folder, person and tag (a bar under the
/// navigation bar), the left-out ones on request. A card opens the document
/// (`KnowledgeDocumentView`). Editors only, not the demo (`FamilyContext.knowledgeAvailable`);
/// inside the shell's navigation stack (a sheet from the family page on iPhone).
struct KnowledgeView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        Group {
            if family.knowledgeAvailable {
                KnowledgeList(indexer: family.knowledge)
            } else {
                ContentUnavailableView("Not available", systemImage: "books.vertical")
            }
        }
        // Any size: an empty state alone would otherwise shrink the page (and its background)
        // to the message's size.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .ohanaBackground(ModuleTint.knowledge)
        .navigationTitle("Knowledge")
    }
}

/// What the knowledge page pushes: a document, optionally at a page of its text with a quote
/// marked in it.
struct KnowledgeDocumentTarget: Hashable {
    var id: String
    var page: Int?
    var quote: String?
}

/// A member of the family as the knowledge base shows them (whose a document is): an account or a
/// person without one, with their color and photo (GET /household).
struct KnowledgeMember: Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
    let photo: String?

    static func all(_ household: FamilyHousehold) -> [KnowledgeMember] {
        household.members.map { KnowledgeMember(id: $0.userId, name: $0.label, color: $0.color, photo: $0.photo) }
            + household.people.map { KnowledgeMember(id: $0.id, name: $0.name, color: $0.color, photo: $0.photo) }
    }

    /// The members of `api`'s family: the server's, or the copy on the device.
    static func load(_ api: FamilyAPI) async -> [KnowledgeMember]? {
        (try? await FamilySettingsModel.request(api).fetchOrSaved()).map(all)
    }
}

private struct KnowledgeList: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.scenePhase) private var scenePhase
    let indexer: KnowledgeIndexer

    /// Every document loaded for `query` (its pages after the first included).
    @State private var state: LoadState<KnowledgeDocumentsPage> = .idle
    /// The query `state` belongs to: another one starts from nothing.
    @State private var shownQuery: KnowledgeDocumentQuery?
    @State private var typed = ""
    @State private var query = KnowledgeDocumentQuery()
    @State private var status: KnowledgeStatusInfo?
    @State private var tags: [KnowledgeTagsResponse.Tag] = []
    @State private var members: [KnowledgeMember] = []
    /// The paths seen so far: the folder filter's subfolders come from them.
    @State private var seenPaths: Set<String> = []
    @State private var folder: KnowledgeFolder.State = .none
    @State private var pushed: KnowledgeDocumentTarget?

    private var documents: [KnowledgeDocumentSummary] { state.value?.documents ?? [] }

    /// The next page's; none for the copy on the device.
    private var cursor: String? { state.isSaved ? nil : state.value?.nextCursor }

    private var running: Bool {
        switch indexer.phase {
        case .scanning, .hashing, .uploading: true
        case .idle, .failed: false
        }
    }

    /// Something shown waits for the server's worker (its text, or its card where cards are made).
    private var waiting: Bool {
        documents.contains {
            $0.status == .pending || ($0.status == .ready && $0.cardStatus == .pending && status?.makesCards == true)
        }
    }

    private struct LoadKey: Hashable {
        var query: KnowledgeDocumentQuery
        var revision: Int
    }

    private struct PollKey: Hashable {
        var waiting: Bool
        var active: Bool
    }

    var body: some View {
        LoadStateView(state: state, retry: { await refresh(full: true) }) { _ in
            content
        }
        .searchable(text: $typed, prompt: Text("Search documents"))
        .safeAreaBar(edge: .top) {
            if state.value != nil, !documents.isEmpty || query.isFiltered {
                filterBar
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Knowledge") { moduleMenu })
        .task(id: typed) {
            // What's typed is asked for once typing pauses.
            if !typed.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, query.text != typed else { return }
            query.text = typed
        }
        .onChange(of: query) {
            // Another query: never the last one's documents under it.
            shownQuery = query
            state = .idle
        }
        .task(id: LoadKey(query: query, revision: family.revision(.knowledge))) {
            if shownQuery != query {
                shownQuery = query
                state = .idle
            }
            await refresh(full: true)
        }
        .task(id: PollKey(waiting: waiting, active: scenePhase == .active)) {
            // The worker reads what was just sent: looked at again now and then while it shows and
            // the app is in front.
            guard scenePhase == .active else { return }
            while waiting, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await refresh(full: false)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await refresh(full: true) } }
        }
        .onChange(of: indexer.phase) { _, phase in
            // A run (or its uploads) finished: the server has more.
            switch phase {
            case .idle, .failed: Task { await refresh(full: true) }
            case .scanning, .hashing, .uploading: break
            }
        }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .knowledge) else { return }
            if case let .knowledgeDocument(id, page, quote) = route {
                pushed = KnowledgeDocumentTarget(id: id, page: page, quote: quote)
            } else {
                pushed = nil
            }
        }
        .navigationDestination(for: KnowledgeDocumentTarget.self) {
            KnowledgeDocumentView(target: $0).assistantButton()
        }
        // `.id`: another route replaces the pushed page with a fresh one.
        .navigationDestination(item: $pushed) { KnowledgeDocumentView(target: $0).id($0).assistantButton() }
    }

    // MARK: Loading

    /// Loads the documents again (as many as are loaded); `full`: with the folder's state, the
    /// status, the tags and the members (not when polling).
    private func refresh(full: Bool) async {
        guard full else { return await loadDocuments() }
        async let side: Void = loadSide()
        await loadDocuments()
        await side
    }

    private func loadDocuments() async {
        let current = query
        let loaded = state.value
        let limit = KnowledgeDocumentsPage.refreshLimit(loaded: loaded?.documents.count ?? 0)
        // The first page without a search is kept on the device; a search, or more, isn't.
        let cached = current.trimmedText.isEmpty && limit == KnowledgeDocumentQuery.pageSize
        let get = family.api.knowledgeDocuments(current)
        switch state {
        case .idle, .loading, .failed:
            if cached, let copy = get.saved() {
                state = .saved(copy.value, date: copy.date, updating: true)
            } else {
                state = .loading
            }
        case let .saved(value, date, _):
            state = .saved(value, date: date, updating: true)
        case .loaded:
            break
        }
        do {
            let fresh: KnowledgeDocumentsPage = cached
                ? try await get.fetch()
                : try await family.api.get("/knowledge/documents", query: current.items(limit: limit))
            // An answer for an older query (polling, becoming active, the indexer) is dropped.
            guard current == query else { return }
            let merged = loaded.map { $0.refreshed(with: fresh, limit: limit) } ?? fresh
            state = .loaded(merged)
            seenPaths.formUnion(merged.documents.map(\.path))
        } catch {
            guard current == query, !Task.isCancelled, !(error is CancellationError) else { return }
            state = state.failing(error)
        }
    }

    /// The device's folder, the server's status (folder, cards), the tags and the members.
    private func loadSide() async {
        folder = indexer.folder.state()
        if let info = try? await family.api.knowledgeStatus().fetchOrSaved() { status = info }
        if let answer = try? await family.api.knowledgeTags().fetchOrSaved() { tags = answer.tags }
        if let found = await KnowledgeMember.load(family.api) { members = found }
    }

    private func loadMore(after next: String) async {
        let current = query
        do {
            let page = try await family.api.knowledgeDocuments(current, cursor: next)
            guard current == query, case let .loaded(value) = state, value.nextCursor == next else { return }
            state = .loaded(value.appending(page))
            seenPaths.formUnion(page.documents.map(\.path))
        } catch {
            guard current == query, !Task.isCancelled, case let .loaded(value) = state, value.nextCursor == next else { return }
            state = .loaded(KnowledgeDocumentsPage(documents: value.documents, nextCursor: nil))
            ErrorBanner.shared.showUnlessUnreachable(error)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if documents.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(documents) { document in
                        NavigationLink(value: KnowledgeDocumentTarget(id: document.id)) {
                            KnowledgeDocumentCard(document: document, members: members)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let cursor {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .task(id: cursor) { await loadMore(after: cursor) }
                }
            }
            .contentMargins(16, for: .scrollContent)
            .refreshable { await refresh(full: true) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if query.isFiltered {
            if !query.trimmedText.isEmpty {
                ContentUnavailableView.search(text: query.trimmedText)
            } else {
                ContentUnavailableView("No documents", systemImage: "doc.text.magnifyingglass")
            }
        } else if folder.url == nil, status?.folder == nil {
            ContentUnavailableView {
                Label("No knowledge folder", systemImage: "books.vertical")
            } description: {
                Text("Choose the family’s folder of letters and papers on this device: Ohana reads it and keeps its text, never the files.")
            } actions: {
                Button("Choose Folder…") { family.open(.settings(.knowledge)) }
                    .buttonStyle(.glassProminent)
            }
        } else {
            ContentUnavailableView {
                Label("Nothing read yet", systemImage: "tray")
            } actions: {
                if folder.url != nil {
                    Button("Read Now") { family.indexKnowledge(force: true) }
                        .buttonStyle(.glassProminent)
                        .disabled(running)
                }
            }
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                folderMenu
                if !members.isEmpty { personMenu }
                ForEach(tags, id: \.tag) { tag in
                    let selected = query.tag == tag.tag
                    Button {
                        query.tag = selected ? nil : tag.tag
                    } label: {
                        Label(tag.tag, systemImage: "tag")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .foregroundStyle(selected ? ModuleTint.knowledge : .primary)
                            .chip(tint: selected ? ModuleTint.knowledge : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var folderMenu: some View {
        Menu {
            Button("All Folders", systemImage: query.folder == nil ? "checkmark" : "folder") { query.folder = nil }
            if let current = query.folder {
                if let parent = KnowledgePath.parent(current) {
                    Button(KnowledgePath.folderName(parent), systemImage: "arrow.turn.left.up") { query.folder = parent }
                }
                Section(KnowledgePath.folderName(current)) {
                    ForEach(KnowledgePath.subfolders(of: seenPaths, under: current), id: \.self) { sub in
                        Button(KnowledgePath.folderName(sub), systemImage: "folder") { query.folder = sub }
                    }
                }
            } else {
                Section {
                    ForEach(KnowledgePath.subfolders(of: seenPaths, under: nil), id: \.self) { sub in
                        Button(KnowledgePath.folderName(sub), systemImage: "folder") { query.folder = sub }
                    }
                }
            }
        } label: {
            filterChip(query.folder.map { Text(verbatim: KnowledgePath.folderName($0)) } ?? Text("All Folders"),
                       systemImage: "folder", selected: query.folder != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var personMenu: some View {
        let selected = members.first { $0.id == query.person }
        return Menu {
            Button("Everyone", systemImage: query.person == nil ? "checkmark" : "person.2") { query.person = nil }
            Section {
                ForEach(members) { member in
                    Button(member.name, systemImage: member.id == query.person ? "checkmark" : "person") {
                        query.person = member.id
                    }
                }
            }
        } label: {
            filterChip(selected.map { Text(verbatim: $0.name) } ?? Text("Everyone"),
                       systemImage: "person", selected: selected != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func filterChip(_ title: Text, systemImage: String, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            title
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.subheadline)
        .foregroundStyle(selected ? ModuleTint.knowledge : .primary)
        .chip(tint: selected ? ModuleTint.knowledge : nil)
    }

    // MARK: Toolbar and menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                moduleMenu
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    @ViewBuilder
    private var moduleMenu: some View {
        Toggle("Show Left Out", systemImage: "eye.slash", isOn: $query.excluded)
        Section {
            if folder.url != nil {
                Button("Read Now", systemImage: "arrow.clockwise") { family.indexKnowledge(force: true) }
                    .disabled(running)
            }
            Button("Knowledge Settings", systemImage: "gearshape") { family.open(.settings(.knowledge)) }
        }
    }
}

/// A document as a card: its icon, name, date and folder, whose it is, the start of its summary,
/// its tags and, while it isn't simply there, its status.
struct KnowledgeDocumentCard: View {
    let document: KnowledgeDocumentSummary
    let members: [KnowledgeMember]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                TintedIcon(systemImage: document.kind.systemImage, tint: ModuleTint.knowledge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: document.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(verbatim: KnowledgeWording.subtitle(document))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let person = document.person {
                    KnowledgePersonIcon(person: person, members: members, size: 24)
                }
            }
            if let summary = document.summary, !summary.isEmpty {
                // The assistant's summary: marked by a small sparkle.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(ModuleTint.knowledge)
                        .accessibilityLabel(Text("By the assistant"))
                    Text(verbatim: summary)
                        .lineLimit(3)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if document.status != .ready || !document.tags.isEmpty {
                RecipeFlowLayout(spacing: 6) {
                    KnowledgeStatusBadge(status: document.status)
                    ForEach(document.tags, id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(.caption)
                            .chip()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .contentShape(.rect)
    }
}

/// Whose a document is: their avatar (the family's member by id, else the name the server sent).
struct KnowledgePersonIcon: View {
    let person: KnowledgePerson
    let members: [KnowledgeMember]
    var size: CGFloat = 18

    var body: some View {
        let member = members.first { $0.id == person.id }
        MemberIcon(name: member?.name ?? person.name, color: member?.color, photo: member?.photo, size: size)
    }
}

/// A document's status where it isn't simply there: waiting, failed, missing, left out.
struct KnowledgeStatusBadge: View {
    let status: KnowledgeDocumentStatus

    var body: some View {
        switch status {
        case .ready:
            EmptyView()
        case .pending:
            badge("Waiting", systemImage: "clock", tint: .secondary)
        case .failed:
            badge("Failed", systemImage: "exclamationmark.triangle", tint: .orange)
        case .missing:
            badge("Missing", systemImage: "questionmark.folder", tint: .orange)
        case .excluded:
            badge("Left Out", systemImage: "eye.slash", tint: .secondary)
        }
    }

    private func badge(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .chip(tint: tint)
    }
}

/// How the knowledge base words a document's details.
enum KnowledgeWording {
    /// The document's own date (the card's), else its file's.
    static func date(_ document: KnowledgeDocumentSummary) -> Date {
        document.docDate.flatMap { Day($0) }?.date ?? document.modified
    }

    static func dateText(_ document: KnowledgeDocumentSummary) -> String {
        date(document).formatted(date: .abbreviated, time: .omitted)
    }

    /// "12 Mar 2026 · Insurance › Car".
    static func subtitle(_ document: KnowledgeDocumentSummary) -> String {
        let folders = document.folderParts
        return ([dateText(document)] + (folders.isEmpty ? [] : [folders.joined(separator: " › ")])).joined(separator: " · ")
    }
}

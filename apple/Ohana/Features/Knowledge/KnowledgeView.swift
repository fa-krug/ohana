import SwiftUI

/// The knowledge base: the family's documents (the files of its knowledge folder the server has
/// read), newest first, as a list in a readable column (`columnWidth`): each row with its date,
/// whose it is, the start of its summary and its tags; narrowed by folder and person (menus in a
/// bar under the navigation bar, as wide as the list) and tag (a list beside it on a wide page,
/// `tagColumnFrom`, else a menu in the bar), the left-out ones on request. (Searching them is
/// the search page's: its `knowledge` hits.) A row opens the document
/// (`KnowledgeDocumentView`). Editors only, not the demo (`FamilyContext.knowledgeAvailable`);
/// inside the shell's navigation stack.
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
    /// False while the iPhone's family page covers the page (`shellPageVisible`).
    @Environment(\.shellPageVisible) private var pageVisible
    let indexer: KnowledgeIndexer

    /// Every document loaded for `query` (its pages after the first included).
    @State private var state: LoadState<KnowledgeDocumentsPage> = .idle
    /// The query `state` belongs to: another one starts from nothing.
    @State private var shownQuery: KnowledgeDocumentQuery?
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

    /// Something shown waits for the server's worker (its text, or its first card where cards are
    /// made; one written again keeps showing its earlier card, so it's no reason to poll).
    private var waiting: Bool {
        documents.contains {
            $0.status == .pending
                || ($0.status == .ready && $0.cardStatus == .pending && $0.summary == nil && status?.makesCards == true)
        }
    }

    private struct LoadKey: Hashable {
        var query: KnowledgeDocumentQuery
        var revision: Int
    }

    private struct PollKey: Hashable {
        var waiting: Bool
        var active: Bool
        var visible: Bool
    }

    /// The page is wide enough for the tags in a column beside the list (`tagColumnFrom`).
    @State private var wide = false

    /// The filters show once there is something to narrow (or a filter to take back).
    private var showsFilters: Bool {
        state.value != nil && (!documents.isEmpty || query.isFiltered)
    }

    private var hasTags: Bool { !tags.isEmpty || query.tag != nil }

    /// On a wide page the tags are a list beside the documents, else a menu chip in the bar.
    private var showsTagColumn: Bool { wide && showsFilters && hasTags }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            if showsTagColumn { tagColumn }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.tagColumnFrom } action: { wide = $0 }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Knowledge") { moduleMenu })
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
        .task(id: PollKey(waiting: waiting, active: scenePhase == .active, visible: pageVisible)) {
            // The worker reads what was just sent: looked at again now and then while it shows and
            // the app is in front.
            guard scenePhase == .active, pageVisible else { return }
            while waiting, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await refresh(full: false)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await refresh(full: true) } }
        }
        .onChange(of: pageVisible) {
            // Back on screen (iPhone): what changed meanwhile.
            if pageVisible { Task { await refresh(full: true) } }
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
            KnowledgeDocumentView(target: $0).shellPageItems()
        }
        // `.id`: another route replaces the pushed page with a fresh one.
        .navigationDestination(item: $pushed) { KnowledgeDocumentView(target: $0).id($0).shellPageItems() }
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
        // The first page is kept on the device; more isn't.
        let cached = limit == KnowledgeDocumentQuery.pageSize
        let get = family.api.knowledgeDocuments(current)
        switch state {
        case .idle, .loading, .failed:
            // The copy is read and decoded off the main thread; shown only while it's still this
            // query's turn and nothing came in meanwhile.
            let copy = cached ? await get.savedOffMain() : nil
            guard current == query else { return }
            switch state {
            case .idle, .loading, .failed:
                if let copy {
                    state = .saved(copy.value, date: copy.date, updating: true)
                } else if !state.isLoading {
                    state = .loading
                }
            case .loaded, .saved:
                break
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
            // Polling (every 15 s while something waits): the same list isn't assigned again.
            if case let .loaded(shown) = state, shown == merged { return }
            state = .loaded(merged)
            let paths = merged.documents.map(\.path)
            if !seenPaths.isSuperset(of: paths) { seenPaths.formUnion(paths) }
        } catch {
            guard current == query, !Task.isCancelled, !(error is CancellationError) else { return }
            state = state.failing(error)
        }
    }

    /// The device's folder, the server's status (folder, cards), the tags and the members.
    private func loadSide() async {
        folder = indexer.folder.state()
        async let info = loadStatus()
        async let answer = loadTags()
        async let found = loadMembers()
        if let info = await info, info != status { status = info }
        if let answer = await answer, answer.tags != tags { tags = answer.tags }
        if let found = await found, found != members { members = found }
    }

    private func loadStatus() async -> KnowledgeStatusInfo? {
        try? await family.api.knowledgeStatus().fetchOrSaved()
    }

    private func loadTags() async -> KnowledgeTagsResponse? {
        try? await family.api.knowledgeTags().fetchOrSaved()
    }

    private func loadMembers() async -> [KnowledgeMember]? {
        await KnowledgeMember.load(family.api)
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

    /// The documents with the folder / person (/ tag) chips above them.
    private var listColumn: some View {
        LoadStateView(state: state, retry: { await refresh(full: true) }) { _ in
            content
        }
        .safeAreaBar(edge: .top) {
            if showsFilters { filterBar }
        }
    }

    @ViewBuilder
    private var content: some View {
        if documents.isEmpty {
            emptyState
        } else {
            List {
                ForEach(documents) { document in
                    documentLink(document)
                }
                if let cursor {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .task(id: cursor) { await loadMore(after: cursor) }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .readableWidth(Self.columnWidth)
            .refreshable { await refresh(full: true) }
        }
    }

    /// A row opening its document. On the Mac a `NavigationLink` in a `List` only follows the
    /// list's selection, and this one has none: a click did nothing. A button pushes it there.
    @ViewBuilder
    private func documentLink(_ document: KnowledgeDocumentSummary) -> some View {
        let target = KnowledgeDocumentTarget(id: document.id)
        #if os(macOS)
        Button { pushed = target } label: {
            KnowledgeDocumentRow(document: document, members: members)
        }
        .buttonStyle(.plain)
        #else
        NavigationLink(value: target) {
            KnowledgeDocumentRow(document: document, members: members)
        }
        #endif
    }

    @ViewBuilder
    private var emptyState: some View {
        if query.isFiltered {
            ContentUnavailableView("No documents", systemImage: "doc.text.magnifyingglass")
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

    /// The list's column (and its filter bar's) on a wide window.
    static let columnWidth: CGFloat = 680
    /// The tags' column beside the list.
    static let tagColumnWidth: CGFloat = 220
    /// From this page width on the tags are a column beside the list: the list keeps its column
    /// and a margin on each side.
    static let tagColumnFrom: CGFloat = columnWidth + tagColumnWidth + 48

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                folderMenu
                if !members.isEmpty { personMenu }
                if hasTags, !showsTagColumn { tagMenu }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        // Never a scroll bar under the chips (the Mac's "always show" setting too).
        .scrollIndicators(.never)
        // As wide as the list below, not the window.
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity)
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

    private var tagMenu: some View {
        Menu {
            Button("All Tags", systemImage: query.tag == nil ? "checkmark" : "tag") { query.tag = nil }
            Section {
                ForEach(tags, id: \.tag) { tag in
                    Button(tag.tag, systemImage: tag.tag == query.tag ? "checkmark" : "tag") { query.tag = tag.tag }
                }
            }
        } label: {
            filterChip(query.tag.map { Text(verbatim: $0) } ?? Text("Tags"), systemImage: "tag",
                       selected: query.tag != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// The tags as a list of filters beside the documents (wide pages): All Tags, then each tag
    /// with its number of documents; a tap picks one, a tap on the picked one takes it back.
    private var tagColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tags")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                tagRow(nil, title: Text("All Tags"), count: nil)
                ForEach(tags, id: \.tag) { tag in
                    tagRow(tag.tag, title: Text(verbatim: tag.tag), count: tag.count)
                }
                // A tag picked earlier that's no longer listed: still there to take back.
                if let current = query.tag, !tags.contains(where: { $0.tag == current }) {
                    tagRow(current, title: Text(verbatim: current), count: nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: Self.tagColumnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tagRow(_ tag: String?, title: Text, count: Int?) -> some View {
        let selected = query.tag == tag
        return Button {
            query.tag = selected ? nil : tag
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected && tag != nil ? "tag.fill" : "tag")
                    .frame(width: 18)
                title.lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(selected ? ModuleTint.knowledge : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ModuleTint.knowledge.opacity(0.18))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        // Two plain buttons rather than a More menu: there's nothing else to put in one.
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $query.excluded) {
                Label("Show Left Out", systemImage: "eye.slash")
            }
            .help("Show Left Out")
            Button("Knowledge Settings", systemImage: "gearshape") { family.open(.settings(.knowledge)) }
                .help("Knowledge Settings")
        }
    }

    @ViewBuilder
    private var moduleMenu: some View {
        Toggle("Show Left Out", systemImage: "eye.slash", isOn: $query.excluded)
        Section {
            // Reading the folder again: Settings → Knowledge (and the empty list) have Read Now.
            Button("Knowledge Settings", systemImage: "gearshape") { family.open(.settings(.knowledge)) }
        }
    }
}

/// A document as a row of the list: its icon, name, whose it is and date, its folder, the start of
/// its summary, its tags and, while it isn't simply there, its status.
struct KnowledgeDocumentRow: View {
    let document: KnowledgeDocumentSummary
    let members: [KnowledgeMember]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TintedIcon(systemImage: document.kind.systemImage, tint: ModuleTint.knowledge, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                // Name, person and date in one row where the whole name fits (wide windows);
                // else the name on its own (up to two lines) and the others under it, so a
                // phone shows more of it than "2026…i.pdf".
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        name.lineLimit(1)
                        Spacer(minLength: 0)
                        details
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        name
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            details
                        }
                    }
                }
                if let folder = KnowledgeWording.folder(document) {
                    Text(verbatim: folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let summary = document.summary, !summary.isEmpty {
                    // The assistant's summary: marked by a small sparkle.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(ModuleTint.knowledge)
                            .accessibilityLabel(Text("By the assistant"))
                        Text(verbatim: summary)
                            .lineLimit(2)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .padding(.top, 1)
                }
                if document.status != .ready || !document.tags.isEmpty {
                    RecipeFlowLayout(spacing: 4) {
                        KnowledgeStatusBadge(status: document.status)
                        ForEach(document.tags, id: \.self) { tag in
                            Text(verbatim: tag)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: .capsule)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var name: some View {
        Text(verbatim: document.name)
            .font(.body.weight(.semibold))
    }

    /// Whose it is and its date.
    @ViewBuilder
    private var details: some View {
        if let person = document.person {
            KnowledgePersonIcon(person: person, members: members, size: 18)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        Text(verbatim: KnowledgeWording.dateText(document))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .layoutPriority(1)
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

    /// The size of the tags beside it. Icon and text by hand, never a `Label`: in the list's flow
    /// layout iOS drew that as a tall capsule with the icon only.
    private func badge(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.18), in: .capsule)
        .fixedSize()
        .accessibilityElement(children: .combine)
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

    /// The folders it's in, "Insurance › Car"; nil at the folder's top.
    static func folder(_ document: KnowledgeDocumentSummary) -> String? {
        let folders = document.folderParts
        return folders.isEmpty ? nil : folders.joined(separator: " › ")
    }
}

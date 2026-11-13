import SwiftUI

/// The family's recipes (web: meals/recipes): Favourites or Want to try, search, and one Filter
/// menu with the sort, the tag filter and (editors) the tags themselves (`manageTags`), a page at
/// a time (`RecipeListModel.pageSize`) as an adaptive grid of cards. The + adds a recipe (on iPad
/// and Mac its menu generates or imports one, on iPhone a menu of the three); File ▸ New Recipe
/// (⌘N) adds one. Pages shared to Ohana show as placeholders on top of "Want to try" while the server imports
/// them (`RecipeImports`).
struct RecipeListView: View {
    /// Opens the tags page (`RecipeTagsView`).
    var manageTags: () -> Void = {}

    @Environment(FamilyContext.self) private var family
    @Environment(\.undoManager) private var undoManager
    @Environment(\.mealsOnScreen) private var onScreen
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 250
    @AppStorage(RecipeListModel.listKey) private var list = RecipeListModel.defaultList
    @AppStorage(RecipeListModel.sortKey) private var sort = RecipeListModel.defaultSort
    @State private var query = ""
    @State private var tagFilter: Set<String> = []
    @State private var model = RecipeListModel()
    @State private var imports = RecipeImports()
    @State private var tags: [RecipeTag] = []
    @State private var ai = MealsAIStatus.none
    @State private var showFilter = false
    @State private var creating = false
    @State private var generating = false
    @State private var importing = false
    @State private var deletes = MealsPendingDeletes.shared
    @State private var confirmDelete: RecipeSummary?
    @State private var cooking: MealsRecipeRef?

    private var key: RecipeListModel.Query {
        .init(list: list, query: query.trimmingCharacters(in: .whitespaces), sort: sort, tags: tagFilter)
    }

    /// The imports show on "Want to try" without a search or filter.
    private var importCards: [RecipeImportJob] {
        list == .toTry && key.query.isEmpty && tagFilter.isEmpty ? imports.items : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                if list == .known, imports.pendingCount > 0 {
                    RecipeImportsBanner(count: imports.pendingCount) { list = .toTry }
                }
                content
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .reloadsWhenReconnected(stale: model.saved?.updating == false) { await model.reload(family.api, key) }
        .pageSearchable(text: $query, prompt: Text("Search recipes"))
        .refreshable { await model.reload(family.api, key) }
        .task(id: RecipeListModel.Load(query: key, revision: family.revision(.recipes))) {
            // Typing waits a moment before asking the server.
            if model.loadedQuery != nil, model.loadedQuery?.query != key.query {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            await model.reload(family.api, key)
        }
        .task(id: RecipeImports.Load(familyID: family.api.familyID, revision: family.revision(.recipes),
                                     active: onScreen && scenePhase == .active, restarts: imports.restarts)) {
            // Only while the list is on screen and the app active; it starts over on coming back.
            guard onScreen, scenePhase == .active else { return }
            await imports.poll(family)
        }
        // Two tasks, so the two requests run side by side; each shows its copy on the device
        // first (the toolbar's Filter and AI buttons don't wait for the server).
        .task(id: family.revision(.recipes)) {
            let get = RecipeTagsView.request(family.api)
            if tags.isEmpty, let copy = await get.savedOffMain(), !Task.isCancelled { tags = copy.value.tags }
            tags = (try? await get.fetchOrSaved().tags) ?? tags
        }
        .task(id: family.revision(.recipes)) {
            let get = RecipeListModel.statusRequest(family.api)
            if ai == .none, let copy = await get.savedOffMain(), !Task.isCancelled { ai = copy.value }
            ai = (try? await get.fetchOrSaved()) ?? ai
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.newItem, onScreen && family.canEdit
                           ? NewItemAction(title: "New Recipe") { creating = true } : nil)
        .cookPresentation($cooking)
        .sheet(isPresented: $showFilter) {
            RecipeFilterSheet(tags: tags, selection: $tagFilter)
        }
        .sheet(isPresented: $creating) {
            RecipeEditorSheet(mode: .create(list)) { id in
                family.open(.recipe(id: id))
            }
        }
        .sheet(isPresented: $generating) {
            RecipeGenerateView { list = .toTry }
        }
        .sheet(isPresented: $importing) {
            // The server saves it to "Want to try".
            RecipeImportView { id in
                list = .toTry
                family.open(.recipe(id: id))
            }
        }
        .confirmationDialog("Delete recipe?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { recipe in
            Button("Delete", role: .destructive) {
                withAnimation {
                    deletes.schedule(recipe.id, kind: .recipe, title: recipe.title, family: family,
                                     undoManager: undoManager)
                }
            }
        } message: { _ in
            Text("Delete this recipe? You’ll have a few seconds to undo.")
        }
    }

    // MARK: Pieces

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("List", selection: $list) {
                ForEach(RecipeListType.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var content: some View {
        let visible = model.items.filter { !deletes.isHidden($0.id) }
        if let error = model.error, model.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await model.reload(family.api, key) } }
                    .buttonStyle(.glassProminent)
            }
            .padding(.top, 40)
        } else if model.loadedQuery == nil {
            PageLoadingView().padding(.top, 80)
        } else if visible.isEmpty && importCards.isEmpty {
            if !key.query.isEmpty {
                ContentUnavailableView.search(text: key.query).padding(.top, 40)
            } else if !tagFilter.isEmpty {
                ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No recipe has these tags."))
                    .padding(.top, 40)
            } else if ai.showsWelcome(canEdit: family.canEdit) {
                MealsWelcomeView(ai: ai, addRecipe: { creating = true }, generate: { generating = true },
                                 importFromWeb: { importing = true })
                    .padding(.top, 24)
            } else {
                ContentUnavailableView {
                    Label("No recipes yet", systemImage: "book")
                } description: {
                    Text("Start building your collection")
                } actions: {
                    if family.canEdit {
                        Button("Add your first recipe", systemImage: "plus") { creating = true }
                            .buttonStyle(.glassProminent)
                        if ai.generate {
                            Button("Generate with AI", systemImage: "sparkles") { generating = true }
                                .buttonStyle(.bordered)
                            Button("Import from Web", systemImage: "globe") { importing = true }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.top, 40)
            }
        } else {
            // Cards grow with the text size, up to one column on a phone.
            let width = min(cardWidth, 320)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.7), spacing: 16)], spacing: 16) {
                ForEach(importCards) { job in
                    RecipeImportCard(job: job, canEdit: family.canEdit,
                                     retry: { Task { await imports.retry(job, family) } },
                                     remove: { Task { await imports.remove(job, family) } })
                }
                ForEach(visible) { recipe in
                    NavigationLink {
                        MealsRecipeDetailView(recipeID: recipe.id).shellPageItems()
                    } label: {
                        RecipeCard(recipe: recipe)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: recipe) }
                    .onAppear {
                        if recipe.id == model.items.last?.id { Task { await model.loadMore(family.api) } }
                    }
                }
            }
            if model.hasMore {
                // Not `onAppear`: in the (non-lazy) stack it fired as soon as the first page
                // showed, asking for the next one before anyone scrolled. The last card's
                // `onAppear` (the lazy grid's) asks ahead; this catches a page that ends on screen.
                ProgressView().frame(maxWidth: .infinity).padding()
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        if visible { Task { await model.loadMore(family.api) } }
                    }
            }
            if !visible.isEmpty {
                Text("\(model.totalCount) recipes")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func menu(for recipe: RecipeSummary) -> some View {
        Button {
            cooking = MealsRecipeRef(recipeID: recipe.id)
        } label: {
            Label("Let’s cook!", systemImage: "frying.pan")
        }
        // Changes wait for the server's latest list, not the copy on the device.
        if family.canEdit, model.saved == nil {
            Button {
                perform {
                    let _: RecipeMoveResponse = try await family.api.send(.post, "/meals/recipes/\(recipe.id)/move")
                    family.didChange(.recipes, .meals)
                }
            } label: {
                if list == .known {
                    Label("Move to Want to try", systemImage: "arrow.right.arrow.left")
                } else {
                    Label("Move to Favourites", systemImage: "arrow.right.arrow.left")
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = recipe }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(RecipeSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                if !tags.isEmpty || !tagFilter.isEmpty {
                    Section {
                        if !tags.isEmpty {
                            Button("Tags", systemImage: "tag") { showFilter = true }
                        }
                        if !tagFilter.isEmpty {
                            Button("Clear Filters", systemImage: "xmark") { tagFilter = [] }
                        }
                    }
                }
                if family.canEdit {
                    Section {
                        Button("Manage Tags", systemImage: "square.and.pencil", action: manageTags)
                    }
                }
            } label: {
                Label("Filter", systemImage: tagFilter.isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        if family.canEdit {
            #if os(iOS)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            #endif
            ToolbarItem(placement: .primaryAction) {
                if !ai.generate {
                    Button {
                        creating = true
                    } label: {
                        Label("Add Recipe", systemImage: "plus")
                    }
                } else if compact {
                    // On the iPhone a tap opens the menu: there a long press is all that would show
                    // the other two ways.
                    Menu {
                        Button("Add Recipe", systemImage: "plus") { creating = true }
                        Section {
                            Button("Generate with AI", systemImage: "sparkles") { generating = true }
                            Button("Import from Web", systemImage: "globe") { importing = true }
                        }
                    } label: {
                        Label("Add Recipe", systemImage: "plus")
                    }
                } else {
                    Menu {
                        Button("Generate with AI", systemImage: "sparkles") { generating = true }
                        Button("Import from Web", systemImage: "globe") { importing = true }
                    } label: {
                        Label("Add Recipe", systemImage: "plus")
                    } primaryAction: {
                        creating = true
                    }
                }
            }
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
}

/// One recipe in the grid: its photo, title, times and tags on a card.
struct RecipeCard: View {
    let recipe: RecipeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 150 pt high, at most ~430 pt wide: 800 px is plenty, the full 1024 px photo isn't
            // needed in memory for every card.
            RemoteImage(path: recipe.imagePath, maxPixelSize: 800) { RecipePhotoPlaceholder() }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                RecipeMetaRow(prep: recipe.prepTimeMinutes, cook: recipe.cookTimeMinutes, servings: recipe.defaultServings)
                if !recipe.tags.isEmpty {
                    RecipeFlowLayout(spacing: 4) {
                        ForEach(recipe.tags.prefix(3)) { RecipeTagChip(tag: $0) }
                        if recipe.tags.count > 3 {
                            Text(verbatim: "+\(recipe.tags.count - 3)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentCard(cornerRadius: 22, padding: 0)
        .clipShape(.rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityElement(children: .combine)
    }
}

/// The tag filter (the web's filter dialog): recipes must have one of the picked tags.
struct RecipeFilterSheet: View {
    let tags: [RecipeTag]
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                RecipeTagPicker(tags: tags, selection: $selection)
                    .padding()
            }
            .navigationTitle("Filter")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear filters", role: .destructive) { selection = [] }
                        .disabled(selection.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        .errorBanner()
        .presentationDetents([.medium, .large])
        .recipeSheetFrame(minWidth: 420, minHeight: 420)
    }
}

/// The list's data: the pages loaded so far for one query.
@Observable
final class RecipeListModel {
    struct Query: Hashable {
        var list: RecipeListType
        var query: String
        var sort: RecipeSort
        var tags: Set<String>
    }

    struct Load: Hashable {
        var query: Query
        var revision: Int
    }

    /// Rows per request. A wide window (Mac, iPad) shows 20 cards on one screen, so it asked
    /// for page after page at once; more rows per request make fewer round trips.
    static var pageSize: Int {
        #if os(macOS)
        60
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? 60 : 30
        #endif
    }

    /// Where the page keeps its list and sort (`@AppStorage`), and what they start as.
    static let listKey = "meals.recipes.list"
    static let sortKey = "meals.recipes.sort"
    static let defaultList = RecipeListType.known
    static let defaultSort = RecipeSort.nameAsc

    /// What the page opens on: the list and sort chosen last, no search, no tags (the prefetch
    /// loads its first page).
    static var opening: Query {
        let defaults = UserDefaults.standard
        return Query(list: defaults.string(forKey: listKey).flatMap(RecipeListType.init(rawValue:)) ?? defaultList,
                     query: "",
                     sort: defaults.string(forKey: sortKey).flatMap(RecipeSort.init(rawValue:)) ?? defaultSort,
                     tags: [])
    }

    /// Whether the AI buttons show (the prefetch asks the same).
    static func statusRequest(_ api: FamilyAPI) -> CachedGet<MealsAIStatus> {
        api.cached("/meals/status")
    }

    private(set) var items: [RecipeSummary] = []
    private(set) var totalCount = 0
    private(set) var loadedQuery: Query?
    private(set) var error: String?
    /// While the items are the copy on the device: from when, and whether the server is being
    /// asked (`LoadState.saved`).
    private(set) var saved: (date: Date, updating: Bool)?
    private var loadingMore = false
    /// Counts the times `items` were replaced, so a copy read off the main thread doesn't
    /// overwrite an answer that arrived meanwhile.
    private var generation = 0

    var hasMore: Bool { items.count < totalCount }

    /// The first page of a query, kept on the device; not for searches (a copy per text typed).
    static func firstPage(_ api: FamilyAPI, _ q: Query, limit: Int) -> CachedGet<RecipeListPage> {
        let path = api.path("/meals/recipes")
        // Filed without the page's size: a reload keeping more rows replaces the same copy.
        let key = parameters(q, offset: 0).filter { $0.key != "offset" && $0.key != "limit" }
        return api.client.cached(path, query: parameters(q, offset: 0, limit: limit),
                                 key: api.client.url(path, query: key).absoluteString)
    }

    static func parameters(_ q: Query, offset: Int, limit: Int = pageSize) -> [String: String?] {
        [
            "list": q.list.rawValue,
            "q": q.query.isEmpty ? nil : q.query,
            "sort": q.sort.rawValue,
            "locale": RecipeLocale.code,
            "tags": q.tags.isEmpty ? nil : q.tags.sorted().joined(separator: ","),
            "offset": String(offset),
            "limit": String(limit),
        ]
    }

    /// The first page again (keeping as many rows as were loaded, so a reload doesn't jump).
    /// Another query, or nothing loaded yet, shows its copy on the device meanwhile.
    func reload(_ api: FamilyAPI, _ q: Query) async {
        let limit = q == loadedQuery ? min(100, max(Self.pageSize, items.count)) : Self.pageSize
        let get = Self.firstPage(api, q, limit: limit)
        if let shown = saved, loadedQuery == q {
            saved = (shown.date, true)
        } else if loadedQuery != q || items.isEmpty, q.query.isEmpty {
            // The copy is read and decoded off the main thread; meanwhile another query may have
            // started (this task cancelled) or an answer arrived.
            let start = generation
            if let copy = await get.savedOffMain(), !Task.isCancelled, generation == start {
                generation += 1
                items = copy.value.items
                totalCount = copy.value.totalCount
                loadedQuery = q
                error = nil
                saved = (copy.date, true)
            }
        }
        do {
            let page: RecipeListPage = if q.query.isEmpty {
                try await get.fetch()
            } else {
                try await api.get("/meals/recipes", query: get.query)
            }
            // Another query took over while this one was decoded: its answer would flash.
            try Task.checkCancellation()
            generation += 1
            items = page.items
            totalCount = page.totalCount
            loadedQuery = q
            error = nil
            saved = nil
        } catch is CancellationError {
            if let shown = saved, loadedQuery == q { saved = (shown.date, false) }
        } catch {
            if let shown = saved, loadedQuery == q, APIError.isTemporary(error) {
                // The copy stays: silently, unless the server answered with an error.
                saved = (shown.date, false)
                ErrorBanner.shared.showUnlessUnreachable(error)
            } else if items.isEmpty || loadedQuery != q || saved != nil {
                saved = nil
                self.error = error.localizedDescription
                generation += 1
                items = []
                loadedQuery = q
            } else {
                ErrorBanner.shared.show(error)
            }
        }
    }

    func loadMore(_ api: FamilyAPI) async {
        guard let q = loadedQuery, hasMore, !loadingMore, saved == nil else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page: RecipeListPage = try await api.get("/meals/recipes", query: Self.parameters(q, offset: items.count))
            guard q == loadedQuery else { return }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            totalCount = page.totalCount
        } catch {
            ErrorBanner.shared.show(error)
        }
    }
}

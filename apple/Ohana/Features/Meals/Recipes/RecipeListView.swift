import SwiftUI

/// The family's recipes (web: meals/recipes): Favourites or Want to try, search, tag filter and
/// sort, a page of 20 at a time as an adaptive grid of cards. File ▸ New Recipe (⌘N) adds one.
struct RecipeListView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.undoManager) private var undoManager
    @Environment(\.mealsOnScreen) private var onScreen
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 250
    @AppStorage(RecipeListModel.listKey) private var list = RecipeListModel.defaultList
    @AppStorage(RecipeListModel.sortKey) private var sort = RecipeListModel.defaultSort
    @State private var query = ""
    @State private var tagFilter: Set<String> = []
    @State private var model = RecipeListModel()
    @State private var tags: [RecipeTag] = []
    @State private var ai = MealsAIStatus.none
    @State private var showFilter = false
    @State private var creating = false
    @State private var generating = false
    @State private var deletes = MealsPendingDeletes.shared
    @State private var confirmDelete: RecipeSummary?
    @State private var cooking: MealsRecipeRef?

    private var key: RecipeListModel.Query {
        .init(list: list, query: query.trimmingCharacters(in: .whitespaces), sort: sort, tags: tagFilter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                content
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .topTrailing) {
            if let saved = model.saved {
                SavedCopyBadge(date: saved.date, updating: saved.updating) { await model.reload(family.api, key) }
            }
        }
        .searchable(text: $query, prompt: Text("Search recipes"))
        .refreshable { await model.reload(family.api, key) }
        .task(id: RecipeListModel.Load(query: key, revision: family.revision(.recipes))) {
            // Typing waits a moment before asking the server.
            if model.loadedQuery != nil, model.loadedQuery?.query != key.query {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            await model.reload(family.api, key)
        }
        .task(id: family.revision(.recipes)) {
            tags = (try? await RecipeTagsView.request(family.api).fetchOrSaved().tags) ?? tags
            ai = (try? await RecipeListModel.statusRequest(family.api).fetchOrSaved()) ?? ai
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
                ErrorBanner.shared.success(String(localized: "Recipe created"))
                family.open(.recipe(id: id))
            }
        }
        .sheet(isPresented: $generating) {
            RecipeGenerateView { list = .toTry }
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
            if !tagFilter.isEmpty {
                Button {
                    tagFilter = []
                } label: {
                    Label("Clear filters", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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
            ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, 80)
        } else if visible.isEmpty {
            if !key.query.isEmpty {
                ContentUnavailableView.search(text: key.query).padding(.top, 40)
            } else if !tagFilter.isEmpty {
                ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No recipe has these tags."))
                    .padding(.top, 40)
            } else if ai.showsWelcome(canEdit: family.canEdit) {
                MealsWelcomeView(ai: ai, addRecipe: { creating = true }, generate: { generating = true })
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
                        }
                    }
                }
                .padding(.top, 40)
            }
        } else {
            // Cards grow with the text size, up to one column on a phone.
            let width = min(cardWidth, 320)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.7), spacing: 16)], spacing: 16) {
                ForEach(visible) { recipe in
                    NavigationLink {
                        MealsRecipeDetailView(recipeID: recipe.id).assistantButton()
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
                ProgressView().frame(maxWidth: .infinity).padding()
                    .onAppear { Task { await model.loadMore(family.api) } }
            }
            Text("\(model.totalCount) recipes")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
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
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(RecipeSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            if !tags.isEmpty {
                Button {
                    showFilter = true
                } label: {
                    Label("Filter", systemImage: tagFilter.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        if family.canEdit {
            #if os(iOS)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                if ai.generate {
                    Button {
                        generating = true
                    } label: {
                        Label("Generate with AI", systemImage: "sparkles")
                    }
                }
                Button {
                    creating = true
                } label: {
                    Label("Add Recipe", systemImage: "plus")
                }
            }
        }
    }
}

/// One recipe in the grid: its photo, title, times and tags on a card.
struct RecipeCard: View {
    let recipe: RecipeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(path: recipe.imagePath) { RecipePhotoPlaceholder() }
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

    static let pageSize = 20

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
        } else if loadedQuery != q || items.isEmpty, q.query.isEmpty, let copy = get.saved() {
            items = copy.value.items
            totalCount = copy.value.totalCount
            loadedQuery = q
            error = nil
            saved = (copy.date, true)
        }
        do {
            let page: RecipeListPage = if q.query.isEmpty {
                try await get.fetch()
            } else {
                try await api.get("/meals/recipes", query: get.query)
            }
            items = page.items
            totalCount = page.totalCount
            loadedQuery = q
            error = nil
            saved = nil
        } catch is CancellationError {
            if let shown = saved, loadedQuery == q { saved = (shown.date, false) }
        } catch {
            if let shown = saved, loadedQuery == q, APIError.isTemporary(error) {
                saved = (shown.date, false)
            } else if items.isEmpty || loadedQuery != q || saved != nil {
                saved = nil
                self.error = error.localizedDescription
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

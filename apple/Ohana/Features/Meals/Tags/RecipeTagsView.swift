import SwiftUI

/// The family's recipe tags by category (web: meals/tags): editors add, rename and delete them
/// or start over with the defaults (File ▸ New Tag, ⌘N, adds one); viewers see them.
struct RecipeTagsView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.mealsOnScreen) private var onScreen
    @State private var state: LoadState<[RecipeTag]> = .idle
    @State private var adding = false
    @State private var renaming: RecipeTag?
    @State private var deleting: RecipeTag?
    @State private var confirmReset = false

    /// Changes need an editor and the server's latest tags, not the copy on the device.
    private var canEdit: Bool { family.canEdit && !state.isSaved }

    var body: some View {
        LoadStateView(state: state, retry: load) { tags in
            list(tags)
        }
        .ohanaBackground(ModuleTint.meals)
        .task(id: family.revision(.recipes)) { await load() }
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Tag", systemImage: "plus")
                    }
                }
            }
        }
        .focusedSceneValue(\.newItem, onScreen && canEdit ? NewItemAction(title: "New Tag") { adding = true } : nil)
        .sheet(isPresented: $adding) {
            RecipeTagSheet(tag: nil) { await load() }
        }
        .sheet(item: $renaming) { tag in
            RecipeTagSheet(tag: tag) { await load() }
        }
        .confirmationDialog("Delete tag?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { tag in
            Button("Delete", role: .destructive) { delete(tag) }
        } message: { _ in
            Text("Delete this tag?")
        }
        .confirmationDialog("Reset to Defaults", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) { reset() }
        } message: {
            Text("This will delete all tags (including custom ones) and remove them from your recipes. Start fresh with the defaults?")
        }
    }

    private func load() async {
        await LoadState.run($state, Self.request(family.api)) { $0.tags }
    }

    /// The tags' GET, for this page, the recipe list's filter and the editor (the prefetch asks
    /// the same).
    static func request(_ api: FamilyAPI) -> CachedGet<RecipeTagsResponse> {
        api.cached("/meals/tags")
    }

    private func list(_ tags: [RecipeTag]) -> some View {
        List {
            Section {
                Text("Organize your recipes with tags.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(RecipeTagCategory.allCases) { category in
                let inCategory = tags.filter { $0.category == category.rawValue }
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                Section {
                    if inCategory.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    }
                    ForEach(inCategory) { tag in
                        row(tag)
                    }
                } header: {
                    Label { Text(category.title) } icon: {
                        Circle().fill(category.color).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
            }
            if canEdit {
                Section {
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .refreshable { await load() }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    @ViewBuilder private func row(_ tag: RecipeTag) -> some View {
        let content = HStack {
            Text(tag.name)
            Spacer()
            Text(RecipeLocale.isGerman ? tag.nameEn : tag.nameDe)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if canEdit {
            Button { renaming = tag } label: { content.contentShape(.rect) }
                .tint(.primary)
                .accessibilityHint(Text("Renames the tag"))
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = tag }
                    Button("Rename", systemImage: "pencil") { renaming = tag }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { renaming = tag }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = tag }
                }
        } else {
            content
        }
    }

    private func delete(_ tag: RecipeTag) {
        perform {
            try await family.api.perform(.delete, "/meals/tags/\(tag.id)")
            family.didChange(.recipes, .meals)
        }
    }

    private func reset() {
        perform {
            let _: RecipeTagsResponse = try await family.api.send(.post, "/meals/tags/reset")
            family.didChange(.recipes, .meals)
        }
    }
}

/// Adding a tag (category and a name in one language or both) or renaming one.
private struct RecipeTagSheet: View {
    let tag: RecipeTag?
    let saved: () async -> Void

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var input: RecipeNewTag
    private let original: RecipeNewTag
    @State private var saving = false

    init(tag: RecipeTag?, saved: @escaping () async -> Void) {
        self.tag = tag
        self.saved = saved
        let start = tag.map {
            RecipeNewTag(category: RecipeTagCategory(rawValue: $0.category) ?? .cuisine, nameEn: $0.nameEn, nameDe: $0.nameDe)
        } ?? RecipeNewTag()
        original = start
        _input = State(initialValue: start)
    }

    private var hasChanges: Bool { input != original }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    RecipeNewTagFields(tag: $input, showsCategory: tag == nil)
                } footer: {
                    Text(RecipeNewTag.oneNameHint)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(tag == nil ? LocalizedStringKey("Add Tag") : LocalizedStringKey("Edit Tag"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!input.isValid || !hasChanges || saving)
                }
            }
        }
        .errorBanner()
        .discardGuard(hasChanges: hasChanges || saving)
        .presentationDetents([.medium])
        .recipeSheetFrame(minWidth: 420, minHeight: 280)
    }

    private func save() {
        saving = true
        let body = input.body
        perform {
            defer { saving = false }
            if let tag {
                try await family.api.perform(.patch, "/meals/tags/\(tag.id)",
                                             body: RecipeTagInput(nameEn: body.nameEn, nameDe: body.nameDe))
            } else {
                let _: RecipeIDResponse = try await family.api.send(.post, "/meals/tags", body: body)
            }
            family.didChange(.recipes, .meals)
            await saved()
            dismiss()
        }
    }
}

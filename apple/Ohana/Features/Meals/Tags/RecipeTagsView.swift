import SwiftUI

/// The family's recipe tags by category (web: meals/tags): editors add, rename and delete them
/// or start over with the defaults; viewers see them.
struct RecipeTagsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<[RecipeTag]> = .idle
    @State private var adding = false
    @State private var renaming: RecipeTag?
    @State private var deleting: RecipeTag?
    @State private var confirmReset = false

    var body: some View {
        LoadStateView(state: state, retry: load) { tags in
            list(tags)
        }
        .ohanaBackground(ModuleTint.meals)
        .task(id: family.revision(.recipes)) { await load() }
        .toolbar {
            if family.canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Tag", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
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
        await LoadState.run($state) {
            try await family.api.get("/meals/tags", as: RecipeTagsResponse.self).tags
        }
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
                    }
                }
            }
            if family.canEdit {
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
        if family.canEdit {
            content
                .contentShape(.rect)
                .onTapGesture { renaming = tag }
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

/// Adding a tag (category and both names) or renaming one.
private struct RecipeTagSheet: View {
    let tag: RecipeTag?
    let saved: () async -> Void

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var input = RecipeNewTag()
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                RecipeNewTagFields(tag: $input, showsCategory: tag == nil)
            }
            .formStyle(.grouped)
            .navigationTitle(tag == nil ? LocalizedStringKey("Add Tag") : LocalizedStringKey("Edit Tag"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) { save() }
                        .disabled(!input.isValid || saving)
                }
            }
        }
        .onAppear {
            if let tag {
                input = RecipeNewTag(category: RecipeTagCategory(rawValue: tag.category) ?? .cuisine,
                                     nameEn: tag.nameEn, nameDe: tag.nameDe)
            }
        }
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

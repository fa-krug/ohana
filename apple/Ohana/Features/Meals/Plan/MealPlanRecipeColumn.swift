import SwiftUI

/// The family's recipes beside the plan (iPad and Mac, for editors), to drag onto a day:
/// searchable, by list, tapping one opens it.
struct MealPlanRecipeColumn: View {
    @Environment(FamilyContext.self) private var family
    /// Recipes the active iteration plans already.
    let planned: Set<String>
    var open: (MealPlanRecipeOption) -> Void

    @State private var state: LoadState<[MealPlanRecipeOption]> = .idle
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recipes")
                    .font(.headline)
                Text("Drag one onto a day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            searchField
            LoadStateView(state: state, retry: load) { all in
                list(all.matching(query))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: family.revision(.recipes)) { await load() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search recipes", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    private func list(_ shown: [MealPlanRecipeOption]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                section("Favourites", shown.filter(\.isFavourite))
                section("Want to try", shown.filter { !$0.isFavourite })
            }
        }
        .scrollIndicators(.automatic)
        .overlay {
            if shown.isEmpty {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("No recipes yet", systemImage: "book")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ recipes: [MealPlanRecipeOption]) -> some View {
        if !recipes.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(recipes) { recipe in
                Button { open(recipe) } label: {
                    MealPlanRecipeRow(recipe: recipe, planned: planned.contains(recipe.id))
                        .font(.subheadline)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the recipe"))
                .mealDraggable(MealDragItem(familyID: family.family.id, recipeID: recipe.id, title: recipe.title))
            }
        }
    }

    private func load() async {
        await LoadState.run($state) { try await MealPlanRecipes.load(family.api) }
    }
}

/// A recipe in a list to plan from: its photo, title and whether the iteration plans it already.
struct MealPlanRecipeRow: View {
    let recipe: MealPlanRecipeOption
    let planned: Bool

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(path: recipe.imagePath)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: recipe.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if planned {
                    Text("Planned already")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// What a dragged recipe or planned meal looks like: its title in a chip.
struct MealDragPreview: View {
    let title: String

    var body: some View {
        Label {
            Text(verbatim: title).lineLimit(1)
        } icon: {
            Image(systemName: "fork.knife").foregroundStyle(ModuleTint.meals)
        }
        .font(.subheadline.weight(.medium))
        .chip(tint: ModuleTint.meals)
        .background(Color.cardBackground, in: .capsule)
        .frame(maxWidth: 280)
    }
}

extension View {
    /// Drags `item` with a chip of its title; nothing to drag without one (viewers).
    @ViewBuilder
    func mealDraggable(_ item: MealDragItem?) -> some View {
        if let item {
            draggable(item) { MealDragPreview(title: item.title) }
        } else {
            self
        }
    }

    /// Takes a dropped `MealDragItem` when `enabled` (editors); `action` says whether it was used,
    /// `isTargeted` whether one hovers the view.
    @ViewBuilder
    func mealDropDestination(enabled: Bool, action: @escaping (MealDragItem) -> Bool,
                             isTargeted: @escaping (Bool) -> Void) -> some View {
        if enabled {
            dropDestination(for: MealDragItem.self) { items, _ in
                guard let item = items.first else { return false }
                return action(item)
            } isTargeted: { isTargeted($0) }
        } else {
            self
        }
    }
}

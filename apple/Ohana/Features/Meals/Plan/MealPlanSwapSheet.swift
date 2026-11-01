import SwiftUI

/// Picks the recipe that replaces a planned meal (its leftover days follow): the family's
/// recipes by list, searchable, or a random one that isn't planned in the iteration yet.
struct MealPlanSwapSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let entry: MealPlanEntry
    /// Recipes the iteration plans already.
    let planned: Set<String>
    var choose: (MealPlanRecipeOption) -> Void

    @State private var state: LoadState<[MealPlanRecipeOption]> = .idle
    @State private var query = ""

    private var filtered: [MealPlanRecipeOption] {
        (state.value ?? []).filter { $0.id != entry.recipeId }.matching(query)
    }

    var body: some View {
        NavigationStack {
            LoadStateView(state: state, retry: load) { _ in
                List {
                    let known = filtered.filter(\.isFavourite)
                    let toTry = filtered.filter { !$0.isFavourite }
                    if !known.isEmpty {
                        Section("Favourites") { ForEach(known) { row($0) } }
                    }
                    if !toTry.isEmpty {
                        Section("Want to try") { ForEach(toTry) { row($0) } }
                    }
                }
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Search recipes"))
            .navigationTitle("Swap \(entry.recipeTitle)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Surprise me", systemImage: "dice") { pickRandom() }
                        .disabled(filtered.isEmpty)
                }
            }
            .task { await load() }
        }
        .errorBanner()
        .presentationDetents([.medium, .large])
    }

    private func row(_ recipe: MealPlanRecipeOption) -> some View {
        Button {
            choose(recipe)
            dismiss()
        } label: {
            MealPlanRecipeRow(recipe: recipe, planned: planned.contains(recipe.id))
        }
        .buttonStyle(.plain)
    }

    private func pickRandom() {
        let candidates = filtered.filter { !planned.contains($0.id) }
        guard let recipe = (candidates.isEmpty ? filtered : candidates).randomElement() else { return }
        choose(recipe)
        dismiss()
    }

    private func load() async {
        await LoadState.run($state) { try await MealPlanRecipes.load(family.api) }
    }
}

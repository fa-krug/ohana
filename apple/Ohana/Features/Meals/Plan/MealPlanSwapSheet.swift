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
        let all = (state.value ?? []).filter { $0.id != entry.recipeId }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.title.localizedStandardContains(q) }
    }

    var body: some View {
        NavigationStack {
            LoadStateView(state: state, retry: load) { _ in
                List {
                    let known = filtered.filter { $0.listType == "KNOWN" }
                    let toTry = filtered.filter { $0.listType != "KNOWN" }
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
            HStack(spacing: 12) {
                RemoteImage(path: recipe.imagePath)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: recipe.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if planned.contains(recipe.id) {
                        Text("Planned already")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
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
        await LoadState.run($state) {
            var all: [MealPlanRecipeOption] = []
            var offset = 0
            while true {
                let page: MealPlanRecipePage = try await family.api.get("/recipes", query: [
                    "limit": "100", "offset": "\(offset)", "locale": MealPlanLanguage.current,
                ])
                all += page.items
                offset += page.items.count
                if page.items.isEmpty || offset >= page.totalCount { break }
            }
            return all
        }
    }
}

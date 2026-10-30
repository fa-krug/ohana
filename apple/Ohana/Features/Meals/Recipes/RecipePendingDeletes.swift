import SwiftUI

/// Deleting a recipe waits a few seconds so it can be undone (the web's
/// lib/meals/recipes/pending-delete.ts and the list's undo toast). The recipe is hidden from
/// the lists meanwhile; the banner offers "Undo".
@Observable
final class RecipePendingDeletes {
    static let shared = RecipePendingDeletes()

    struct Pending: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// Recipes waiting to be deleted, the newest last (the banner shows it).
    private(set) var pending: [Pending] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    static let delay: Duration = .seconds(5)

    func isHidden(_ id: String) -> Bool { tasks[id] != nil }

    var latest: Pending? { pending.last }

    func schedule(_ id: String, title: String, family: FamilyContext) {
        tasks[id]?.cancel()
        pending.removeAll { $0.id == id }
        pending.append(Pending(id: id, title: title))
        let api = family.api
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            do {
                try await api.perform(.delete, "/meals/recipes/\(id)")
            } catch {
                ErrorBanner.shared.show(error)
            }
            self?.finish(id)
            family.didChange(.recipes, .meals, .mealPlan)
        }
    }

    func undo(_ id: String) {
        tasks[id]?.cancel()
        finish(id)
    }

    private func finish(_ id: String) {
        tasks[id] = nil
        pending.removeAll { $0.id == id }
    }
}

/// "Recipe deleted. Undo" at the bottom of the meals pages while a delete waits.
struct RecipeUndoBanner: View {
    @State private var deletes = RecipePendingDeletes.shared

    var body: some View {
        if let latest = deletes.latest {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recipe deleted.").font(.callout.weight(.semibold))
                    Text(latest.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Undo") { withAnimation { deletes.undo(latest.id) } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("z", modifiers: .command)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

import SwiftUI

/// Deleting a recipe waits a few seconds so it can be undone (the web's
/// lib/meals/recipes/pending-delete.ts and the list's undo toast). The recipe is hidden from
/// the lists meanwhile; the banner offers "Undo", and so does the window's undo manager
/// (Edit → Undo, ⌘Z) while the delete waits.
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
    /// Per waiting delete: the undo manager it was registered with and the target of its action.
    private var registrations: [String: (manager: UndoManager, target: UndoTarget)] = [:]

    /// The target an undo action is registered for (one per delete, so it can be removed alone).
    final class UndoTarget {}

    static let delay: Duration = .seconds(5)

    func isHidden(_ id: String) -> Bool { tasks[id] != nil }

    var latest: Pending? { pending.last }

    func schedule(_ id: String, title: String, family: FamilyContext, undoManager: UndoManager? = nil) {
        tasks[id]?.cancel()
        unregister(id)
        pending.removeAll { $0.id == id }
        pending.append(Pending(id: id, title: title))
        if let undoManager {
            let target = UndoTarget()
            registrations[id] = (undoManager, target)
            undoManager.registerUndo(withTarget: target) { [weak self] _ in
                self?.registrations[id] = nil
                withAnimation { self?.undo(id) }
            }
            undoManager.setActionName(String(localized: "Delete Recipe"))
        }
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
        unregister(id)
        pending.removeAll { $0.id == id }
    }

    /// The delete can't be taken back any more (done, or undone by the banner).
    private func unregister(_ id: String) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        registration.manager.removeAllActions(withTarget: registration.target)
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

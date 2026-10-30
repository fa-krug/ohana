import SwiftUI

/// Deleting a recipe or a shopping item waits a few seconds so it can be undone (the web's
/// lib/meals/recipes/pending-delete.ts and the list's undo toast). It is hidden from the lists
/// meanwhile; the banner offers "Undo", and so does the window's undo manager (Edit → Undo, ⌘Z)
/// while the delete waits.
@Observable
final class MealsPendingDeletes {
    static let shared = MealsPendingDeletes()

    /// What is deleted.
    enum Kind: Equatable {
        case recipe, shoppingItem

        func path(_ id: String) -> String {
            switch self {
            case .recipe: "/meals/recipes/\(id)"
            case .shoppingItem: "/meals/shopping/items/\(id)"
            }
        }

        /// The data the delete changes, to reload when it's done.
        var areas: [DataArea] {
            switch self {
            case .recipe: [.recipes, .meals, .mealPlan]
            case .shoppingItem: [.shopping]
            }
        }

        /// The banner's line.
        var message: LocalizedStringKey {
            switch self {
            case .recipe: "Recipe deleted."
            case .shoppingItem: "Item deleted."
            }
        }

        /// Edit → Undo …
        var actionName: String {
            switch self {
            case .recipe: String(localized: "Delete Recipe")
            case .shoppingItem: String(localized: "Delete Item")
            }
        }
    }

    struct Pending: Identifiable, Equatable {
        let id: String
        let title: String
        let kind: Kind
    }

    /// Deletes waiting, the newest last (the banner shows it).
    private(set) var pending: [Pending] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Per waiting delete: the undo manager it was registered with and the target of its action.
    private var registrations: [String: (manager: UndoManager, target: UndoTarget)] = [:]

    /// The target an undo action is registered for (one per delete, so it can be removed alone).
    final class UndoTarget {}

    /// How long a delete waits; the tests make it short.
    var delay: Duration = .seconds(5)

    func isHidden(_ id: String) -> Bool { tasks[id] != nil }

    var latest: Pending? { pending.last }

    /// Hides the recipe or item now and deletes it on the server (DELETE its path) after `delay`.
    func schedule(_ id: String, kind: Kind, title: String, family: FamilyContext, undoManager: UndoManager? = nil) {
        let api = family.api
        schedule(id, kind: kind, title: title, undoManager: undoManager) {
            try await api.perform(.delete, kind.path(id))
        } done: {
            family.didChange(kind.areas)
        }
    }

    /// Hides it now and runs `send` after `delay` unless undone, then `done`.
    func schedule(_ id: String, kind: Kind, title: String, undoManager: UndoManager? = nil,
                  send: @escaping () async throws -> Void, done: @escaping () -> Void = {}) {
        tasks[id]?.cancel()
        unregister(id)
        pending.removeAll { $0.id == id }
        pending.append(Pending(id: id, title: title, kind: kind))
        if let undoManager {
            let target = UndoTarget()
            registrations[id] = (undoManager, target)
            undoManager.registerUndo(withTarget: target) { [weak self] _ in
                self?.registrations[id] = nil
                withAnimation { self?.undo(id) }
            }
            undoManager.setActionName(kind.actionName)
        }
        let delay = delay
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                try await send()
            } catch {
                ErrorBanner.shared.show(error)
            }
            self?.finish(id)
            done()
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

/// "Recipe deleted. Undo" (or an item) at the bottom of the meals pages while a delete waits.
struct MealsUndoBanner: View {
    @State private var deletes = MealsPendingDeletes.shared

    var body: some View {
        if let latest = deletes.latest {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(latest.kind.message).font(.callout.weight(.semibold))
                    Text(verbatim: latest.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button("Undo") { withAnimation { deletes.undo(latest.id) } }
                    .buttonStyle(.glassProminent)
                    .tint(ModuleTint.meals)
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

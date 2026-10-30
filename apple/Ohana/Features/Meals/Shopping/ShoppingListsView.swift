import SwiftUI

/// Meals → Shopping lists (placeholder until the module is ported).
struct ShoppingListsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Shopping", systemImage: "cart")
            .navigationTitle("Shopping")
    }
}

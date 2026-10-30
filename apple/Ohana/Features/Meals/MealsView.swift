import SwiftUI

/// Meals (placeholder until the module is ported).
struct MealsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Meals", systemImage: "fork.knife")
            .ohanaBackground(ModuleTint.meals)
            .navigationTitle("Meals")
    }
}

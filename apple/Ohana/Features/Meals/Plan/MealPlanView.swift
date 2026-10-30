import SwiftUI

/// Meals → Plan (placeholder until the module is ported).
struct MealPlanView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Meal plan", systemImage: "calendar.badge.clock")
            .navigationTitle("Meal plan")
    }
}

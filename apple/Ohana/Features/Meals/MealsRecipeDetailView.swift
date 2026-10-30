import SwiftUI

/// A recipe's page, pushed from anywhere in Meals (placeholder until the module is ported).
struct MealsRecipeDetailView: View {
    let recipeID: String

    var body: some View {
        ContentUnavailableView("Recipe", systemImage: "book")
    }
}

/// Cooking a recipe step by step (placeholder until the module is ported).
struct MealsCookView: View {
    let recipeID: String

    var body: some View {
        ContentUnavailableView("Cook", systemImage: "flame")
    }
}

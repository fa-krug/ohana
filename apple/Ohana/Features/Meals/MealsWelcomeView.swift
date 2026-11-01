import SwiftUI

/// The first steps while the family has no recipe at all (the web's meals/page.tsx, cookless's
/// welcome page), shown to editors in place of the empty recipe list: add the first recipe,
/// let the AI suggest some, plan the meals, invite someone to cook with.
struct MealsWelcomeView: View {
    let ai: MealsAIStatus
    var addRecipe: () -> Void
    var generate: () -> Void
    var importFromWeb: () -> Void = {}

    @Environment(FamilyContext.self) private var family
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(ModuleTint.meals.gradient)
                    .symbolEffect(.bounce, options: .nonRepeating)
                    .accessibilityHidden(true)
                Text("Welcome to Meals!")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Your family has no recipes yet. Here’s how to start:")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                step("Add your first recipe", "Start building your collection", systemImage: "book", action: addRecipe)
                if ai.generate {
                    step("Generate with AI", "Let the assistant suggest recipes to try", systemImage: "sparkles",
                         action: generate)
                    step("Import from the web", "Turn a recipe page into a recipe", systemImage: "globe",
                         action: importFromWeb)
                }
                step("Create a meal plan", "Plan your meals for the week", systemImage: "calendar") {
                    family.open(.mealPlan)
                }
                step("Invite a family member", "Cook together", systemImage: "person.badge.plus") {
                    family.open(.settings(.members))
                }
            }
            Button(action: addRecipe) {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(ModuleTint.meals)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }

    private func step(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, systemImage: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                TintedIcon(systemImage: systemImage, tint: ModuleTint.meals, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentCard(cornerRadius: 20, padding: 12)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
    }
}

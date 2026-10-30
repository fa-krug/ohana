import SwiftUI

/// The first steps while the family has no recipe at all (the web's meals/page.tsx, cookless's
/// welcome page), shown to editors in place of the empty recipe list: add the first recipe,
/// let the AI suggest some, plan the meals, invite someone to cook with.
struct MealsWelcomeView: View {
    let ai: MealsAIStatus
    var addRecipe: () -> Void
    var generate: () -> Void

    @Environment(FamilyContext.self) private var family

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(ModuleTint.meals.gradient)
                    .symbolEffect(.bounce, options: .nonRepeating)
                Text("Welcome to Meals!")
                    .font(.title.bold())
                Text("Your family has no recipes yet. Here’s how to start:")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    step("Add your first recipe", "Start building your collection", systemImage: "book", action: addRecipe)
                    if ai.generate {
                        step("Generate with AI", "Let the assistant suggest recipes to try", systemImage: "sparkles",
                             action: generate)
                    }
                    step("Create a meal plan", "Plan your meals for the week", systemImage: "calendar") {
                        family.open(.mealPlan)
                    }
                    step("Invite a family member", "Cook together", systemImage: "person.badge.plus") {
                        family.open(.settings(.members))
                    }
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
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(ModuleTint.meals)
                    .frame(width: 44, height: 44)
                    .background(ModuleTint.meals.opacity(0.15), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

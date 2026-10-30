import SwiftUI

/// The parts of Meals (the web's meals-tabs.tsx).
enum MealsSegment: String, CaseIterable, Identifiable {
    case recipes, plan, shopping, tags

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .recipes: "Recipes"
        case .plan: "Plan"
        case .shopping: "Shopping"
        case .tags: "Tags"
        }
    }

    var systemImage: String {
        switch self {
        case .recipes: "book"
        case .plan: "calendar"
        case .shopping: "cart"
        case .tags: "tag"
        }
    }
}

/// A screen Meals pushes for a route (and the plan for its meals): a recipe, or cooking it, at
/// the given servings (nil: the recipe's own).
enum MealsDestination: Hashable, Identifiable {
    case recipe(id: String, servings: Int? = nil)
    case cook(recipeID: String, servings: Int? = nil)

    var id: Self { self }
}

/// What Meals does with an `AppRoute` of its module: the part to show, a screen to push, the new
/// recipe editor to open, the shopping list to pick.
struct MealsRouting: Equatable {
    var segment: MealsSegment?
    var destination: MealsDestination?
    var createsRecipe = false
    /// With `segment == .shopping`: the list (nil: the latest).
    var shoppingListID: String?

    /// Nil for routes of other modules.
    init?(_ route: AppRoute) {
        switch route {
        case .module(.meals):
            break
        case let .recipe(id):
            segment = .recipes
            destination = .recipe(id: id)
        case let .cook(recipeID):
            destination = .cook(recipeID: recipeID)
        case .newRecipe:
            segment = .recipes
            createsRecipe = true
        case .mealPlan:
            segment = .plan
        case let .shoppingList(id):
            segment = .shopping
            shoppingListID = id
        case .mealTags:
            segment = .tags
        default:
            return nil
        }
    }
}

/// Meals (web: f/[familyId]/meals): recipes, meal plan, shopping lists and tags behind a
/// Liquid Glass switcher; the part shown last is remembered per device. Lives inside the
/// shell's NavigationStack and takes the module's routes (`family.open(.recipe(id:))`, …).
struct MealsView: View {
    @Environment(FamilyContext.self) private var family
    @AppStorage("meals.segment") private var segment: MealsSegment = .recipes
    @State private var destination: MealsDestination?
    @State private var creatingRecipe = false
    @State private var shoppingListID: String?

    var body: some View {
        Group {
            switch segment {
            case .recipes:
                RecipeListView()
                    .navigationTitle("Recipes")
            case .plan:
                MealPlanView()
            case .shopping:
                ShoppingListsView(selection: $shoppingListID)
            case .tags:
                RecipeTagsView()
                    .navigationTitle("Tags")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ohanaBackground(ModuleTint.meals)
        .safeAreaInset(edge: .top, spacing: 0) {
            MealsSegmentSwitcher(selection: $segment)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { RecipeUndoBanner() }
        .animation(.spring(duration: 0.35), value: RecipePendingDeletes.shared.latest)
        .background { MealsSegmentShortcuts(selection: $segment) }
        .navigationDestination(item: $destination) { MealsDestinationView(destination: $0) }
        .sheet(isPresented: $creatingRecipe) {
            RecipeEditorSheet(mode: .create(.known)) { id in
                ErrorBanner.shared.success(String(localized: "Recipe created"))
                family.open(.recipe(id: id))
            }
        }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .meals), let routing = MealsRouting(route) else { return }
            if let target = routing.segment { segment = target }
            if routing.segment == .shopping { shoppingListID = routing.shoppingListID }
            if routing.createsRecipe { creatingRecipe = true }
            if let target = routing.destination { destination = target }
        }
    }
}

/// The screen of a `MealsDestination`.
struct MealsDestinationView: View {
    let destination: MealsDestination

    var body: some View {
        switch destination {
        case let .recipe(id, servings): MealsRecipeDetailView(recipeID: id, initialServings: servings)
        case let .cook(id, servings): MealsCookView(recipeID: id, servings: servings)
        }
    }
}

/// The switcher: one glass capsule per part, the chosen one tinted; the glass morphs between
/// them.
struct MealsSegmentSwitcher: View {
    @Binding var selection: MealsSegment
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(MealsSegment.allCases) { item in
                    let selected = item == selection
                    Button {
                        withAnimation(.spring(duration: 0.3)) { selection = item }
                    } label: {
                        Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(selected ? Color.primary : .secondary)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? .regular.tint(ModuleTint.meals.opacity(0.45)).interactive() : .regular.interactive(),
                                 in: .capsule)
                    .glassEffectID(item.id, in: glass)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

/// ⌥⌘1…4 switch between the parts (Mac and iPad keyboards).
private struct MealsSegmentShortcuts: View {
    @Binding var selection: MealsSegment

    var body: some View {
        ZStack {
            ForEach(Array(MealsSegment.allCases.enumerated()), id: \.element) { index, item in
                Button(String(localized: item.title)) { selection = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

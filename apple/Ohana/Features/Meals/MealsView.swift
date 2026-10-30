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

/// Meals (web: f/[familyId]/meals): recipes, meal plan, shopping lists and tags behind a
/// Liquid Glass switcher; the part shown last is remembered per device. Lives inside the
/// shell's NavigationStack.
struct MealsView: View {
    @Environment(FamilyContext.self) private var family
    @AppStorage("meals.segment") private var segment: MealsSegment = .recipes

    var body: some View {
        Group {
            switch segment {
            case .recipes:
                RecipeListView()
                    .ohanaBackground(ModuleTint.meals)
                    .navigationTitle("Recipes")
            case .plan:
                MealPlanView()
            case .shopping:
                ShoppingListsView()
            case .tags:
                RecipeTagsView()
                    .navigationTitle("Tags")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            MealsSegmentSwitcher(selection: $segment)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .overlay(alignment: .bottom) { RecipeUndoBanner() }
        .animation(.spring(duration: 0.35), value: RecipePendingDeletes.shared.latest)
        .background { MealsSegmentShortcuts(selection: $segment) }
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

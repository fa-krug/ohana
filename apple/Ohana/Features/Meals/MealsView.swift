import SwiftUI

/// The parts of Meals (the web's meals-tabs.tsx). The tags are a page of their own, opened from
/// the recipe list's Filter menu.
enum MealsSegment: String, CaseIterable, Identifiable {
    case recipes, plan

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .recipes: "Recipes"
        case .plan: "Plan"
        }
    }

    var systemImage: String {
        switch self {
        case .recipes: "book"
        case .plan: "calendar"
        }
    }
}

/// A screen a route of Meals opens: a recipe (pushed), or cooking it (over everything, see
/// `cookPresentation`), at the given servings (nil: the recipe's own).
enum MealsDestination: Hashable {
    case recipe(id: String, servings: Int? = nil)
    case cook(recipeID: String, servings: Int? = nil)
}

/// A recipe at some servings (nil: the recipe's own): the one pushed, or the one being cooked.
struct MealsRecipeRef: Hashable, Identifiable {
    let recipeID: String
    var servings: Int?

    var id: Self { self }
}

/// What Meals does with an `AppRoute` of its module: the part to show, the recipe list to show, a
/// screen to open, the new recipe editor to open, the tags page to push.
struct MealsRouting: Equatable {
    var segment: MealsSegment?
    var recipeList: RecipeListType?
    var destination: MealsDestination?
    var createsRecipe = false
    var showsTags = false

    /// Nil for routes of other modules.
    init?(_ route: AppRoute) {
        switch route {
        case .module(.meals):
            break
        case let .recipe(id):
            segment = .recipes
            destination = .recipe(id: id)
        case let .recipeList(list):
            segment = .recipes
            recipeList = list
        case let .cook(recipeID):
            destination = .cook(recipeID: recipeID)
        case .newRecipe:
            segment = .recipes
            createsRecipe = true
        case .mealPlan:
            segment = .plan
        case .mealTags:
            segment = .recipes
            showsTags = true
        default:
            return nil
        }
    }
}

/// Meals (web: f/[familyId]/meals): recipes and meal plan behind a
/// segmented picker (in the toolbar on iPad and Mac, under the navigation bar on iPhone); the
/// part shown last is remembered per device. The tags page is pushed (the recipe list's Filter
/// menu, `.mealTags`). Lives inside the shell's NavigationStack and takes
/// the module's routes (`family.open(.recipe(id:))`, …). Its menu (the Mac's menu bar, the
/// iPad's ⌘-hold list) switches between the parts with ⌥⌘1…2.
struct MealsView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("meals.segment") private var segment: MealsSegment = .recipes
    /// The recipe list's Favourites / Want to try (`RecipeListView` keeps it under the same key).
    @AppStorage(RecipeListModel.listKey) private var recipeList = RecipeListModel.defaultList
    @State private var shownRecipe: MealsRecipeRef?
    @State private var cooking: MealsRecipeRef?
    @State private var creatingRecipe = false
    @State private var managingTags = false
    @State private var onScreen = false
    /// False while the iPhone keeps the page hidden behind another (`shellPageVisible`).
    @Environment(\.shellPageVisible) private var pageVisible
    /// The page is wide enough for the segments in the toolbar.
    @State private var segmentsFit = true

    var body: some View {
        Group {
            switch segment {
            case .recipes:
                RecipeListView { managingTags = true }
                    .navigationTitle("Recipes")
            case .plan:
                MealPlanView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width >= 640 } action: { segmentsFit = $0 }
        .ohanaBackground(ModuleTint.meals)
        .toolbar {
            if sizeClass != .compact {
                ToolbarItem(placement: .principal) {
                    MealsSegmentPicker(selection: $segment, fits: segmentsFit)
                }
            }
        }
        #if os(iOS)
        .safeAreaBar(edge: .top) {
            if sizeClass == .compact {
                MealsSegmentPicker(selection: $segment)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        // Under a large title the bar moves with the title as it collapses, and scrolling back
        // up made the two fight (the page jittered). The segments name the part anyway.
        .navigationBarTitleDisplayMode(sizeClass == .compact ? .inline : .automatic)
        #endif
        .overlay(alignment: .bottom) { MealsUndoBanner() }
        .animation(.spring(duration: 0.35), value: MealsPendingDeletes.shared.latest)
        .environment(\.mealsOnScreen, onScreen && pageVisible)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .focusedSceneValue(\.moduleMenu, onScreen ? ModuleMenu(title: "Meals") { sectionCommands } : nil)
        .navigationDestination(item: $shownRecipe) {
            MealsRecipeDetailView(recipeID: $0.recipeID, initialServings: $0.servings).assistantButton()
        }
        .navigationDestination(isPresented: $managingTags) { MealTagsPage() }
        .cookPresentation($cooking)
        .sheet(isPresented: $creatingRecipe) {
            RecipeEditorSheet(mode: .create(.known)) { id in
                family.open(.recipe(id: id))
            }
        }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .meals), let routing = MealsRouting(route) else { return }
            if let target = routing.segment { segment = target }
            if let list = routing.recipeList { recipeList = list }
            if routing.createsRecipe { creatingRecipe = true }
            if routing.showsTags { managingTags = true }
            switch routing.destination {
            case let .recipe(id, servings)?: shownRecipe = MealsRecipeRef(recipeID: id, servings: servings)
            case let .cook(id, servings)?: cooking = MealsRecipeRef(recipeID: id, servings: servings)
            case nil: break
            }
        }
    }

    /// The parts in the module's menu, ⌥⌘1…2.
    @ViewBuilder private var sectionCommands: some View {
        ForEach(Array(MealsSegment.allCases.enumerated()), id: \.element) { index, item in
            Button {
                segment = item
            } label: {
                Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
        }
    }
}

/// The tags page pushed over Meals: on screen (File ▸ New Tag) only while it's shown, as Meals
/// itself is no longer then.
private struct MealTagsPage: View {
    @State private var onScreen = false
    @Environment(\.shellPageVisible) private var pageVisible

    var body: some View {
        RecipeTagsView()
            .navigationTitle("Tags")
            .environment(\.mealsOnScreen, onScreen && pageVisible)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .assistantButton()
    }
}

extension EnvironmentValues {
    /// Meals is the screen shown (not a hidden tab, nor covered by a pushed recipe): only then do
    /// its parts offer File ▸ New ….
    @Entry var mealsOnScreen = false
}

/// The parts of Meals as a segmented control with their full names; where the segments can't
/// hold them (accessibility text sizes, a narrow window), a menu.
struct MealsSegmentPicker: View {
    @Binding var selection: MealsSegment
    /// Whether the segments fit, when the caller knows (the toolbar: by the page's width). A
    /// `ViewThatFits` there measured both forms at every step of a resize, such as the assistant
    /// panel sliding in.
    var fits: Bool?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            menu
        } else if let fits {
            if fits { segments } else { menu }
        } else {
            ViewThatFits(in: .horizontal) {
                segments
                menu
            }
        }
    }

    private var segments: some View {
        Picker("Section", selection: $selection) {
            ForEach(MealsSegment.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var menu: some View {
        Picker(selection: $selection) {
            ForEach(MealsSegment.allCases) { item in
                Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
                    .tag(item)
            }
        } label: {
            Text("Section")
        }
        .pickerStyle(.menu)
    }
}

extension View {
    /// Cooking a recipe, wherever it starts: full screen on iPhone and iPad (the screen stays
    /// awake meanwhile), a large sheet on the Mac. The cook view's Close ends it.
    func cookPresentation(_ recipe: Binding<MealsRecipeRef?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: recipe) { ref in
            NavigationStack { MealsCookView(recipeID: ref.recipeID, servings: ref.servings) }
                .errorBanner()
        }
        #else
        sheet(item: recipe) { ref in
            NavigationStack { MealsCookView(recipeID: ref.recipeID, servings: ref.servings) }
                .frame(minWidth: 640, idealWidth: 900, minHeight: 560, idealHeight: 760)
                .errorBanner()
        }
        #endif
    }
}

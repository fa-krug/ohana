import SwiftUI

/// A change to the plan that can be taken back (POST /meals/plan/restore with `body`) for a few
/// seconds: with the bar's "Undo" or the window's undo manager (Edit → Undo, ⌘Z).
final class MealPlanUndo: Identifiable {
    let id = UUID()
    let message: String
    let body: JSONValue

    init(message: String, body: JSONValue) {
        self.message = message
        self.body = body
    }
}

/// Meals → Plan: the family's meal plan (port of the web's plan page). The active iteration day
/// by day (lunch with its recipe, leftovers, away days, shopping days), the past ones folded; the
/// shopping list in Reminders (toolbar: Shopping List, `ShoppingRemindersSheet`); and for
/// editors: setting the plan up, refreshing an iteration, starting the next one, swapping or
/// removing a meal (each undoable for a few seconds). Editors drag a meal
/// onto another day (swapping them) or a recipe onto a day; on iPad and Mac the recipes to drag
/// sit in a column beside the plan (toolbar: Recipes).
struct MealPlanView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("meals.plan.recipes") private var showsRecipes = true
    @State private var state: LoadState<MealPlanResponse> = .idle
    @State private var showSetup = false
    @State private var shownRecipe: MealsRecipeRef?
    @State private var cooking: MealsRecipeRef?
    @State private var swapping: MealPlanEntry?
    @State private var confirmRenew: MealPlanIteration?
    @State private var undo: MealPlanUndo?
    @State private var working = false
    @State private var showsShopping = false
    @State private var reminders = ShoppingReminders.shared

    /// Changes need an editor and the server's latest plan, not the copy on the device.
    private var canEdit: Bool { family.canEdit && !state.isSaved }

    /// What the shopping days say about Reminders: the list they go to, or that they could.
    private var shoppingLabel: String? {
        guard !family.api.client.isDemo else { return nil }
        guard let listID = reminders.settings(for: family.api).listID else {
            return String(localized: "Shopping list in Reminders")
        }
        let title = RemindersStore.shared.list(listID)?.title ?? String(localized: "Reminders")
        return String(localized: "In Reminders: \(title)")
    }

    var body: some View {
        LoadStateView(state: state, retry: load) { data in
            content(data)
        }
        .navigationTitle("Meal plan")
        .toolbar {
            if offersRecipeColumn(state.value?.plan) {
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Recipes", systemImage: "book", isOn: $showsRecipes)
                        .help("Recipes to drag onto a day")
                }
            }
            if !family.api.client.isDemo {
                ToolbarItem(placement: .primaryAction) {
                    Button("Shopping List", systemImage: "checklist") { showsShopping = true }
                        .help("The shopping list in Reminders")
                }
            }
            if canEdit, let data = state.value, data.plan != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Update plan", systemImage: "slider.horizontal.3") { showSetup = true }
                }
            }
        }
        .task(id: family.revision(.mealPlan)) { await load() }
        .sheet(isPresented: $showSetup) {
            if let data = state.value {
                MealPlanSetupSheet(initial: data.plan.map(MealPlanSetupInput.init(plan:)) ?? .initial,
                                   tags: data.tags, replacesPlan: data.plan != nil) { input in
                    try await setUp(input)
                }
            }
        }
        .sheet(isPresented: $showsShopping) { ShoppingRemindersSheet() }
        .sheet(item: $swapping) { entry in
            MealPlanSwapSheet(entry: entry, planned: state.value?.plan?.recipeIDs(in: iterationID(of: entry)) ?? []) { recipe in
                swap(entry, to: recipe)
            }
        }
        .confirmationDialog("Plan these days again?", isPresented: Binding(
            get: { confirmRenew != nil }, set: { if !$0 { confirmRenew = nil } }
        ), titleVisibility: .visible, presenting: confirmRenew) { iteration in
            Button("Refresh") { renew(iteration) }
        } message: { _ in
            Text("The meals of these days are planned anew.")
        }
        .navigationDestination(item: $shownRecipe) {
            MealsRecipeDetailView(recipeID: $0.recipeID, initialServings: $0.servings).assistantButton()
        }
        .cookPresentation($cooking)
        .overlay(alignment: .bottom) {
            if let undo {
                MealPlanUndoBar(undo: undo) { take(undo) } dismiss: { expire(undo) }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: undo?.id)
    }

    private func load() async {
        await LoadState.run($state, Self.request(family.api))
    }

    /// The plan's GET (the prefetch asks the same).
    static func request(_ api: FamilyAPI) -> CachedGet<MealPlanResponse> {
        api.cached("/meals/plan")
    }

    // MARK: Content

    /// Editors on iPad and Mac with an active iteration may show the recipes beside the plan.
    private func offersRecipeColumn(_ plan: MealPlanDTO?) -> Bool {
        canEdit && sizeClass != .compact && plan?.activeIteration != nil
    }

    @ViewBuilder
    private func content(_ data: MealPlanResponse) -> some View {
        if let plan = data.plan, !plan.iterations.isEmpty {
            HStack(spacing: 0) {
                days(plan, away: data.away)
                if showsRecipes, offersRecipeColumn(plan), let active = plan.activeIteration {
                    MealPlanRecipeColumn(planned: plan.recipeIDs(in: active.id)) { recipe in
                        shownRecipe = MealsRecipeRef(recipeID: recipe.id)
                    }
                    .contentCard(padding: 12)
                    .frame(minWidth: 0, maxWidth: 320, maxHeight: .infinity)
                    .padding([.vertical, .trailing])
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: showsRecipes)
        } else {
            ContentUnavailableView {
                Label("No meal plan yet", systemImage: "calendar.badge.plus")
            } description: {
                Text("Set up your first plan to get cooking!")
            } actions: {
                if canEdit {
                    Button("Let’s go!") { showSetup = true }
                        .buttonStyle(.glassProminent)
                        .tint(ModuleTint.meals)
                }
            }
        }
    }

    private func days(_ plan: MealPlanDTO, away: [String: [String]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if canEdit, plan.activeEnded(today: .today) {
                    endedBanner
                }
                if let active = plan.activeIteration {
                    card(active, plan: plan, away: away, archived: false)
                } else {
                    ContentUnavailableView {
                        Label("No active plan", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("Time to plan your next round!")
                    } actions: {
                        if canEdit { nextButton }
                    }
                    .contentCard()
                }
                if !plan.pastIterations.isEmpty {
                    Text("Previous plans")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                    ForEach(plan.pastIterations) { iteration in
                        card(iteration, plan: plan, away: away, archived: true)
                    }
                }
            }
            .padding()
            .padding(.bottom, undo == nil ? 0 : 60)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
    }

    private func card(_ iteration: MealPlanIteration, plan: MealPlanDTO, away: [String: [String]], archived: Bool) -> some View {
        MealPlanIterationCard(
            iteration: iteration,
            rows: iteration.dayRows(away: away),
            archived: archived,
            familyID: family.family.id,
            canEdit: canEdit,
            shoppingLabel: shoppingLabel,
            working: working,
            onRenew: { confirmRenew = iteration },
            onDrop: { item, row in drop(item, onto: row, of: iteration) },
            onAction: { action in
                switch action {
                case let .open(entry): shownRecipe = MealsRecipeRef(recipeID: entry.recipeId, servings: entry.servings)
                case let .cook(entry): cooking = MealsRecipeRef(recipeID: entry.recipeId, servings: entry.servings)
                case let .swap(entry): swapping = entry
                case let .remove(entry): remove(entry)
                case .shoppingSettings: showsShopping = true
                }
            }
        )
    }

    private var endedBanner: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                endedLabel
                Spacer(minLength: 8)
                nextButton
            }
            VStack(alignment: .leading, spacing: 12) {
                endedLabel
                nextButton
            }
        }
        .contentCard(tint: ModuleTint.meals)
    }

    private var endedLabel: some View {
        Label {
            Text("This plan has wrapped up!")
                .font(.subheadline.weight(.medium))
        } icon: {
            Image(systemName: "flag.checkered")
                .font(.title3)
                .foregroundStyle(ModuleTint.meals)
        }
    }

    private var nextButton: some View {
        Button("Start next iteration", systemImage: "forward.end") { next() }
            .buttonStyle(.borderedProminent)
            .tint(ModuleTint.meals)
            .disabled(working)
    }

    private func iterationID(of entry: MealPlanEntry) -> String {
        state.value?.plan?.iterations.first { $0.entries.contains(entry) }?.id ?? ""
    }

    // MARK: Changes

    private func setUp(_ input: MealPlanSetupInput) async throws {
        let _: MealPlanChangeResult = try await family.api.send(.post, "/meals/plan/setup", body: input)
        // Setting up deletes every iteration (the sheet asked first), so an earlier change can't
        // be restored any more, and the server keeps nothing to restore this one from.
        if let undo { expire(undo) }
        family.didChange(.mealPlan)
        ErrorBanner.shared.success(String(localized: "Meal plan generated."))
    }

    private func change(_ message: String, _ call: @escaping () async throws -> MealPlanChangeResult) {
        working = true
        perform {
            defer { working = false }
            let result = try await call()
            if let body = result.undo { offer(MealPlanUndo(message: message, body: body)) }
            family.didChange(.mealPlan)
        }
    }

    private func renew(_ iteration: MealPlanIteration) {
        change(String(localized: "Plan refreshed")) {
            try await family.api.send(.post, "/meals/plan/iterations/\(iteration.id)/renew")
        }
    }

    private func next() {
        change(String(localized: "Next iteration started")) {
            try await family.api.send(.post, "/meals/plan/next")
        }
    }

    private func swap(_ entry: MealPlanEntry, to recipe: MealPlanRecipeOption) {
        change(String(localized: "\(recipe.title) is planned instead")) {
            try await family.api.send(.patch, "/meals/plan/entries/\(entry.id)", body: MealPlanSwapInput(recipeId: recipe.id))
        }
    }

    /// Puts a dragged recipe or meal onto `row`'s day; false when it changes nothing there.
    private func drop(_ item: MealDragItem, onto row: MealPlanDayRow, of iteration: MealPlanIteration) -> Bool {
        guard !working, let drop = MealPlanDrop(item, onto: row, of: iteration, familyID: family.family.id) else {
            return false
        }
        switch drop {
        case let .replace(entryID, recipeID, title):
            change(String(localized: "\(title) is planned instead")) {
                try await family.api.send(.patch, "/meals/plan/entries/\(entryID)", body: MealPlanSwapInput(recipeId: recipeID))
            }
        case let .add(iterationID, date, recipeID, title):
            change(String(localized: "\(title) planned for \(date.formatted())")) {
                try await family.api.send(.post, "/meals/plan/iterations/\(iterationID)/entries",
                                          body: MealPlanAddInput(date: date, recipeId: recipeID))
            }
        case let .move(entryID, date, title, swapped):
            change(swapped ? String(localized: "Meals swapped") : String(localized: "\(title) moved to \(date.formatted())")) {
                try await family.api.send(.post, "/meals/plan/entries/\(entryID)/move", body: MealPlanMoveInput(date: date))
            }
        }
        return true
    }

    private func remove(_ entry: MealPlanEntry) {
        change(String(localized: "Meal removed")) {
            try await family.api.send(.delete, "/meals/plan/entries/\(entry.id)")
        }
    }

    /// Shows the bar and registers the undo with the window's undo manager.
    private func offer(_ new: MealPlanUndo) {
        if let undo { expire(undo) }
        undo = new
        undoManager?.registerUndo(withTarget: new) { [self] target in
            take(target, fromManager: true)
        }
        undoManager?.setActionName(new.message)
    }

    /// The change can't be taken back any more.
    private func expire(_ old: MealPlanUndo) {
        undoManager?.removeAllActions(withTarget: old)
        if undo === old { undo = nil }
    }

    private func take(_ undo: MealPlanUndo, fromManager: Bool = false) {
        if !fromManager { undoManager?.removeAllActions(withTarget: undo) }
        if self.undo === undo { self.undo = nil }
        perform {
            try await family.api.perform(.post, "/meals/plan/restore", body: undo.body)
            family.didChange(.mealPlan)
        }
    }
}

/// What can be done with a day's meal.
enum MealPlanEntryAction {
    case open(MealPlanEntry)
    case cook(MealPlanEntry)
    case swap(MealPlanEntry)
    case remove(MealPlanEntry)
    /// The shopping list in Reminders (its settings).
    case shoppingSettings
}

/// One iteration: its days with lunch and dinner; past ones start folded.
struct MealPlanIterationCard: View {
    let iteration: MealPlanIteration
    let rows: [MealPlanDayRow]
    let archived: Bool
    let familyID: String
    let canEdit: Bool
    /// The shopping days' line about Reminders; nil: none (the demo).
    var shoppingLabel: String?
    let working: Bool
    var onRenew: () -> Void
    /// A recipe or meal dropped onto a day; whether it was used.
    var onDrop: (MealDragItem, MealPlanDayRow) -> Bool
    var onAction: (MealPlanEntryAction) -> Void

    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? !archived }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.vertical, 10)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        MealPlanDayRowView(row: row, isToday: row.day == .today, familyID: familyID, canEdit: canEdit,
                                           shoppingLabel: shoppingLabel, onDrop: { onDrop($0, row) }, onAction: onAction)
                        if row.id != rows.last?.id {
                            Divider().opacity(0.6)
                        }
                    }
                }
            }
        }
        .contentCard()
        .opacity(archived ? 0.85 : 1)
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.snappy) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: "\(iteration.startDate.formatted()) – \(iteration.endDate.formatted())")
                        .font(.headline)
                        .foregroundStyle(archived ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            Spacer()
            if !archived && canEdit {
                Button("Refresh", systemImage: "arrow.triangle.2.circlepath", action: onRenew)
                    .buttonStyle(.bordered)
                    .disabled(working)
                    .help("Plan these days again")
            }
        }
    }
}

/// A day of the plan: its date, the shopping list in Reminders on shopping days to come, lunch
/// (or away) and dinner.
/// "Lunch" and "Dinner" sit in a column as wide as the longer of them; at accessibility text
/// sizes above their meal. For editors the lunch can be dragged and the day takes a dropped
/// recipe or meal (outlined while one hovers it).
struct MealPlanDayRowView: View {
    let row: MealPlanDayRow
    let isToday: Bool
    let familyID: String
    let canEdit: Bool
    var shoppingLabel: String?
    var onDrop: (MealDragItem) -> Bool
    var onAction: (MealPlanEntryAction) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.day.formatted())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday ? ModuleTint.meals : .primary)
                if isToday {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ModuleTint.meals)
                }
                Spacer()
                if row.isShoppingDay {
                    Image(systemName: "cart")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Shopping day")
                }
            }
            if row.isShoppingDay, row.day >= .today, let shoppingLabel {
                Button { onAction(.shoppingSettings) } label: {
                    Label { Text(verbatim: shoppingLabel) } icon: { Image(systemName: "checklist") }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                        .chip(tint: .blue)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the shopping list’s settings"))
            }
            if row.isAway {
                Label("Away · \(row.awayTypes?.joined(separator: ", ") ?? "")", systemImage: "suitcase")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) { label(Text("Lunch")); lunch }
                    VStack(alignment: .leading, spacing: 2) { label(Text("Dinner")); dinner }
                }
                .font(.subheadline)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { label(Text("Lunch")); lunch }
                    GridRow { label(Text("Dinner")); dinner }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, isToday ? 10 : 0)
        .background {
            if isToday {
                RoundedRectangle(cornerRadius: 14).fill(ModuleTint.meals.opacity(0.12))
            }
        }
        .background {
            // Reaches past the row's edges where it has no padding of its own.
            if targeted {
                RoundedRectangle(cornerRadius: 14)
                    .fill(ModuleTint.meals.opacity(0.14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(ModuleTint.meals, lineWidth: 2) }
                    .padding(.horizontal, isToday ? 0 : -8)
            }
        }
        .animation(.snappy(duration: 0.15), value: targeted)
        .contentShape(.rect)
        .mealDropDestination(enabled: canEdit, action: onDrop) { targeted = $0 }
    }

    @ViewBuilder
    private var lunch: some View {
        if let entry = row.entry {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { onAction(.open(entry)) } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: entry.recipeTitle)
                            .fontWeight(entry.isLeftover ? .regular : .medium)
                            .italic(entry.isLeftover)
                            .foregroundStyle(entry.isLeftover ? .secondary : .primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if entry.isLeftover {
                            Text("(Leftover)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the recipe"))
                Menu {
                    actions(entry)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { actions(entry) }
            .mealDraggable(canEdit ? MealDragItem(familyID: familyID, recipeID: entry.recipeId,
                                                  title: entry.recipeTitle, entryID: entry.id) : nil)
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }

    private var dinner: some View {
        Text("Something light").foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actions(_ entry: MealPlanEntry) -> some View {
        Button("Open recipe", systemImage: "book") { onAction(.open(entry)) }
        Button("Cook", systemImage: "flame") { onAction(.cook(entry)) }
        if canEdit {
            Divider()
            Button("Swap…", systemImage: "arrow.left.arrow.right") { onAction(.swap(entry)) }
            Button("Remove", systemImage: "trash", role: .destructive) { onAction(.remove(entry)) }
        }
    }

    private func label(_ title: Text) -> some View {
        title
            .font(.caption.weight(.medium))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// "Meal removed · Undo", for a few seconds after a change.
struct MealPlanUndoBar: View {
    let undo: MealPlanUndo
    var action: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: undo.message)
                .font(.subheadline)
                .lineLimit(2)
            Button("Undo", action: action)
                .buttonStyle(.glassProminent)
                .tint(ModuleTint.meals)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { dismiss() }
        }
    }
}

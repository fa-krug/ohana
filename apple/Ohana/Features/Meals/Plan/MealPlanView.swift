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
/// by day (lunch with its recipe, leftovers, away days, shopping days with their lists), the
/// past ones folded, and for editors: setting the plan up, refreshing an iteration, starting the
/// next one, swapping or removing a meal (each undoable for a few seconds).
struct MealPlanView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.undoManager) private var undoManager
    @State private var state: LoadState<MealPlanResponse> = .idle
    @State private var showSetup = false
    @State private var shownRecipe: MealsRecipeRef?
    @State private var cooking: MealsRecipeRef?
    @State private var swapping: MealPlanEntry?
    @State private var confirmRenew: MealPlanIteration?
    @State private var undo: MealPlanUndo?
    @State private var working = false

    var body: some View {
        LoadStateView(state: state, retry: load) { data in
            content(data)
        }
        .navigationTitle("Meal plan")
        .toolbar {
            if family.canEdit, let data = state.value, data.plan != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Update plan", systemImage: "slider.horizontal.3") { showSetup = true }
                        .keyboardShortcut(",", modifiers: [.command, .shift])
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
            Text("The meals and shopping lists of these days are planned anew.")
        }
        .navigationDestination(item: $shownRecipe) {
            MealsRecipeDetailView(recipeID: $0.recipeID, initialServings: $0.servings)
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
        await LoadState.run($state) { try await family.api.get("/meals/plan") }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ data: MealPlanResponse) -> some View {
        if let plan = data.plan, !plan.iterations.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if family.canEdit, plan.activeEnded(today: .today) {
                        endedBanner
                    }
                    if let active = plan.activeIteration {
                        card(active, plan: plan, away: data.away, archived: false)
                    } else {
                        ContentUnavailableView {
                            Label("No active plan", systemImage: "calendar.badge.exclamationmark")
                        } description: {
                            Text("Time to plan your next round!")
                        } actions: {
                            if family.canEdit { nextButton }
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
                            card(iteration, plan: plan, away: data.away, archived: true)
                        }
                    }
                }
                .padding()
                .padding(.bottom, undo == nil ? 0 : 60)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        } else {
            ContentUnavailableView {
                Label("No meal plan yet", systemImage: "calendar.badge.plus")
            } description: {
                Text("Set up your first plan to get cooking!")
            } actions: {
                if family.canEdit {
                    Button("Let’s go!") { showSetup = true }
                        .buttonStyle(.glassProminent)
                        .tint(ModuleTint.meals)
                }
            }
        }
    }

    private func card(_ iteration: MealPlanIteration, plan: MealPlanDTO, away: [String: [String]], archived: Bool) -> some View {
        MealPlanIterationCard(
            iteration: iteration,
            rows: iteration.dayRows(shoppingDays: plan.shoppingDays, away: away),
            archived: archived,
            canEdit: family.canEdit,
            working: working,
            onRenew: { confirmRenew = iteration },
            onAction: { action in
                switch action {
                case let .open(entry): shownRecipe = MealsRecipeRef(recipeID: entry.recipeId, servings: entry.servings)
                case let .cook(entry): cooking = MealsRecipeRef(recipeID: entry.recipeId, servings: entry.servings)
                case let .swap(entry): swapping = entry
                case let .remove(entry): remove(entry)
                case let .shoppingList(id): family.open(.shoppingList(id: id))
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
        family.didChange(.mealPlan, .shopping)
        ErrorBanner.shared.success(String(localized: "Meal plan generated."))
    }

    private func change(_ message: String, _ call: @escaping () async throws -> MealPlanChangeResult) {
        working = true
        perform {
            defer { working = false }
            let result = try await call()
            if let body = result.undo { offer(MealPlanUndo(message: message, body: body)) }
            family.didChange(.mealPlan, .shopping)
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
            family.didChange(.mealPlan, .shopping)
        }
    }
}

/// What can be done with a day's meal.
enum MealPlanEntryAction {
    case open(MealPlanEntry)
    case cook(MealPlanEntry)
    case swap(MealPlanEntry)
    case remove(MealPlanEntry)
    case shoppingList(String)
}

/// One iteration: its days with lunch and dinner; past ones start folded.
struct MealPlanIterationCard: View {
    let iteration: MealPlanIteration
    let rows: [MealPlanDayRow]
    let archived: Bool
    let canEdit: Bool
    let working: Bool
    var onRenew: () -> Void
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
                        MealPlanDayRowView(row: row, isToday: row.day == .today, canEdit: canEdit, onAction: onAction)
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

/// A day of the plan: its date, the shopping list on shopping days, lunch (or away) and dinner.
/// "Lunch" and "Dinner" sit in a column as wide as the longer of them; at accessibility text
/// sizes above their meal.
struct MealPlanDayRowView: View {
    let row: MealPlanDayRow
    let isToday: Bool
    let canEdit: Bool
    var onAction: (MealPlanEntryAction) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

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
            if let list = row.shoppingList {
                Button { onAction(.shoppingList(list.id)) } label: {
                    Label("\(list.itemCount) items to grab", systemImage: "cart.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                        .chip(tint: .blue)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the shopping list"))
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

import SwiftUI

/// Meals → Shopping: the latest shopping list (as on the web's shopping page), with a switcher
/// to the family's other lists (one per shopping day of each plan iteration). `selection` picks
/// one (nil: the latest), e.g. a shopping day of the plan (`AppRoute.shoppingList`). The lists
/// are kept on the device: shown from there at once on a cold start, and while offline.
struct ShoppingListsView: View {
    @Environment(FamilyContext.self) private var family
    @Binding var selection: String?
    /// The saved overview shows as `.loaded`: the list page below says it's a copy (its badge or
    /// banner), so the two don't both say so.
    @State private var state: LoadState<ShoppingOverview> = .idle
    /// The overview shown is the copy kept on the device.
    @State private var savedCopy = false

    var body: some View {
        LoadStateView(state: state, retry: load) { overview in
            if let id = selection ?? overview.latest?.id {
                ShoppingListPage(listID: id, lists: overview.lists, latestID: overview.latest?.id) { selection = $0 }
            } else {
                ShoppingEmptyView()
            }
        }
        .navigationTitle("Shopping list")
        .task(id: [family.revision(.shopping), family.revision(.mealPlan)]) { await load() }
    }

    private func load() async {
        let store = ShoppingOfflineStore(api: family.api)
        if state.value == nil {
            if !family.api.client.isDemo, let saved = store.loadOverview() {
                state = .loaded(saved)
                savedCopy = true
            } else {
                state = .loading
            }
        }
        do {
            let overview: ShoppingOverview = try await family.api.get("/meals/shopping", query: ["lang": MealPlanLanguage.current])
            state = .loaded(overview)
            savedCopy = false
            store.saveOverview(overview)
            store.prune(keeping: Set(overview.lists.map(\.id)))
        } catch is CancellationError {
            return
        } catch {
            if ShoppingTickQueue.isRetryable(error), state.value == nil, let saved = store.loadOverview() {
                state = .loaded(saved)
                savedCopy = true
            } else if state.value == nil || (savedCopy && !ShoppingTickQueue.isRetryable(error)) {
                state = .failed(error.localizedDescription)
                savedCopy = false
            } else if !savedCopy {
                ErrorBanner.shared.show(error)
            }
        }
        // A list made new by the plan is gone: back to the latest.
        if let id = selection, let lists = state.value?.lists, !lists.contains(where: { $0.id == id }),
           !savedCopy || store.loadList(id) == nil {
            selection = nil
        }
    }
}

/// No list yet: lists come with the meal plan.
struct ShoppingEmptyView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView {
            Label("Nothing to shop for", systemImage: "cart")
        } description: {
            Text("Create a meal plan and we’ll sort it out for you!")
        } actions: {
            Button("Go to meal plan", systemImage: "calendar") { family.open(.mealPlan) }
                .buttonStyle(.glass)
        }
    }
}

/// One shopping list: its items by aisle, ticked off at once (sent in the background, queued
/// while offline), quantities, deleting (undoable for a few seconds) and adding items (File ▸
/// New Item, ⌘N; queued too while offline, shown with a clock until sent), and what the trip cost.
/// On iPad and Mac the family's lists are a strip above the items, and an item dragged onto
/// another list moves there (undoable for a few seconds).
struct ShoppingListPage: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.mealsOnScreen) private var onScreen
    @State private var deletes = MealsPendingDeletes.shared
    let listID: String
    /// The family's lists, for the switcher (empty: no switcher).
    var lists: [ShoppingListSummary] = []
    var latestID: String?
    var onSelect: ((String?) -> Void)?

    /// `.saved` (the quiet badge) while the copy kept on the device shows until the server answers;
    /// when it can't be reached the copy shows as `.loaded` with `savedCopy`, and the banner says
    /// so instead of the badge.
    @State private var state: LoadState<ShoppingList> = .idle
    /// The list shown is the copy kept on the device (no connection): ticks still work.
    @State private var savedCopy = false
    @State private var collapsed: Set<ShoppingCategory> = []
    @State private var editing: ShoppingItem?
    @State private var quantityText = ""
    @State private var showAdd = false
    @State private var confirmReset = false
    @State private var ticks = 0
    @State private var connectivity = Connectivity.shared
    /// Items being moved to another list: hidden until the list loaded without them.
    @State private var moving: Set<String> = []
    @State private var moveUndo: ShoppingMoveUndo?

    private var queue: ShoppingTickQueue { .for(family.api) }

    private struct LoadKey: Equatable {
        let listID: String
        let revision: Int
    }

    var body: some View {
        LoadStateView(state: state, retry: load) { list in
            content(list)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if showsStrip, let onSelect {
                ShoppingListStrip(lists: lists, shownID: listID, acceptsDrops: canMove) { id in
                    onSelect(id == latestID ? nil : id)
                } onDrop: { item, list in
                    drop(item, on: list)
                }
            }
        }
        .overlay(alignment: .bottom) {
            // Not while a delete's banner (MealsUndoBanner) is in its place; back after it.
            if let moveUndo, deletes.latest == nil {
                ShoppingMoveUndoBar(undo: moveUndo) { take(moveUndo) } dismiss: { expire(moveUndo) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: moveUndo?.id)
        .task(id: LoadKey(listID: listID, revision: family.revision(.shopping))) { await load() }
        .toolbar { toolbar }
        .focusedSceneValue(\.newItem, onScreen && canAdd
                           ? NewItemAction(title: "New Item") { showAdd = true } : nil)
        .alert("Quantity", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }),
               presenting: editing) { item in
            TextField("Quantity", text: $quantityText)
            Button("Save") { saveQuantity(of: item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(verbatim: "\(item.unitAbbreviation) \(item.ingredientName)")
        }
        .confirmationDialog("Untick every item?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset") { resetTicks() }
        }
        .sheet(isPresented: $showAdd) {
            ShoppingAddItemSheet(listID: listID, queueOnly: savedCopy || !connectivity.isOnline) {
                family.didChange(.shopping)
            }
        }
        .sensoryFeedback(.selection, trigger: ticks)
        .onChange(of: connectivity.isOnline) { _, online in
            // Back online: fresh lists instead of the saved copy (the queue sends the ticks).
            if online, savedCopy { family.didChange(.shopping) }
        }
        .onChange(of: queue.addsSettled) {
            // A queued add was sent (or refused): the server's list has it now.
            family.didChange(.shopping)
        }
    }

    /// Editing beyond ticking and adding needs the server.
    private var canChange: Bool { family.canEdit && !savedCopy && !state.isSaved }
    /// Adds wait in the queue while the server can't be reached (not in the demo: it's read-only).
    private var canAdd: Bool { family.canEdit && !family.api.client.isDemo && state.value != nil }

    /// The lists as a strip above the items (iPad, Mac), instead of the toolbar's menu.
    private var showsStrip: Bool { sizeClass != .compact && lists.count > 1 && onSelect != nil }

    /// Items can be dragged onto the strip's other lists.
    private var canMove: Bool { canChange && showsStrip }

    private func load() async {
        let store = ShoppingOfflineStore(api: family.api)
        if state.value?.id != listID {
            if !family.api.client.isDemo, let saved = store.savedList(listID) {
                state = .saved(saved.value, date: saved.date, updating: true)
            } else {
                state = .loading
            }
            savedCopy = false
        } else if case let .saved(list, date, _) = state {
            state = .saved(list, date: date, updating: true)
        }
        do {
            let response: ShoppingListResponse = try await family.api.get(
                "/meals/shopping/lists/\(listID)", query: ["lang": MealPlanLanguage.current])
            state = .loaded(response.list)
            savedCopy = false
            moving.formIntersection(response.list.items.map(\.id))
            store.saveList(response.list)
            queue.reconcile()
        } catch is CancellationError {
        } catch {
            if ShoppingTickQueue.isRetryable(error), let saved = state.isSaved ? state.value : store.loadList(listID) {
                state = .loaded(saved)
                savedCopy = true
            } else if state.value == nil || state.isSaved {
                state = .failed(error.localizedDescription)
            } else {
                ErrorBanner.shared.show(error)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ list: ShoppingList) -> some View {
        let items = visibleItems(of: list)
        if items.isEmpty {
            ContentUnavailableView {
                Label("Nothing to shop for", systemImage: "cart")
            } description: {
                Text("Create a meal plan and we’ll sort it out for you!")
            } actions: {
                if canAdd {
                    Button("Add item", systemImage: "plus") { showAdd = true }
                        .buttonStyle(.glassProminent)
                }
                Button("Go to meal plan", systemImage: "calendar") { family.open(.mealPlan) }
                    .buttonStyle(.bordered)
            }
        } else {
            List {
                summary(list, items: items)
                ForEach(ShoppingGrouping.groups(items)) { group in
                    categorySection(group)
                }
                // What it cost comes from the finances: not without them.
                if list.shoppingDate != nil, !savedCopy, !state.isSaved, family.isEnabled(.finance) {
                    ShoppingSpentSection(listID: list.id)
                }
            }
            .refreshable {
                queue.retryNow()
                await load()
            }
            .animation(.snappy, value: items)
            .safeAreaInset(edge: .top, spacing: 0) {
                ShoppingOfflineBanner(queue: queue, showsSavedCopy: savedCopy)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func summary(_ list: ShoppingList, items: [ShoppingItem]) -> some View {
        let checked = items.filter(\.isChecked).count
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let day = list.shoppingDate {
                        Label("Shopping for \(day.formatted())", systemImage: "cart")
                    } else {
                        Label("From your meal plan", systemImage: "cart")
                    }
                    Spacer()
                    Text("\(checked) of \(items.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                ProgressView(value: Double(checked), total: Double(max(items.count, 1)))
                    .tint(ModuleTint.meals)
            }
            .padding(.vertical, 4)
            if checked == items.count {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All done!").font(.headline)
                        Text("Everything on this list has been checked off")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Back to meal plan") { family.open(.mealPlan) }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func categorySection(_ group: ShoppingCategoryGroup) -> some View {
        let open = !collapsed.contains(group.category)
        return Section {
            if open {
                ForEach(group.items) { item in
                    row(item)
                }
            }
        } header: {
            Button {
                withAnimation(.snappy) {
                    if open { collapsed.insert(group.category) } else { collapsed.remove(group.category) }
                }
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Label(group.category.title, systemImage: group.category.systemImage)
                    Spacer()
                    Text("\(group.checkedCount) of \(group.items.count)")
                        .monospacedDigit()
                }
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
        }
    }

    @ViewBuilder
    private func row(_ item: ShoppingItem) -> some View {
        if let add = queue.pendingAdds(for: listID).first(where: { $0.item.id == item.id }) {
            pendingRow(add)
        } else {
            itemRow(item)
        }
    }

    /// An add waiting for the server: not tickable yet; it can be taken back until it's on its way.
    private func pendingRow(_ add: ShoppingPendingAdd) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(add.item.label())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Waiting to be sent"))
        .help("Waiting to be sent")
        .swipeActions(edge: .trailing) {
            if queue.sendingAddID != add.id {
                Button("Remove", systemImage: "trash", role: .destructive) { queue.removeAdd(add.id) }
            }
        }
        .contextMenu {
            if queue.sendingAddID != add.id {
                Button("Remove", systemImage: "trash", role: .destructive) { queue.removeAdd(add.id) }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ShoppingItem) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(item.isChecked ? AnyShapeStyle(ModuleTint.meals) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(item.label())
                .strikethrough(item.isChecked)
                .foregroundStyle(item.isChecked ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        if family.canEdit {
            Button { tick(item) } label: { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.isChecked ? .isSelected : [])
                .modifier(ShoppingItemDrag(item: canMove ? ShoppingItemDragItem(
                    familyID: family.family.id, itemID: item.id, listID: listID) : nil, label: item.label()))
                .swipeActions(edge: .trailing) {
                    if canChange {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
                        Button("Quantity", systemImage: "number") { startEditing(item) }
                            .tint(.orange)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button(item.isChecked ? "Untick" : "Tick", systemImage: item.isChecked ? "circle" : "checkmark") {
                        tick(item)
                    }
                    .tint(ModuleTint.meals)
                }
                .contextMenu {
                    Button(item.isChecked ? "Untick" : "Tick", systemImage: item.isChecked ? "circle" : "checkmark") {
                        tick(item)
                    }
                    if canChange {
                        Button("Change quantity", systemImage: "number") { startEditing(item) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
                    }
                }
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(item.isChecked ? .isSelected : [])
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if lists.count > 1, !showsStrip, let onSelect {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Shopping list", selection: Binding(get: { listID }, set: { id in
                        onSelect(id == latestID ? nil : id)
                    })) {
                        ForEach(lists) { list in
                            Text(verbatim: Self.title(of: list)).tag(list.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Lists", systemImage: "calendar")
                }
                .help("Lists")
            }
        }
        if let list = state.value {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: ShoppingExport.text(for: ShoppingList(id: list.id, shoppingDate: list.shoppingDate,
                                                                      createdAt: list.createdAt,
                                                                      items: visibleItems(of: list)))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if family.canEdit {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add item", systemImage: "plus") { showAdd = true }
                        .disabled(!canAdd)
                    Button("Reset", systemImage: "arrow.uturn.backward") { confirmReset = true }
                        .disabled(!visibleItems(of: list).contains(where: \.isChecked))
                        .help("Untick every item")
                }
            }
        }
    }

    private static func title(of list: ShoppingListSummary) -> String {
        let day = list.shoppingDate?.formatted() ?? "—"
        return "\(day) · \(list.checkedCount)/\(list.itemCount)"
    }

    // MARK: Actions

    /// The items with their ticks, without those being deleted or moved, and the adds waiting to
    /// be sent.
    private func visibleItems(of list: ShoppingList) -> [ShoppingItem] {
        queue.apply(to: list.items).filter { !deletes.isHidden($0.id) && !moving.contains($0.id) }
            + queue.pendingAdds(for: list.id).map(\.item)
    }

    private func tick(_ item: ShoppingItem) {
        queue.set(item.id, checked: !item.isChecked)
        ticks += 1
    }

    private func resetTicks() {
        guard let list = state.value else { return }
        for item in visibleItems(of: list) where item.isChecked {
            queue.set(item.id, checked: false)
        }
        ticks += 1
    }

    private func startEditing(_ item: ShoppingItem) {
        quantityText = ShoppingQuantity.format(item.quantity)
        editing = item
    }

    private func saveQuantity(of item: ShoppingItem) {
        let quantity = quantityText.trimmingCharacters(in: .whitespaces).replacing(",", with: ".")
        perform {
            try await family.api.perform(.patch, "/meals/shopping/items/\(item.id)",
                                         body: ShoppingQuantityInput(quantity: quantity))
            family.didChange(.shopping)
        }
    }

    /// Hidden at once, deleted after a few seconds unless undone (the bar's Undo, ⌘Z).
    private func delete(_ item: ShoppingItem) {
        withAnimation {
            deletes.schedule(item.id, kind: .shoppingItem, title: item.label(), family: family, undoManager: undoManager)
        }
    }

    // MARK: Moving

    /// An item dropped on a list of the strip.
    private func drop(_ item: ShoppingItemDragItem, on list: ShoppingListSummary) -> Bool {
        guard canMove, ShoppingMove.accepts(item, onto: list.id, familyID: family.family.id) else { return false }
        move(item, to: list)
        return true
    }

    /// Hidden at once, moved on the server; undoable for a few seconds (the bar's Undo, ⌘Z).
    private func move(_ item: ShoppingItemDragItem, to list: ShoppingListSummary) {
        let request = ShoppingMove.request(item, to: list.id)
        let message = list.shoppingDate.map { String(localized: "Moved to \($0.formatted())") }
            ?? String(localized: "Moved to another list")
        let title = state.value?.items.first { $0.id == item.itemID }?.label()
        moving.insert(item.itemID)
        perform {
            do {
                let result: ShoppingMoveResult = try await family.api.send(.post, request.path, body: request.input)
                offer(ShoppingMoveUndo(message: message, title: title, request: ShoppingMove.undo(of: result)))
            } catch {
                moving.remove(item.itemID)
                throw error
            }
            family.didChange(.shopping)
        }
    }

    /// Shows the bar and registers the undo with the window's undo manager.
    private func offer(_ new: ShoppingMoveUndo) {
        if let moveUndo { expire(moveUndo) }
        moveUndo = new
        undoManager?.registerUndo(withTarget: new) { [self] target in
            take(target, fromManager: true)
        }
        undoManager?.setActionName(String(localized: "Move Item"))
    }

    /// The move can't be taken back any more.
    private func expire(_ old: ShoppingMoveUndo) {
        undoManager?.removeAllActions(withTarget: old)
        if moveUndo === old { moveUndo = nil }
    }

    private func take(_ undo: ShoppingMoveUndo, fromManager: Bool = false) {
        if !fromManager { undoManager?.removeAllActions(withTarget: undo) }
        if moveUndo === undo { moveUndo = nil }
        moving.remove(undo.request.itemID)
        perform {
            let _: ShoppingMoveResult = try await family.api.send(.post, undo.request.path, body: undo.request.input)
            family.didChange(.shopping)
        }
    }
}

/// A move to another list that can be taken back for a few seconds.
final class ShoppingMoveUndo: Identifiable {
    let id = UUID()
    let message: String
    /// The item's label, when it was on the list shown.
    let title: String?
    let request: ShoppingMoveRequest

    init(message: String, title: String?, request: ShoppingMoveRequest) {
        self.message = message
        self.title = title
        self.request = request
    }
}

/// "Moved to Thu, 5 Nov · Undo", for a few seconds after a move.
struct ShoppingMoveUndoBar: View {
    let undo: ShoppingMoveUndo
    var action: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: undo.message).font(.callout.weight(.semibold))
                if let title = undo.title {
                    Text(verbatim: title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Undo", action: action)
                .buttonStyle(.glassProminent)
                .tint(ModuleTint.meals)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 440)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { dismiss() }
        }
    }
}

/// The family's lists side by side above the items (iPad, Mac): shopping day and how much is
/// ticked off, the shown one highlighted. A tap shows a list; an item dropped on another list
/// moves there.
struct ShoppingListStrip: View {
    let lists: [ShoppingListSummary]
    let shownID: String
    /// Items can be dropped on the other lists.
    let acceptsDrops: Bool
    var onSelect: (String) -> Void
    var onDrop: (ShoppingItemDragItem, ShoppingListSummary) -> Bool

    /// The list a dragged item is over.
    @State private var targeted: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(lists) { list in
                        chip(list).id(list.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(shownID) }
            .onChange(of: shownID) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
    }

    @ViewBuilder
    private func chip(_ list: ShoppingListSummary) -> some View {
        let shown = list.id == shownID
        let over = targeted == list.id
        let button = Button { onSelect(list.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: list.shoppingDate?.formatted() ?? "—")
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: "\(list.checkedCount)/\(list.itemCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cardBackground)
                    .overlay {
                        if shown || over {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(ModuleTint.meals.opacity(over ? 0.3 : 0.15))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(over || shown ? ModuleTint.meals : .clear, lineWidth: over ? 2 : 1)
            }
            .scaleEffect(over ? 1.06 : 1)
            .animation(.snappy, value: over)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: list.shoppingDate?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? "—"))
        .accessibilityValue(Text("\(list.checkedCount) of \(list.itemCount)"))
        .accessibilityAddTraits(shown ? .isSelected : [])
        if acceptsDrops, !shown {
            button
                .dropDestination(for: ShoppingItemDragItem.self) { items, _ in
                    targeted = nil
                    guard let item = items.first else { return false }
                    return onDrop(item, list)
                } isTargeted: { isOver in
                    if isOver { targeted = list.id } else if targeted == list.id { targeted = nil }
                }
        } else {
            button
        }
    }
}

/// Makes an item's row draggable onto another list (nil: not), with the item as a chip.
private struct ShoppingItemDrag: ViewModifier {
    let item: ShoppingItemDragItem?
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let item {
            content.draggable(item) {
                Label(label, systemImage: "cart")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.cardBackground, in: .capsule)
                    .contentShape(.dragPreview, .capsule)
            }
        } else {
            content
        }
    }
}

/// Meals → Finance: what the shopping trip cost, from the groceries transactions of the list's
/// shopping day ± 1 day (read-only, like the web's spent card).
struct ShoppingSpentSection: View {
    @Environment(FamilyContext.self) private var family
    let listID: String
    @State private var spend: ShoppingSpend?
    @State private var failed: String?

    private struct LoadKey: Equatable {
        let listID: String
        let finance: Int
        let shopping: Int
    }

    var body: some View {
        Section {
            if let spend {
                if spend.category == nil {
                    Text("Ohana shows here what this shopping trip cost, from the finances’ groceries category.")
                        .foregroundStyle(.secondary)
                    Button("Choose the groceries category", systemImage: "gearshape") {
                        family.open(.settings(.finance))
                    }
                } else if spend.transactions.isEmpty {
                    Text("No transactions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(spend.transactions) { tx in
                        HStack(spacing: 12) {
                            Text(tx.date.formatted())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(verbatim: tx.payee.isEmpty ? (tx.description.isEmpty ? "—" : tx.description) : tx.payee)
                                .lineLimit(1)
                            Spacer()
                            Text(money(tx.amountCents, spend.currency))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            } else if let failed {
                Text(failed).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            HStack {
                Label("Spent", systemImage: "creditcard")
                Spacer()
                if let spend, !spend.transactions.isEmpty {
                    Text(money(spend.totalCents, spend.currency))
                        .monospacedDigit()
                }
            }
            // On the header, not the section: modifiers of a section go to each of its rows.
            .task(id: LoadKey(listID: listID, finance: family.revision(.finance), shopping: family.revision(.shopping))) {
                await load()
            }
        } footer: {
            if let spend, let category = spend.category {
                let name = category.icon.isEmpty ? category.name : "\(category.icon) \(category.name)"
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(name) in your finances, \(spend.from.formatted()) – \(spend.to.formatted())")
                    Button("Open finance") { family.open(.financeTransactions(categoryID: category.id)) }
                        .buttonStyle(.borderless)
                        .font(.footnote.weight(.medium))
                }
            }
        }
    }

    private func load() async {
        do {
            spend = try await family.api.get("/meals/shopping/lists/\(listID)/spent")
            failed = nil
        } catch is CancellationError {
        } catch {
            failed = error.localizedDescription
        }
    }

    private func money(_ cents: Int, _ currency: String) -> String {
        Money.format(Decimal(cents) / 100, currency: currency)
    }
}

/// Adds an item to a list: an ingredient Ohana knows (by its English or German name) or a new
/// one; an open item of the same ingredient and unit gets the quantity added. While the server
/// can't be reached the add waits in the list's queue (`ShoppingTickQueue`).
struct ShoppingAddItemSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let listID: String
    /// Offline, or the list shown is the saved copy: queue the add without trying first.
    var queueOnly = false
    /// The server has the add (not called for a queued one: the queue reloads the list once sent).
    var onAdded: () -> Void

    @State private var name = ""
    @State private var quantity = "1"
    @State private var unitID: Int?
    @State private var category: ShoppingCategory = .other
    @State private var units: [ShoppingUnit] = []
    /// The unit picked for the user when the units came.
    @State private var defaultUnitID: Int?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    private var quantityValue: Double? {
        Double(quantity.trimmingCharacters(in: .whitespaces).replacing(",", with: "."))
    }

    private var hasChanges: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || quantity != "1" || category != .other
            || unitID != defaultUnitID
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (quantityValue ?? 0) > 0 && unitID != nil && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.next)
                    TextField("Quantity", text: $quantity)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Picker("Unit", selection: $unitID) {
                        ForEach(units) { unit in
                            Text(verbatim: "\(unit.abbreviation) · \(unit.name)").tag(Optional(unit.id))
                        }
                    }
                } footer: {
                    if quantityValue.map({ $0 <= 0 }) ?? !quantity.isEmpty {
                        Text("The quantity must be a number above 0.")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Aisle", selection: $category) {
                        ForEach(ShoppingCategory.allCases) { category in
                            Label(category.title, systemImage: category.systemImage).tag(category)
                        }
                    }
                } footer: {
                    Text("For a new ingredient; one Ohana knows keeps its own aisle.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark", role: .confirm) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .task { await loadUnits() }
            .onAppear { nameFocused = true }
            .onSubmit { if canSave { save() } }
        }
        .errorBanner()
        .discardGuard(hasChanges: hasChanges || saving)
        .presentationDetents([.medium, .large])
    }

    private func loadUnits() async {
        do {
            // The units as last loaded while offline.
            let response = try await family.api.cached("/meals/shopping/units", as: ShoppingUnitsResponse.self)
                .fetchOrSaved()
            units = response.units
            if unitID == nil {
                unitID = (units.first { $0.abbreviation == "Stk" } ?? units.first)?.id
                defaultUnitID = unitID
            }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    private func save() {
        guard let unitID, let value = quantityValue, let unit = units.first(where: { $0.id == unitID }) else { return }
        saving = true
        let add = ShoppingPendingAdd(listID: listID, name: name.trimmingCharacters(in: .whitespaces),
                                     quantity: String(value), unitID: unitID, unitAbbreviation: unit.abbreviation,
                                     category: category.rawValue)
        perform {
            defer { saving = false }
            if try await ShoppingTickQueue.for(family.api).add(add, sendNow: !queueOnly) { onAdded() }
            dismiss()
        }
    }
}

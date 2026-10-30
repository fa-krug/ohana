import SwiftUI

/// Meals → Shopping: the latest shopping list (as on the web's shopping page), with a switcher
/// to the family's other lists (one per shopping day of each plan iteration).
struct ShoppingListsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<ShoppingOverview> = .idle
    @State private var selectedID: String?

    var body: some View {
        LoadStateView(state: state, retry: load) { overview in
            if let id = selectedID ?? overview.latest?.id {
                ShoppingListPage(listID: id, lists: overview.lists, latestID: overview.latest?.id) { selectedID = $0 }
            } else {
                ShoppingEmptyView()
            }
        }
        .navigationTitle("Shopping list")
        .task(id: [family.revision(.shopping), family.revision(.mealPlan)]) { await load() }
    }

    private func load() async {
        await LoadState.run($state) {
            try await family.api.get("/meals/shopping", query: ["lang": MealPlanLanguage.current])
        }
        // A list made new by the plan is gone: back to the latest.
        if let id = selectedID, let lists = state.value?.lists, !lists.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }
}

/// A shopping list pushed from elsewhere (the meal plan's shopping days).
struct ShoppingListDetailView: View {
    let listID: String

    var body: some View {
        ShoppingListPage(listID: listID)
            .navigationTitle("Shopping list")
    }
}

/// No list yet: lists come with the meal plan.
struct ShoppingEmptyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing to shop for", systemImage: "cart")
        } description: {
            Text("Create a meal plan and we’ll sort it out for you!")
        }
    }
}

/// One shopping list: its items by aisle, ticked off at once (sent in the background, queued
/// while offline), quantities, deleting and adding items, and what the trip cost.
struct ShoppingListPage: View {
    @Environment(FamilyContext.self) private var family
    let listID: String
    /// The family's lists, for the switcher (empty: no switcher).
    var lists: [ShoppingListSummary] = []
    var latestID: String?
    var onSelect: ((String?) -> Void)?

    @State private var state: LoadState<ShoppingList> = .idle
    @State private var collapsed: Set<ShoppingCategory> = []
    @State private var editing: ShoppingItem?
    @State private var quantityText = ""
    @State private var showAdd = false
    @State private var confirmReset = false
    @State private var ticks = 0

    private var queue: ShoppingTickQueue { .for(family.api) }

    private struct LoadKey: Equatable {
        let listID: String
        let revision: Int
    }

    var body: some View {
        LoadStateView(state: state, retry: load) { list in
            content(list)
        }
        .task(id: LoadKey(listID: listID, revision: family.revision(.shopping))) { await load() }
        .toolbar { toolbar }
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
            ShoppingAddItemSheet(listID: listID) { family.didChange(.shopping) }
        }
        .sensoryFeedback(.selection, trigger: ticks)
    }

    private func load() async {
        await LoadState.run($state) {
            let response: ShoppingListResponse = try await family.api.get(
                "/meals/shopping/lists/\(listID)", query: ["lang": MealPlanLanguage.current])
            return response.list
        }
        queue.reconcile()
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ list: ShoppingList) -> some View {
        let items = queue.apply(to: list.items)
        if items.isEmpty {
            ContentUnavailableView {
                Label("Nothing to shop for", systemImage: "cart")
            } description: {
                Text("Create a meal plan and we’ll sort it out for you!")
            } actions: {
                if family.canEdit {
                    Button("Add item", systemImage: "plus") { showAdd = true }
                        .buttonStyle(.glassProminent)
                }
            }
        } else {
            List {
                summary(list, items: items)
                ForEach(ShoppingGrouping.groups(items)) { group in
                    categorySection(group)
                }
                if list.shoppingDate != nil {
                    ShoppingSpentSection(listID: list.id)
                }
            }
            .refreshable {
                queue.retryNow()
                await load()
            }
            .animation(.snappy, value: items)
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
                }
                .padding(.vertical, 4)
            }
            if queue.isWaiting {
                Label("Ticks are sent when the connection is back.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                    Label(group.category.title, systemImage: group.category.systemImage)
                    Spacer()
                    Text("\(group.checkedCount) of \(group.items.count)")
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func row(_ item: ShoppingItem) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(item.isChecked ? AnyShapeStyle(ModuleTint.meals) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
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
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
                    Button("Quantity", systemImage: "number") { startEditing(item) }
                        .tint(.orange)
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
                    Button("Change quantity", systemImage: "number") { startEditing(item) }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(item) }
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
        if lists.count > 1, let onSelect {
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
                                                                      items: queue.apply(to: list.items)))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if family.canEdit {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add item", systemImage: "plus") { showAdd = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Reset", systemImage: "arrow.uturn.backward") { confirmReset = true }
                        .disabled(!queue.apply(to: list.items).contains(where: \.isChecked))
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

    private func tick(_ item: ShoppingItem) {
        queue.set(item.id, checked: !item.isChecked)
        ticks += 1
    }

    private func resetTicks() {
        guard let list = state.value else { return }
        for item in queue.apply(to: list.items) where item.isChecked {
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

    private func delete(_ item: ShoppingItem) {
        if case var .loaded(list) = state {
            list.items.removeAll { $0.id == item.id }
            state = .loaded(list)
        }
        perform {
            defer { family.didChange(.shopping) }
            try await family.api.perform(.delete, "/meals/shopping/items/\(item.id)")
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
                    Text("Choose the groceries category in Settings → Finance.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                Text("\(name) in your finances, \(spend.from.formatted()) – \(spend.to.formatted())")
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
/// one; an open item of the same ingredient and unit gets the quantity added.
struct ShoppingAddItemSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let listID: String
    var onAdded: () -> Void

    @State private var name = ""
    @State private var quantity = "1"
    @State private var unitID: Int?
    @State private var category: ShoppingCategory = .other
    @State private var units: [ShoppingUnit] = []
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    private var quantityValue: Double? {
        Double(quantity.trimmingCharacters(in: .whitespaces).replacing(",", with: "."))
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
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!canSave)
                }
            }
            .task { await loadUnits() }
            .onAppear { nameFocused = true }
            .onSubmit { if canSave { save() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadUnits() async {
        do {
            let response: ShoppingUnitsResponse = try await family.api.get("/meals/shopping/units")
            units = response.units
            if unitID == nil {
                unitID = (units.first { $0.abbreviation == "Stk" } ?? units.first)?.id
            }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    private func save() {
        guard let unitID, let value = quantityValue else { return }
        saving = true
        let input = ShoppingAddItemInput(name: name.trimmingCharacters(in: .whitespaces),
                                         quantity: String(value), unitId: unitID, category: category.rawValue)
        perform {
            defer { saving = false }
            let _: ShoppingAddItemResult = try await family.api.send(.post, "/meals/shopping/lists/\(listID)/items",
                                                                     body: input)
            onAdded()
            dismiss()
        }
    }
}

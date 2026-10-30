import SwiftUI

/// Settings → Finance (web/components/finance/finance-settings.tsx): currency, the groceries
/// category, accounts, nested categories, the statistic average, saved bank formats, and
/// deleting all finance data. Viewers see it all, read-only.
struct FinanceSettingsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var store: FinanceStore?

    var body: some View {
        Group {
            if let store, store.family === family {
                FinanceSettingsForm(store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ohanaBackground(ModuleTint.finance)
        .navigationTitle("Finance")
        .task(id: ObjectIdentifier(family)) {
            if store?.family !== family { store = FinanceStore(family: family) }
        }
    }
}

private enum FinanceSettingsSheet: Identifiable {
    case newAccount, account(FinanceAccount), newCategory(parent: FinanceCategory?), category(FinanceCategory)

    var id: String {
        switch self {
        case .newAccount: "new-account"
        case let .account(a): "account-" + a.id
        case let .newCategory(parent): "new-category-" + (parent?.id ?? "")
        case let .category(c): "category-" + c.id
        }
    }
}

struct FinanceSettingsForm: View {
    @Bindable var store: FinanceStore
    @Environment(FamilyContext.self) private var family
    @State private var sheet: FinanceSettingsSheet?
    @State private var deletingCategory: FinanceCategory?
    @State private var deletingAccount: FinanceAccount?
    @State private var clearing = false

    static let currencies = ["EUR", "USD", "GBP", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "JPY", "CAD", "AUD"]

    var body: some View {
        Group {
            if store.overview != nil {
                form
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await store.loadOverview() } }.buttonStyle(.glassProminent)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: family.revision(.finance)) { await store.openSettings(family.revision(.finance)) }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newAccount: FinanceAccountEditor(store: store, account: nil)
            case let .account(a): FinanceAccountEditor(store: store, account: a)
            case let .newCategory(parent): FinanceCategoryEditor(store: store, category: nil, parent: parent)
            case let .category(c): FinanceCategoryEditor(store: store, category: c, parent: nil)
            }
        }
        .confirmationDialog(deletingCategory.map { String(localized: "Delete the category “\($0.name)”?") } ?? "",
                            isPresented: Binding { deletingCategory != nil } set: { if !$0 { deletingCategory = nil } },
                            titleVisibility: .visible, presenting: deletingCategory) { c in
            Button("Delete", role: .destructive) { Task { await store.deleteCategory(c.id) } }
        } message: { c in
            if let parent = store.tree.parent(of: c.id) {
                Text("Its transactions and subcategories move to “\(parent.name)”.")
            } else {
                Text("Its transactions stay, without a category. Its subcategories move up to the top level.")
            }
        }
        .confirmationDialog(deletingAccount.map { String(localized: "Delete the account “\($0.name)”?") } ?? "",
                            isPresented: Binding { deletingAccount != nil } set: { if !$0 { deletingAccount = nil } },
                            titleVisibility: .visible, presenting: deletingAccount) { a in
            Button("Delete", role: .destructive) { Task { await store.deleteAccount(a.id) } }
        } message: { _ in
            Text("All its transactions are deleted as well. This can’t be undone.")
        }
        .confirmationDialog("Delete all finance data?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Delete all finance data", role: .destructive) { Task { await store.clearAll() } }
        } message: {
            Text("All transactions, accounts, categories and saved bank formats are deleted for everyone in this family. This can’t be undone.")
        }
    }

    private var form: some View {
        Form {
            if !store.canEdit {
                Section {
                    Label("You can look at the finances; only editors can change them.", systemImage: "eye")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Currency") {
                Picker("Currency", selection: Binding { store.currency } set: { c in Task { await store.setCurrency(c) } }) {
                    ForEach(Array(Set([store.currency] + Self.currencies)).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .disabled(!store.canEdit)
            }
            groceries
            accounts
            categories
            Section {
                NavigationLink {
                    FinanceBenchmarkEditor(store: store)
                } label: {
                    LabeledContent("Statistic average") {
                        Text(store.overview?.benchmark.map { $0.label.isEmpty ? String(localized: "Set, without a source") : $0.label }
                             ?? String(localized: "Not set"))
                    }
                }
            } footer: {
                Text("Figures the overview measures your months against, e.g. household spending according to the statistics office.")
            }
            if store.canEdit {
                mappings
                Section {
                    Button("Delete all finance data", systemImage: "trash", role: .destructive) { clearing = true }
                } header: {
                    Text("Danger zone")
                } footer: {
                    Text("Deletes all transactions, accounts, categories and saved bank formats of this family and resets the currency. The calendar stays as it is.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var groceries: some View {
        Section {
            Picker("Groceries category", selection: Binding { store.overview?.groceriesCategoryId } set: { id in
                Task { await store.setGroceriesCategory(id) }
            }) {
                Text(store.defaultGroceries.map { String(localized: "Automatic: \($0.label)") }
                     ?? String(localized: "Automatic (a category called Groceries)"))
                    .tag(String?.none)
                ForEach(store.tree.ordered.filter { $0.category.kind != .income }) { node in
                    Text(node.depth == 0 ? node.category.label : store.tree.path(node.id)).tag(Optional(node.id))
                }
            }
            .disabled(!store.canEdit)
        } header: {
            Text("Groceries")
        } footer: {
            Text("The category of your grocery shopping (with its subcategories): a shopping list shows what was spent in it on the shopping day (± 1 day), and those transactions link to the list.")
        }
    }

    private var accounts: some View {
        Section {
            if store.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, a in
                Button {
                    sheet = .account(a)
                } label: {
                    HStack(spacing: 10) {
                        FinanceColorDot(hex: a.color, size: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.label).foregroundStyle(.primary)
                            Text("Opening balance \(store.money(a.openingCents))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.money(a.balanceCents))
                            .monospacedDigit()
                            .foregroundStyle(a.balanceCents < 0 ? .red : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if store.canEdit {
                        Button("Move up", systemImage: "arrow.up") { Task { await store.moveAccount(a.id, by: -1) } }
                            .disabled(i == 0)
                        Button("Move down", systemImage: "arrow.down") { Task { await store.moveAccount(a.id, by: 1) } }
                            .disabled(i == store.accounts.count - 1)
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingAccount = a }
                    }
                }
                .swipeActions {
                    if store.canEdit {
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingAccount = a }
                    }
                }
            }
            if store.canEdit {
                Button("Add account", systemImage: "plus") { sheet = .newAccount }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Your bank accounts, cash or cards. A transaction can belong to one; the balance is the opening balance plus all its transactions.")
        }
    }

    private var categories: some View {
        Section {
            ForEach(store.tree.ordered) { node in
                categoryRow(node)
            }
            if store.canEdit {
                Button("Add category", systemImage: "plus") { sheet = .newCategory(parent: nil) }
                Button("Add default categories", systemImage: "square.stack.3d.down.right") {
                    Task { await store.addDefaultCategories() }
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("To sort the transactions. Income categories show for money coming in, expense categories for money going out, “both” for both. Categories can have subcategories, as deep as you like: a subcategory has the kind of its top-level category, and a category’s totals include its subcategories.")
        }
    }

    private func categoryRow(_ node: FinanceCategoryTree.Node) -> some View {
        let c = node.category
        let siblings = store.tree.children(of: store.tree.parent(of: c.id)?.id)
        let index = siblings.firstIndex { $0.id == c.id } ?? 0
        return Button {
            sheet = .category(c)
        } label: {
            HStack(spacing: 8) {
                if node.depth > 0 {
                    Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                }
                FinanceColorDot(hex: c.color, size: 12)
                Text(c.label).foregroundStyle(.primary)
                Spacer()
                if node.depth == 0 {
                    Text(c.kind.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(min(node.depth, 6)) * 18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if store.canEdit {
                Button("Add subcategory", systemImage: "plus") { sheet = .newCategory(parent: c) }
                Button("Move up", systemImage: "arrow.up") { Task { await store.moveCategory(c.id, by: -1) } }
                    .disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") { Task { await store.moveCategory(c.id, by: 1) } }
                    .disabled(index == siblings.count - 1)
                Menu("Move to", systemImage: "arrow.turn.down.right") {
                    Button("Top level") { Task { await store.updateCategory(c.id, ["parentId": .null]) } }
                        .disabled(c.parentId == nil)
                    Divider()
                    ForEach(store.tree.moveTargets(for: c.id)) { target in
                        Button(String(repeating: "   ", count: min(target.depth, 6)) + target.category.label) {
                            Task { await store.updateCategory(c.id, ["parentId": .string(target.id)]) }
                        }
                        .disabled(target.id == c.parentId)
                    }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { deletingCategory = c }
            }
        }
        .swipeActions {
            if store.canEdit {
                Button("Delete", systemImage: "trash", role: .destructive) { deletingCategory = c }
            }
        }
    }

    private var mappings: some View {
        Section {
            let saved = store.overview?.mappings ?? []
            if saved.isEmpty {
                Text("None yet: the import remembers the format of a bank’s files.").foregroundStyle(.secondary)
            }
            ForEach(saved, id: \.signature) { m in
                HStack {
                    Text(m.signature)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                    Spacer()
                    Button {
                        Task { await store.deleteMapping(m.signature) }
                    } label: {
                        Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Saved bank formats")
        } footer: {
            Text("How the columns of a bank’s CSV files map, recognized by the header row. Remove one to set it up anew at the next import.")
        }
    }
}

// MARK: Editors

/// An account's name, icon, color and opening balance.
struct FinanceAccountEditor: View {
    @Bindable var store: FinanceStore
    let account: FinanceAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = ""
    @State private var color = Color.blue
    @State private var opening = ""
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Icon (an emoji)", text: $icon)
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                }
                .disabled(!store.canEdit)
                Section {
                    LabeledContent {
                        TextField("Opening balance", text: $opening, prompt: Text(FinanceMoney.placeholder))
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    } label: {
                        Text("Opening balance (\(store.currency))")
                    }
                    .disabled(!store.canEdit)
                    if let account {
                        LabeledContent("Balance", value: store.money(account.balanceCents))
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(account == nil ? String(localized: "New account") : String(localized: "Account"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(store.canEdit ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() } }
                if store.canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }.disabled(busy)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .financeSheetFrame(minWidth: 400, minHeight: 360)
        .onAppear {
            name = account?.name ?? String(localized: "Account \(store.accounts.count + 1)")
            icon = account?.icon ?? ""
            color = FinanceColor.color(account?.color ?? FinanceColor.next(used: store.accounts.map(\.color)))
            opening = account.map { FinanceMoney.signedInput($0.openingCents) } ?? ""
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { problem = String(localized: "Enter a name."); return }
        let cents = opening.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : FinanceMoney.parse(opening)
        guard let cents else { problem = String(localized: "Enter an amount, e.g. \(FinanceMoney.input(1250))"); return }
        let hex = FinanceColor.hex(color)
        let iconText = String(icon.trimmingCharacters(in: .whitespaces).prefix(8))
        busy = true
        if let account {
            var patch: [String: JSONValue] = [:]
            if trimmed != account.name { patch["name"] = .string(trimmed) }
            if iconText != account.icon { patch["icon"] = .string(iconText) }
            if hex != account.color.lowercased() { patch["color"] = .string(hex) }
            if cents != account.openingCents { patch["openingCents"] = FinanceJSON.int(cents) }
            if !patch.isEmpty { await store.updateAccount(account.id, patch) }
        } else {
            await store.addAccount(name: trimmed, color: hex, icon: iconText, openingCents: cents)
        }
        busy = false
        dismiss()
    }
}

/// A category's name, icon, color, kind (top level only) and place in the tree.
struct FinanceCategoryEditor: View {
    @Bindable var store: FinanceStore
    let category: FinanceCategory?
    let parent: FinanceCategory?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = ""
    @State private var color = Color.blue
    @State private var kind = FinanceCategoryKind.expense
    @State private var parentId: String?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Icon (an emoji)", text: $icon)
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                }
                Section {
                    Picker("Parent", selection: $parentId) {
                        Text("Top level").tag(String?.none)
                        ForEach(category.map { store.tree.moveTargets(for: $0.id) } ?? store.tree.ordered) { node in
                            Text(String(repeating: "   ", count: min(node.depth, 6)) + node.category.label).tag(Optional(node.id))
                        }
                    }
                    if parentId == nil {
                        Picker("Kind", selection: $kind) {
                            ForEach(FinanceCategoryKind.allCases) { Text($0.title).tag($0) }
                        }
                    } else if let top = store.category(store.tree.top(of: parentId)) {
                        LabeledContent("Kind", value: top.kind.title)
                    }
                } footer: {
                    Text("A subcategory has the kind of its top-level category.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .disabled(!store.canEdit)
            .formStyle(.grouped)
            .navigationTitle(category == nil ? String(localized: "New category") : String(localized: "Category"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(store.canEdit ? String(localized: "Cancel") : String(localized: "Done")) { dismiss() } }
                if store.canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }.disabled(busy)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .financeSheetFrame(minWidth: 400, minHeight: 380)
        .onAppear {
            if let category {
                name = category.name
                icon = category.icon
                color = FinanceColor.color(category.color)
                kind = category.kind
                parentId = category.parentId
            } else {
                name = String(localized: "Category \(store.categories.count + 1)")
                color = FinanceColor.color(parent?.color ?? FinanceColor.next(used: store.categories.map(\.color)))
                kind = parent?.kind ?? .expense
                parentId = parent?.id
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { problem = String(localized: "Enter a name."); return }
        let hex = FinanceColor.hex(color)
        let iconText = String(icon.trimmingCharacters(in: .whitespaces).prefix(8))
        busy = true
        if let category {
            var patch: [String: JSONValue] = [:]
            if trimmed != category.name { patch["name"] = .string(trimmed) }
            if iconText != category.icon { patch["icon"] = .string(iconText) }
            if hex != category.color.lowercased() { patch["color"] = .string(hex) }
            if parentId != category.parentId { patch["parentId"] = FinanceJSON.string(parentId) }
            if parentId == nil && kind != category.kind { patch["kind"] = .string(kind.rawValue) }
            if !patch.isEmpty { await store.updateCategory(category.id, patch) }
        } else {
            await store.addCategory(name: trimmed, parent: store.category(parentId), kind: kind, color: hex, icon: iconText)
        }
        busy = false
        dismiss()
    }
}

/// The statistic average the overview compares with: a source, and ranges per month (from – to;
/// one end alone is a single value) for income, expenses and the top-level categories. Ranges
/// set on subcategories (through the API) stay as they are.
struct FinanceBenchmarkEditor: View {
    @Bindable var store: FinanceStore
    @State private var label = ""
    @State private var income = FinanceRangeDraft()
    @State private var expense = FinanceRangeDraft()
    @State private var categories: [String: FinanceRangeDraft] = [:]
    @State private var busy = false
    @State private var loaded: FinanceBenchmark??

    var body: some View {
        let saved = store.overview?.benchmark
        let draft = makeBenchmark()
        Form {
            Section {
                TextField("Source", text: $label, prompt: Text("e.g. statistics office 2024, couple with 2 children"))
            } footer: {
                Text("Each amount is a range per month in \(store.currency), from the lower to the upper households; a single value is a single average. Leave empty what you don’t know.")
            }
            Section("Totals") {
                rangeRow("Income per month", $income)
                rangeRow("Expenses per month", $expense)
            }
            if !store.tree.roots.isEmpty {
                Section("Per category") {
                    ForEach(store.tree.children(of: nil)) { node in
                        rangeRow(node.category.label, Binding { categories[node.id] ?? FinanceRangeDraft() } set: { categories[node.id] = $0 },
                                 placeholder: rolledUp(node.id),
                                 caption: node.category.kind == .income ? String(localized: "Income") : nil)
                    }
                }
            }
            if store.canEdit {
                Section {
                    if draft == nil {
                        Text("Amounts must be numbers from 0, “from” not above “to”.").foregroundStyle(.red)
                    }
                    Button("Save") {
                        Task {
                            busy = true
                            await store.setBenchmark(draft!.isEmpty ? nil : draft!.benchmark)
                            busy = false
                        }
                    }
                    .disabled(busy || draft == nil)
                    if saved != nil {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task {
                                busy = true
                                await store.setBenchmark(nil)
                                busy = false
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!store.canEdit)
        .navigationTitle("Statistic average")
        .onAppear { fill(saved) }
        .onChange(of: saved) { _, value in fill(value) }
    }

    private func fill(_ saved: FinanceBenchmark?) {
        guard loaded != .some(saved) else { return }
        loaded = .some(saved)
        label = saved?.label ?? ""
        income = FinanceRangeDraft(saved?.income)
        expense = FinanceRangeDraft(saved?.expense)
        categories = Dictionary((saved?.categories ?? []).map { ($0.categoryId, FinanceRangeDraft($0.range)) }) { _, b in b }
    }

    private struct Made {
        var benchmark: FinanceBenchmark
        var isEmpty: Bool { benchmark.income == nil && benchmark.expense == nil && benchmark.categories.isEmpty }
    }

    /// The draft as a benchmark; nil while an amount is invalid.
    private func makeBenchmark() -> Made? {
        guard case let .ok(income) = income.parsed, case let .ok(expense) = expense.parsed else { return nil }
        var list: [FinanceBenchmarkCategory] = []
        for (id, draft) in categories.sorted(by: { $0.key < $1.key }) where store.tree.node(id) != nil {
            guard case let .ok(range) = draft.parsed else { return nil }
            if let range { list.append(FinanceBenchmarkCategory(categoryId: id, lowCents: range.lowCents, highCents: range.highCents)) }
        }
        return Made(benchmark: FinanceBenchmark(label: label.trimmingCharacters(in: .whitespaces), income: income,
                                                expense: expense, categories: list))
    }

    /// What a top-level category without its own range shows: its subcategories' sum.
    private func rolledUp(_ id: String) -> FinanceRangeDraft? {
        let below = store.tree.subtree(id).filter { $0 != id }.compactMap { k -> FinanceCentsRange? in
            if case let .ok(range) = (categories[k] ?? FinanceRangeDraft()).parsed { return range }
            return nil
        }
        guard !below.isEmpty else { return nil }
        return FinanceRangeDraft(FinanceCentsRange(lowCents: below.reduce(0) { $0 + $1.lowCents },
                                                   highCents: below.reduce(0) { $0 + $1.highCents }))
    }

    private func rangeRow(_ title: String, _ value: Binding<FinanceRangeDraft>, placeholder: FinanceRangeDraft? = nil,
                          caption: String? = nil) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("from", text: value.low, prompt: Text(placeholder?.low ?? String(localized: "from")))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                Text(verbatim: "–").foregroundStyle(.secondary)
                TextField("to", text: value.high, prompt: Text(placeholder?.high ?? String(localized: "to")))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            .monospacedDigit()
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A range per month as typed: "" for an end that isn't given.
struct FinanceRangeDraft: Hashable {
    var low = ""
    var high = ""

    enum Parsed: Equatable {
        case ok(FinanceCentsRange?)
        case invalid
    }

    init(low: String = "", high: String = "") {
        self.low = low
        self.high = high
    }

    init(_ range: FinanceCentsRange?) {
        if let range {
            low = FinanceMoney.input(range.lowCents)
            high = FinanceMoney.input(range.highCents)
        }
    }

    /// Nil when empty, invalid when not numbers of at least 0 from low to high; one end alone is
    /// a single value.
    var parsed: Parsed {
        func parse(_ v: String) -> Int?? {
            v.trimmingCharacters(in: .whitespaces).isEmpty ? .none : .some(FinanceMoney.parse(v))
        }
        let l = parse(low), h = parse(high)
        if l == nil && h == nil { return .ok(nil) }
        if l == .some(nil) || h == .some(nil) { return .invalid }
        let lo = l.flatMap { $0 }, hi = h.flatMap { $0 }
        if (lo ?? 0) < 0 || (hi ?? 0) < 0 { return .invalid }
        if let lo, let hi, lo > hi { return .invalid }
        return .ok(FinanceCentsRange(lowCents: lo ?? hi!, highCents: hi ?? lo!))
    }
}

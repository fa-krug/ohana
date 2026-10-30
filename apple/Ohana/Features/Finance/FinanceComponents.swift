import SwiftUI

extension View {
    /// A sheet's smallest size on the Mac (iOS sheets take the screen's width).
    func financeSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}

/// A small dot in a category's or account's color.
struct FinanceColorDot: View {
    let hex: String
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(FinanceColor.color(hex)).frame(width: size, height: size)
    }
}

/// The category's color, icon and name, or "Uncategorized".
struct FinanceCategoryLabel: View {
    let category: FinanceCategory?

    var body: some View {
        if let category {
            HStack(spacing: 5) {
                FinanceColorDot(hex: category.color)
                Text(category.label).lineLimit(1)
            }
        } else {
            Text("Uncategorized").foregroundStyle(.secondary)
        }
    }
}

/// A small glass pill with the account's color, icon and name.
struct FinanceAccountChip: View {
    let account: FinanceAccount

    var body: some View {
        HStack(spacing: 4) {
            FinanceColorDot(hex: account.color, size: 7)
            Text(account.label).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// The category tree as menu items: a category with subcategories opens a submenu holding
/// itself and them. `fits` leaves out top-level categories (with their subcategories) it rejects.
struct FinanceCategoryMenuItems: View {
    let tree: FinanceCategoryTree
    var selection: String?
    var fits: (FinanceCategory) -> Bool = { _ in true }
    let pick: (String?) -> Void

    var body: some View {
        Button {
            pick(nil)
        } label: {
            if selection == nil { Label("Uncategorized", systemImage: "checkmark") } else { Text("Uncategorized") }
        }
        Divider()
        ForEach(tree.children(of: nil).filter { fits($0.category) }) { node in
            FinanceCategoryMenuNode(tree: tree, node: node, selection: selection, pick: pick)
        }
    }
}

struct FinanceCategoryMenuNode: View {
    let tree: FinanceCategoryTree
    let node: FinanceCategoryTree.Node
    var selection: String?
    let pick: (String?) -> Void

    var body: some View {
        if node.children.isEmpty {
            item
        } else {
            Menu(node.category.label) {
                item
                Divider()
                ForEach(tree.children(of: node.id)) { child in
                    FinanceCategoryMenuNode(tree: tree, node: child, selection: selection, pick: pick)
                }
            }
        }
    }

    private var item: some View {
        Button {
            pick(node.id)
        } label: {
            if selection == node.id { Label(node.category.label, systemImage: "checkmark") } else { Text(node.category.label) }
        }
    }
}

/// A list to pick a category from (forms): the tree indented, searchable by path.
struct FinanceCategoryPickerList: View {
    let tree: FinanceCategoryTree
    @Binding var selection: String?
    var fits: (FinanceCategory) -> Bool = { _ in true }
    var noneTitle: LocalizedStringKey = "Uncategorized"
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var nodes: [FinanceCategoryTree.Node] {
        let fitting = tree.ordered.filter { fits($0.category) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? fitting : fitting.filter { tree.path($0.id).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if query.isEmpty {
                row(title: Text(noneTitle).foregroundStyle(.secondary), id: nil, depth: 0)
            }
            ForEach(nodes) { node in
                row(title: Text(node.category.label), id: node.id, depth: query.isEmpty ? node.depth : 0,
                    color: node.category.color, path: query.isEmpty || node.depth == 0 ? nil : tree.path(node.id))
            }
        }
        .searchable(text: $query)
        .navigationTitle("Category")
    }

    private func row(title: Text, id: String?, depth: Int, color: String? = nil, path: String? = nil) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack(spacing: 8) {
                if let color { FinanceColorDot(hex: color) }
                VStack(alignment: .leading, spacing: 1) {
                    title
                    if let path { Text(path).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.leading, CGFloat(min(depth, 6)) * 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Income, expenses and the difference, as headline numbers.
struct FinanceStatTiles: View {
    let income: Int
    let expense: Int
    let currency: String

    var body: some View {
        let net = income - expense
        HStack(spacing: 10) {
            tile("Income", FinanceMoney.format(income, currency: currency), dot: .green)
            tile("Expenses", FinanceMoney.format(expense, currency: currency), dot: .orange)
            tile("Net", FinanceMoney.format(net, currency: currency, sign: true), color: net < 0 ? .red : .primary,
                 hint: income > 0 ? String(localized: "\(Int((Double(net) / Double(income) * 100).rounded())) % left") : nil)
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, dot: Color? = nil, color: Color = .primary,
                      hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let dot { RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 9, height: 9) }
                Text(title).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
    }
}

/// The accounts with their balances on the day the period shows; picking one shows only its
/// transactions. With several accounts a total comes first.
struct FinanceAccountCards: View {
    @Bindable var store: FinanceStore

    private struct Card: Identifiable {
        var id: String
        var label: String
        var color: String?
        var cents: Int
        var now: Int
    }

    var body: some View {
        let at = store.balances?.at
        let past = at != nil && at != Day.today.description
        var cards = store.accounts.map {
            Card(id: $0.id, label: $0.label, color: $0.color, cents: store.balance(of: $0), now: $0.balanceCents)
        }
        if cards.count > 1 {
            cards.insert(Card(id: "", label: String(localized: "All accounts"), color: nil,
                              cents: cards.reduce(0) { $0 + $1.cents }, now: cards.reduce(0) { $0 + $1.now }), at: 0)
        }
        return VStack(alignment: .leading, spacing: 6) {
            if past, let at, let day = Day(at) {
                Text("Balances on \(day.formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(cards) { card in
                            cardView(card, past: past)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func cardView(_ card: Card, past: Bool) -> some View {
        let active = !card.id.isEmpty && store.filter.account == card.id
        return Button {
            Task { await store.setFilter { $0.account = store.filter.account == card.id ? "" : card.id } }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let color = card.color { FinanceColorDot(hex: color) }
                    Text(card.label).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(store.money(card.cents))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(card.cents < 0 ? .red : .primary)
                if past && card.now != card.cents {
                    Text("Now \(store.money(card.now))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            .padding(12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(active ? ModuleTint.finance.opacity(0.35) : .clear).interactive(),
                     in: .rect(cornerRadius: 18))
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(Text(card.id.isEmpty ? String(localized: "Show all accounts") : String(localized: "Show only this account")))
    }
}

/// The period: previous, the period (a menu to pick month, year or all time), next.
struct FinancePeriodBar: View {
    @Bindable var store: FinanceStore

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if store.period.mode != .all {
                    Button {
                        Task { await store.step(-1) }
                    } label: {
                        Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly)
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .help("Previous (⌥⌘←)")
                }
                Menu {
                    Picker("Period", selection: Binding(
                        get: { store.period.mode },
                        set: { mode in Task { await store.setPeriod(FinancePeriod(mode: mode, year: store.period.year, month: store.period.month)) } }
                    )) {
                        ForEach(FinancePeriod.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Today", systemImage: "calendar") {
                        let now = FinancePeriod.current()
                        Task { await store.setPeriod(FinancePeriod(mode: store.period.mode == .all ? .month : store.period.mode,
                                                                   year: now.year, month: now.month)) }
                    }
                } label: {
                    Text(store.period.title)
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 120)
                }
                .menuIndicator(.visible)
                if store.period.mode != .all {
                    Button {
                        Task { await store.step(1) }
                    } label: {
                        Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .help("Next (⌥⌘→)")
                }
            }
            .buttonStyle(.glass)
            .menuStyle(.button)
        }
    }
}

/// The filters of the list as glass menus: account, category, kind.
struct FinanceFilterBar: View {
    @Bindable var store: FinanceStore

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !store.accounts.isEmpty {
                        Menu {
                            Picker("Account", selection: filterBinding(\.account)) {
                                Text("All accounts").tag("")
                                Text("Without account").tag("none")
                                ForEach(store.accounts) { Text($0.label).tag($0.id) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            chip("building.columns", accountTitle, active: !store.filter.account.isEmpty)
                        }
                    }
                    Menu {
                        Button("All categories") { set { $0.category = "" } }
                        Button("Uncategorized") { set { $0.category = "none" } }
                        Divider()
                        ForEach(store.tree.children(of: nil)) { node in
                            FinanceCategoryMenuNode(tree: store.tree, node: node,
                                                    selection: store.filter.category.isEmpty ? nil : store.filter.category) { id in
                                set { $0.category = id ?? "" }
                            }
                        }
                    } label: {
                        chip("tag", categoryTitle, active: !store.filter.category.isEmpty)
                    }
                    Menu {
                        Picker("Kind", selection: Binding(get: { store.filter.kind }, set: { kind in set { $0.kind = kind } })) {
                            ForEach(FinanceFilter.Kind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        chip("arrow.up.arrow.down", store.filter.kind.title, active: store.filter.kind != .all)
                    }
                    if store.filter.isActive {
                        Button {
                            set { $0.category = ""; $0.account = ""; $0.kind = .all }
                        } label: {
                            Label("Clear filters", systemImage: "xmark").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .help("Clear filters")
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var accountTitle: String {
        switch store.filter.account {
        case "": String(localized: "All accounts")
        case "none": String(localized: "Without account")
        default: store.account(store.filter.account)?.label ?? String(localized: "Account")
        }
    }

    private var categoryTitle: String {
        switch store.filter.category {
        case "": String(localized: "All categories")
        case "none": String(localized: "Uncategorized")
        default: store.category(store.filter.category)?.label ?? String(localized: "Category")
        }
    }

    private func chip(_ icon: String, _ title: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .foregroundStyle(active ? ModuleTint.finance : .primary)
    }

    private func filterBinding(_ key: WritableKeyPath<FinanceFilter, String>) -> Binding<String> {
        Binding(get: { store.filter[keyPath: key] }, set: { value in set { $0[keyPath: key] = value } })
    }

    private func set(_ change: @escaping (inout FinanceFilter) -> Void) {
        Task { await store.setFilter(change) }
    }
}

/// The toast at the bottom: what a change did, with its undo.
struct FinanceToastView: View {
    @Bindable var store: FinanceStore
    let toast: FinanceToast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.callout)
                .lineLimit(2)
            if toast.undo != nil {
                // ⌘Z is Edit → Undo, which undoes the same change (the store registers it).
                Button("Undo") { Task { await store.undoToast() } }
                    .buttonStyle(.glassProminent)
                    .tint(ModuleTint.finance)
            }
            Button {
                store.dismissToast()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

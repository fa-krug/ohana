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

    /// Large controls on iOS, so their hit targets reach 44 pt.
    func financeTouchSize() -> some View {
        #if os(iOS)
        controlSize(.large)
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

/// A small pill with the account's color, icon and name.
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
        .accessibilityAddTraits(selection == id ? .isSelected : [])
        // A subcategory says where it sits; sighted people see it by the indentation.
        .accessibilityHint(id.flatMap { depth > 0 ? Text(tree.path($0)) : nil } ?? Text(verbatim: ""))
    }
}

/// Income, expenses and the difference, as headline numbers: cards side by side (one below the
/// other at accessibility sizes), or `inline` without cards, for a list row.
struct FinanceStatTiles: View {
    let income: Int
    let expense: Int
    let currency: String
    var inline = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let net = income - expense
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            tile("Income", FinanceMoney.format(income, currency: currency), dot: .green)
            tile("Expenses", FinanceMoney.format(expense, currency: currency), dot: .orange)
            tile("Net", FinanceMoney.format(net, currency: currency, sign: true), color: net < 0 ? .red : .primary,
                 hint: income > 0 ? String(localized: "\(Int((Double(net) / Double(income) * 100).rounded())) % left") : nil)
        }
    }

    @ViewBuilder
    private func tile(_ title: LocalizedStringKey, _ value: String, dot: Color? = nil, color: Color = .primary,
                      hint: String? = nil) -> some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let dot { RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 9, height: 9) }
                Text(title).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // The amount keeps its sign: the color isn't the only hint that it's negative.
            Text(value)
                .font((inline ? Font.subheadline : .headline).weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.6)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        if inline { content } else { content.contentCard(cornerRadius: 18, padding: 12) }
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
                HStack(alignment: .top, spacing: 10) {
                    ForEach(cards) { card in
                        cardView(card, past: past)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func cardView(_ card: Card, past: Bool) -> some View {
        let active = !card.id.isEmpty && store.filter.account == card.id
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            Task { await store.setFilter { $0.account = store.filter.account == card.id ? "" : card.id } }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if let color = card.color { FinanceColorDot(hex: color) }
                    Text(card.label).lineLimit(1)
                    if active {
                        // Picked: a checkmark as well as the tint.
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(ModuleTint.finance)
                    }
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
            .frame(minWidth: 120, minHeight: 44, alignment: .leading)
            .padding(12)
            .background {
                shape.fill(Color.cardBackground)
                    .overlay { if active { shape.fill(ModuleTint.finance.opacity(0.15)) } }
                    .overlay { if active { shape.strokeBorder(ModuleTint.finance, lineWidth: 1.5) } }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityHint(Text(card.id.isEmpty ? String(localized: "Show all accounts") : String(localized: "Show only this account")))
        .help(Text(card.id.isEmpty ? String(localized: "Show all accounts") : String(localized: "Show only this account")))
    }
}

/// The period: previous, the period (a menu to pick month, year or all time), next. `floating`
/// above the content it is glass; in a list (iPhone) it is part of the content. The menu bar's
/// Finance menu steps it with ⌘[ and ⌘].
struct FinancePeriodBar: View {
    @Bindable var store: FinanceStore
    var floating = true

    var body: some View {
        if floating {
            GlassEffectContainer(spacing: 8) {
                bar.buttonStyle(.glass)
            }
        } else {
            bar.buttonStyle(.bordered)
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if store.period.mode != .all {
                Button {
                    Task { await store.step(-1) }
                } label: {
                    Label("Previous period", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .help("Previous period (⌘[)")
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
                Button("Today", systemImage: "calendar") { Task { await store.goToToday() } }
            } label: {
                Text(store.period.title)
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 120)
            }
            .menuIndicator(.visible)
            .accessibilityLabel(Text("Period"))
            .accessibilityValue(Text(store.period.title))
            if store.period.mode != .all {
                Button {
                    Task { await store.step(1) }
                } label: {
                    Label("Next period", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .help("Next period (⌘])")
            }
        }
        .menuStyle(.button)
        .financeTouchSize()
    }
}

/// The filters of the list as menus in the content (iPad, Mac): account, category, kind.
struct FinanceFilterBar: View {
    @Bindable var store: FinanceStore

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if !store.accounts.isEmpty {
                    Menu {
                        FinanceAccountFilterPicker(store: store).pickerStyle(.inline)
                    } label: {
                        chip("building.columns", FinanceFilterTitles.account(store), active: !store.filter.account.isEmpty)
                    }
                }
                Menu {
                    FinanceCategoryFilterItems(store: store)
                } label: {
                    chip("tag", FinanceFilterTitles.category(store), active: !store.filter.category.isEmpty)
                }
                Menu {
                    FinanceKindFilterPicker(store: store).pickerStyle(.inline)
                } label: {
                    chip("arrow.up.arrow.down", store.filter.kind.title, active: store.filter.kind != .all)
                }
                if store.filter.isActive {
                    Button {
                        Task { await store.clearFilters() }
                    } label: {
                        Label("Clear filters", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                    .help("Clear filters")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .financeTouchSize()
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ icon: String, _ title: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .foregroundStyle(active ? ModuleTint.finance : .primary)
    }
}

/// The toolbar's filter menu on iPhone: the same filters as menu items, badged with how many
/// are on.
struct FinanceFilterMenu: View {
    @Bindable var store: FinanceStore

    var body: some View {
        let count = store.filter.activeCount
        Menu {
            if !store.accounts.isEmpty {
                FinanceAccountFilterPicker(store: store).pickerStyle(.menu)
            }
            Menu {
                FinanceCategoryFilterItems(store: store)
            } label: {
                Label("Category", systemImage: "tag")
                Text(FinanceFilterTitles.category(store))
            }
            FinanceKindFilterPicker(store: store).pickerStyle(.menu)
            if store.filter.isActive {
                Divider()
                Button("Clear filters", systemImage: "xmark") { Task { await store.clearFilters() } }
            }
        } label: {
            Label("Filter", systemImage: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .badge(count)
        .accessibilityValue(count > 0 ? Text(FinanceText.inflected("^[\(count) filter](inflect: true) on")) : Text(verbatim: ""))
    }
}

/// What the filter menus show for the current account and category.
@MainActor
enum FinanceFilterTitles {
    static func account(_ store: FinanceStore) -> String {
        switch store.filter.account {
        case "": String(localized: "All accounts")
        case "none": String(localized: "Without account")
        default: store.account(store.filter.account)?.label ?? String(localized: "Account")
        }
    }

    static func category(_ store: FinanceStore) -> String {
        switch store.filter.category {
        case "": String(localized: "All categories")
        case "none": String(localized: "Uncategorized")
        default: store.category(store.filter.category)?.label ?? String(localized: "Category")
        }
    }
}

struct FinanceAccountFilterPicker: View {
    @Bindable var store: FinanceStore

    var body: some View {
        Picker(selection: Binding(get: { store.filter.account }, set: { id in Task { await store.setFilter { $0.account = id } } })) {
            Text("All accounts").tag("")
            Text("Without account").tag("none")
            ForEach(store.accounts) { Text($0.label).tag($0.id) }
        } label: {
            Label("Account", systemImage: "building.columns")
        }
    }
}

struct FinanceKindFilterPicker: View {
    @Bindable var store: FinanceStore

    var body: some View {
        Picker(selection: Binding(get: { store.filter.kind }, set: { kind in Task { await store.setFilter { $0.kind = kind } } })) {
            ForEach(FinanceFilter.Kind.allCases) { Text($0.title).tag($0) }
        } label: {
            Label("Kind", systemImage: "arrow.up.arrow.down")
        }
    }
}

/// All, uncategorized, and the category tree (a category includes its subcategories).
struct FinanceCategoryFilterItems: View {
    @Bindable var store: FinanceStore

    var body: some View {
        Button("All categories") { set("") }
        Button("Uncategorized") { set("none") }
        Divider()
        ForEach(store.tree.children(of: nil)) { node in
            FinanceCategoryMenuNode(tree: store.tree, node: node,
                                    selection: store.filter.category.isEmpty ? nil : store.filter.category) { id in
                set(id ?? "")
            }
        }
    }

    private func set(_ category: String) {
        Task { await store.setFilter { $0.category = category } }
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
    }
}

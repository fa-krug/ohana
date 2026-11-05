import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The transactions of one day, in the server's order (newest first).
struct FinanceDayGroup: Identifiable {
    var date: String
    var items: [FinanceTransaction]
    var id: String { date }

    static func groups(_ transactions: [FinanceTransaction]) -> [FinanceDayGroup] {
        var out: [FinanceDayGroup] = []
        for t in transactions {
            if out.last?.date == t.date { out[out.count - 1].items.append(t) } else { out.append(FinanceDayGroup(date: t.date, items: [t])) }
        }
        return out
    }

    var title: String {
        guard let day = Day(date) else { return date }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// What the list says about a transaction's links: "Transfer · A → B", "Part of …", "Split into …".
struct FinanceLinkInfo {
    let legs: [String: [FinanceTransaction]]
    let byId: [String: FinanceTransaction]

    init(_ transactions: [FinanceTransaction]) {
        var legs: [String: [FinanceTransaction]] = [:]
        for t in transactions { if let id = t.transferId { legs[id, default: []].append(t) } }
        self.legs = legs
        byId = Dictionary(transactions.map { ($0.id, $0) }) { a, _ in a }
    }

    /// (icon, text) for transfer legs, parts and split bookings.
    @MainActor
    func detail(_ t: FinanceTransaction, store: FinanceStore) -> (String, String)? {
        func accountName(_ t: FinanceTransaction) -> String {
            store.account(t.accountId)?.name ?? String(localized: "Without account")
        }
        if let transferId = t.transferId {
            let group = legs[transferId] ?? [t]
            let from = group.first { $0.amountCents < 0 }, to = group.first { $0.amountCents > 0 }
            let route = if let from, let to { "\(accountName(from)) → \(accountName(to))" }
                else if t.amountCents < 0 { "\(accountName(t)) →" } else { "→ \(accountName(t))" }
            return ("link", String(localized: "Transfer") + " · " + route)
        }
        if let splitOf = t.splitOf {
            let booking = byId[splitOf]
            let name = booking.map { !$0.payee.isEmpty ? $0.payee : $0.description } ?? ""
            return ("list.bullet.indent", name.isEmpty ? String(localized: "Part of a split booking") : String(localized: "Part of \(name)"))
        }
        if let split = t.split {
            var text = FinanceText.inflected("Split into ^[\(split.parts) part](inflect: true)")
            if split.remainderCents != 0 {
                text += " · " + String(localized: "remainder \(store.money(split.remainderCents, sign: split.remainderCents > 0))")
            }
            return ("list.bullet.indent", text)
        }
        return nil
    }
}

/// The filtered transactions of the period: a sortable table on the Mac and the iPad, a list
/// grouped by day on the iPhone (where the period, the balances and the totals scroll away
/// with it). Editors change categories inline, combine the selected rows into a transfer or a
/// split booking, and undo from the toast.
struct FinanceTransactionsView: View {
    @Bindable var store: FinanceStore
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    var selecting: Bool
    let onEdit: (FinanceTransaction) -> Void

    var body: some View {
        if let list = store.list {
            content(list)
        } else if let error = store.error {
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.reloadAll() } }.buttonStyle(.glassProminent)
            }
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ list: FinanceTransactionList) -> some View {
        #if os(iOS)
        if sizeClass == .compact {
            compactList(list, info: store.linkInfo)
        } else {
            table(list)
        }
        #else
        table(list)
        #endif
    }

    private func table(_ list: FinanceTransactionList) -> some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                if !store.accounts.isEmpty { FinanceAccountCards(store: store) }
                FinanceStatTiles(income: list.incomeCents, expense: list.expenseCents, currency: store.currency)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            if list.transactions.isEmpty {
                empty.frame(maxHeight: .infinity)
            } else {
                FinanceTransactionTable(store: store, transactions: list.transactions, onEdit: onEdit)
                if list.total > list.transactions.count { more(list) }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No transactions", systemImage: "banknote")
        } description: {
            Text(store.canEdit
                 ? String(localized: "No transactions in this period. Add one or import a bank statement (CSV).")
                 : String(localized: "No transactions in this period."))
        }
    }

    private func more(_ list: FinanceTransactionList) -> some View {
        Button("Show more (\(list.total - list.transactions.count) left)") { Task { await store.showMore() } }
            .buttonStyle(.bordered)
            .padding(.bottom, 8)
    }

    #if os(iOS)
    /// The iPhone's list: the period, the balances and a one-line summary first, so the first
    /// transactions show high on the screen and the rest scrolls away with the list.
    private func compactList(_ list: FinanceTransactionList, info: FinanceLinkInfo) -> some View {
        List(selection: $store.selected) {
            Section {
                FinancePeriodBar(store: store, floating: false)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                if !store.accounts.isEmpty {
                    FinanceAccountCards(store: store)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
            }
            Section {
                FinanceStatTiles(income: list.incomeCents, expense: list.expenseCents, currency: store.currency, inline: true)
                    .selectionDisabled()
            }
            if list.transactions.isEmpty {
                empty
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            ForEach(FinanceDayGroup.groups(list.transactions)) { group in
                Section(group.title) {
                    ForEach(group.items) { t in
                        row(t, info: info)
                    }
                }
            }
            if list.total > list.transactions.count {
                more(list)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .opacity(store.loadingList ? 0.6 : 1)
        .animation(.default, value: store.loadingList)
    }

    @ViewBuilder
    private func row(_ t: FinanceTransaction, info: FinanceLinkInfo) -> some View {
        let content = FinanceTransactionRow(store: store, transaction: t, detail: info.detail(t, store: store))
        Group {
            if selecting {
                content
            } else {
                Button { onEdit(t) } label: { content.contentShape(.rect) }
                    .buttonStyle(.plain)
            }
        }
        .tag(t.id)
        .contextMenu { FinanceTransactionMenu(store: store, transaction: t, onEdit: onEdit) }
        .swipeActions(edge: .trailing) {
            if store.canEdit {
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete([t.id]) } }
            }
        }
        .swipeActions(edge: .leading) {
            if store.canEdit {
                if t.transferId != nil {
                    Button("Split up transfer", systemImage: "link.badge.plus") { Task { await store.unlink(t.id) } }
                        .tint(.indigo)
                }
                if t.splitOf != nil || t.split != nil {
                    Button(t.splitOf != nil ? String(localized: "Take out of the split") : String(localized: "Undo split"), systemImage: "rectangle.split.3x1") {
                        Task { await store.unsplit(t) }
                    }
                    .tint(.teal)
                }
            }
        }
    }
    #endif
}

/// One transaction: payee or description, its links or account, category and amount.
struct FinanceTransactionRow: View {
    @Bindable var store: FinanceStore
    let transaction: FinanceTransaction
    let detail: (String, String)?

    var body: some View {
        let t = transaction
        let category = store.category(t.categoryId)
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(category.map { FinanceColor.color($0.color) } ?? Color.secondary.opacity(0.25))
                .frame(width: 4)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.body.weight(.medium)).lineLimit(1)
                if let (icon, text) = detail {
                    Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if store.account(t.accountId) != nil || (!t.payee.isEmpty && !t.description.isEmpty) {
                    HStack(spacing: 6) {
                        if let account = store.account(t.accountId) { FinanceAccountChip(account: account) }
                        if !t.payee.isEmpty && !t.description.isEmpty {
                            Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                FinanceCategoryLabel(category: category).font(.caption)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                FinanceAmountText(store: store, transaction: t)
                HStack(spacing: 6) {
                    if !t.note.isEmpty {
                        Image(systemName: "note.text").accessibilityLabel("Note")
                    }
                    if let origin = t.origin, let icon = origin.icon {
                        Image(systemName: icon).accessibilityLabel(origin.title)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// The amount: green in, red out, always with its sign; muted for a transfer leg (it counts
/// once, by the group's sum) and a split booking (it counts through its parts).
struct FinanceAmountText: View {
    @Bindable var store: FinanceStore
    let transaction: FinanceTransaction

    var body: some View {
        let t = transaction
        let muted = t.transferId != nil || t.split != nil
        Text(store.money(t.amountCents, sign: t.amountCents > 0))
            .font(.body.weight(.semibold).monospacedDigit())
            .foregroundStyle(FinanceMoney.color(t.amountCents, muted: muted))
            .help(muted ? Text(t.transferId != nil
                               ? String(localized: "Part of a transfer: it counts only once, as the sum of its transactions")
                               : String(localized: "Split booking: it counts only through its parts and what they leave over"))
                        : Text(verbatim: ""))
    }
}

/// The actions on one transaction (context menus).
struct FinanceTransactionMenu: View {
    @Bindable var store: FinanceStore
    let transaction: FinanceTransaction
    let onEdit: (FinanceTransaction) -> Void

    var body: some View {
        let t = transaction
        if store.canEdit {
            Button("Edit", systemImage: "pencil") { onEdit(t) }
            Menu {
                FinanceCategoryMenuItems(tree: store.tree, selection: t.categoryId,
                                         fits: { FinanceCategoryTree.fits($0, income: t.amountCents > 0) }) { id in
                    Task { await store.setCategory([t.id], to: id) }
                }
            } label: {
                Label("Category", systemImage: "tag")
            }
        } else {
            Button("Details", systemImage: "info.circle") { onEdit(t) }
        }
        if store.canEdit {
            if t.transferId != nil {
                Button("Split up transfer", systemImage: "link.badge.plus") { Task { await store.unlink(t.id) } }
            }
            if t.splitOf != nil || t.split != nil {
                Button(t.splitOf != nil ? String(localized: "Take out of the split") : String(localized: "Undo split"), systemImage: "rectangle.split.3x1") {
                    Task { await store.unsplit(t) }
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete([t.id]) } }
        }
    }
}

/// A transaction as the table sorts it: with the names its category and account show, and
/// what its cells show, worked out once per list (not in every cell, at every selection change).
nonisolated struct FinanceTableRow: Identifiable, Sendable {
    let transaction: FinanceTransaction
    let id: String
    let date: String
    let title: String
    let amountCents: Int
    let category: String
    let account: String
    /// The date as the Date column shows it.
    let dateText: String
    let categoryValue: FinanceCategory?
    /// "Food › Groceries" (the Category cell's help), "" without a category.
    let categoryPath: String
    let accountValue: FinanceAccount?
    /// The links' line under the payee (`FinanceLinkInfo.detail`).
    let detail: (icon: String, text: String)?

    init(transaction t: FinanceTransaction, category: String = "", account: String = "", dateText: String? = nil,
         categoryValue: FinanceCategory? = nil, categoryPath: String = "", accountValue: FinanceAccount? = nil,
         detail: (icon: String, text: String)? = nil) {
        transaction = t
        id = t.id
        date = t.date
        title = t.title
        amountCents = t.amountCents
        self.category = category
        self.account = account
        self.dateText = dateText ?? t.date
        self.categoryValue = categoryValue
        self.categoryPath = categoryPath
        self.accountValue = accountValue
        self.detail = detail
    }

    /// The rows of the store's list, in its order.
    @MainActor
    static func rows(_ store: FinanceStore) -> [FinanceTableRow] {
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        var dates: [String: String] = [:]
        var paths: [String: String] = [:]
        var rows: [FinanceTableRow] = []
        let transactions = store.list?.transactions ?? []
        rows.reserveCapacity(transactions.count)
        for t in transactions {
            let category = store.category(t.categoryId)
            let account = store.account(t.accountId)
            let dateText = dates[t.date] ?? (Day(t.date)?.formatted(format) ?? t.date)
            dates[t.date] = dateText
            var path = ""
            if let category {
                path = paths[category.id] ?? store.tree.path(category.id)
                paths[category.id] = path
            }
            let detail = store.linkInfo.detail(t, store: store).map { (icon: $0.0, text: $0.1) }
            rows.append(FinanceTableRow(transaction: t, category: category?.label ?? "", account: account?.label ?? "",
                                        dateText: dateText, categoryValue: category, categoryPath: path,
                                        accountValue: account, detail: detail))
        }
        return rows
    }
}

/// The table's rows, sorted, kept between body passes: the table is drawn again at every
/// selection change, and building and sorting all rows each time made that slow.
@MainActor
final class FinanceTableRowsCache {
    private var source: (list: Int, overview: Int)?
    private var unsorted: [FinanceTableRow] = []
    private var order: [KeyPathComparator<FinanceTableRow>]?
    private var sorted: [FinanceTableRow] = []

    func rows(_ store: FinanceStore, sortedBy order: [KeyPathComparator<FinanceTableRow>]) -> [FinanceTableRow] {
        // Read in the body: changes of the list or the overview draw the table again.
        let source = (list: store.listRevision, overview: store.overviewRevision)
        if self.source == nil || self.source! != source {
            unsorted = FinanceTableRow.rows(store)
            self.source = source
            self.order = nil
        }
        if self.order != order {
            sorted = FinanceTableSort.sorted(unsorted, by: order)
            self.order = order
        }
        return sorted
    }
}

/// The table's sorting. Newest first is the server's own order (within a day the newest booked
/// first), and oldest first exactly its reverse; other columns sort stably on top of it.
enum FinanceTableSort {
    static var newestFirst: [KeyPathComparator<FinanceTableRow>] { [KeyPathComparator(\.date, order: .reverse)] }

    static func sorted(_ rows: [FinanceTableRow], by order: [KeyPathComparator<FinanceTableRow>]) -> [FinanceTableRow] {
        guard let first = order.first else { return rows }
        if first.keyPath == \FinanceTableRow.date {
            return first.order == .reverse ? rows : rows.reversed()
        }
        return rows.sorted(using: order)
    }
}

/// The table of transactions (Mac, iPad): multiple selection, sortable and customizable
/// columns (remembered per window), a double click or tap edits, ⌫ deletes on the Mac.
struct FinanceTransactionTable: View {
    @Bindable var store: FinanceStore
    let transactions: [FinanceTransaction]
    let onEdit: (FinanceTransaction) -> Void
    @State private var sortOrder = FinanceTableSort.newestFirst
    @State private var rowsCache = FinanceTableRowsCache()
    @SceneStorage("finance.columns") private var columns: TableColumnCustomization<FinanceTableRow>

    var body: some View {
        let rows = rowsCache.rows(store, sortedBy: sortOrder)
        Table(rows, selection: $store.selected, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Date", value: \.date) { row in
                Text(row.dateText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 130)
            .customizationID("date")
            TableColumn("Payee", value: \.title, comparator: .localizedStandard) { row in
                payee(row)
            }
            .width(min: 180, ideal: 320)
            .customizationID("payee")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Category", value: \.category, comparator: .localizedStandard) { row in
                category(row)
            }
            .width(min: 120, ideal: 180)
            .customizationID("category")
            TableColumn("Account", value: \.account, comparator: .localizedStandard) { row in
                if let account = row.accountValue { FinanceAccountChip(account: account) }
            }
            .width(min: 80, ideal: 120)
            .customizationID("account")
            TableColumn("Amount", value: \.amountCents) { row in
                FinanceAmountText(store: store, transaction: row.transaction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)
            .customizationID("amount")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let t = transactions.first(where: { $0.id == id }) {
                FinanceTransactionMenu(store: store, transaction: t, onEdit: onEdit)
            } else if ids.count > 1, store.canEdit {
                FinanceSelectionMenu(store: store, ids: ids)
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let t = transactions.first(where: { $0.id == id }) { onEdit(t) }
        }
        #if os(macOS)
        .onDeleteCommand {
            guard store.canEdit, !store.selected.isEmpty else { return }
            Task { await store.delete(Array(store.selected)) }
        }
        #endif
        .scrollContentBackground(.hidden)
        .opacity(store.loadingList ? 0.6 : 1)
    }

    private func payee(_ row: FinanceTableRow) -> some View {
        let t = row.transaction
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(t.title).lineLimit(1)
                if let origin = t.origin, let icon = origin.icon {
                    Image(systemName: icon).foregroundStyle(.secondary)
                        .help(origin.title)
                        .accessibilityLabel(origin.title)
                }
            }
            if let detail = row.detail {
                Label(detail.text, systemImage: detail.icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if !t.payee.isEmpty && !t.description.isEmpty {
                Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Editors change the category from the cell. On the Mac the cell is a plain button whose
    /// menu is built when it opens: a `Menu` per row built the whole category tree for each row
    /// shown, again at every selection change.
    @ViewBuilder
    private func category(_ row: FinanceTableRow) -> some View {
        let t = row.transaction
        if store.canEdit {
            #if os(macOS)
            Button {
                FinanceCategoryPopUp.show(tree: store.tree, selection: t.categoryId,
                                          fits: { FinanceCategoryTree.fits($0, income: t.amountCents > 0) }) { id in
                    Task { await store.setCategory([t.id], to: id) }
                }
            } label: {
                FinanceCategoryLabel(category: row.categoryValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(row.categoryPath)
            #else
            Menu {
                FinanceCategoryMenuItems(tree: store.tree, selection: t.categoryId,
                                         fits: { FinanceCategoryTree.fits($0, income: t.amountCents > 0) }) { id in
                    Task { await store.setCategory([t.id], to: id) }
                }
            } label: {
                FinanceCategoryLabel(category: row.categoryValue)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .help(row.categoryPath)
            #endif
        } else {
            FinanceCategoryLabel(category: row.categoryValue)
        }
    }
}

#if os(macOS)
/// A table row's category menu (the Mac), built when it opens: the category tree, the current
/// one checked, a category with subcategories a submenu holding itself and them, as
/// `FinanceCategoryMenuItems`.
enum FinanceCategoryPopUp {
    static func show(tree: FinanceCategoryTree, selection: String?, fits: (FinanceCategory) -> Bool,
                     pick: @escaping (String?) -> Void) {
        let target = Target(pick: pick)
        func item(_ title: String, id: String?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.state = selection == id ? .on : .off
            return item
        }
        func add(_ node: FinanceCategoryTree.Node, to menu: NSMenu) {
            let own = item(node.category.label, id: node.id)
            guard !node.children.isEmpty else {
                menu.addItem(own)
                return
            }
            let submenu = NSMenu(title: node.category.label)
            submenu.addItem(own)
            submenu.addItem(.separator())
            for child in tree.children(of: node.id) { add(child, to: submenu) }
            let parent = NSMenuItem(title: node.category.label, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Uncategorized"), id: nil))
        menu.addItem(.separator())
        for node in tree.children(of: nil) where fits(node.category) { add(node, to: menu) }
        // Returns once the menu closed, after the chosen item's action.
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private final class Target: NSObject {
        let pick: (String?) -> Void

        init(pick: @escaping (String?) -> Void) {
            self.pick = pick
        }

        @objc func choose(_ sender: NSMenuItem) {
            pick(sender.representedObject as? String)
        }
    }
}
#endif

/// Combining the selected transactions into a transfer or a split booking.
struct FinanceCombineButtons: View {
    @Bindable var store: FinanceStore
    let selected: [FinanceTransaction]

    var body: some View {
        Button("Combine into a transfer", systemImage: "link") { Task { await store.link(selected.map(\.id)) } }
            .disabled(!FinanceStore.canLink(selected))
        Button("Combine into a split booking", systemImage: "rectangle.split.3x1") {
            guard let booking = FinanceStore.splitBooking(of: selected) else { return }
            Task { await store.split(booking: booking.id, parts: selected.filter { $0.id != booking.id }.map(\.id)) }
        }
        .disabled(!FinanceStore.canSplit(selected))
    }
}

/// The actions on several selected transactions (the table's context menu).
struct FinanceSelectionMenu: View {
    @Bindable var store: FinanceStore
    let ids: Set<String>

    var body: some View {
        let selected = store.list?.transactions.filter { ids.contains($0.id) } ?? []
        Menu {
            FinanceCategoryMenuItems(tree: store.tree, selection: nil) { id in
                Task { await store.setCategory(selected.map(\.id), to: id) }
            }
        } label: {
            Label("Category", systemImage: "tag")
        }
        FinanceCombineButtons(store: store, selected: selected)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(selected.map(\.id)) } }
    }
}

/// What the selected transactions add up to, and how they would count combined.
struct FinanceSelectionSummary: View {
    @Bindable var store: FinanceStore

    var body: some View {
        let selected = store.selectedTransactions
        let net = selected.reduce(0) { $0 + $1.amountCents }
        VStack(alignment: .leading, spacing: 2) {
            Text("\(selected.count) selected · sum \(store.money(net, sign: true))")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if selected.count >= 2 {
                Text(net == 0 ? String(localized: "Adds up to 0: counts neither as income nor as an expense.")
                     : net > 0 ? String(localized: "Counts once, as income of \(store.money(abs(net))).")
                     : String(localized: "Counts once, as an expense of \(store.money(abs(net))).")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
/// The Mac's bar above the selected rows: what they add up to, and what can be done with them:
/// set their category, combine two or more into a transfer or a split booking, delete them.
struct FinanceSelectionBar: View {
    @Bindable var store: FinanceStore

    var body: some View {
        let selected = store.selectedTransactions
        let booking = FinanceStore.splitBooking(of: selected)
        VStack(alignment: .leading, spacing: 8) {
            FinanceSelectionSummary(store: store)
            ViewThatFits(in: .horizontal) {
                actions(selected, booking: booking).labelStyle(.titleAndIcon)
                actions(selected, booking: booking).labelStyle(.iconOnly)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func actions(_ selected: [FinanceTransaction], booking: FinanceTransaction?) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    FinanceCategoryMenuItems(tree: store.tree, selection: nil) { id in
                        Task { await store.setCategory(selected.map(\.id), to: id) }
                    }
                } label: {
                    Label("Category", systemImage: "tag")
                }
                .menuStyle(.button)
                // Combining takes two or more.
                if selected.count >= 2 {
                    Button("Transfer", systemImage: "link") { Task { await store.link(selected.map(\.id)) } }
                        .disabled(!FinanceStore.canLink(selected))
                        .help(FinanceStore.canLink(selected) ? Text("Combine into a transfer")
                              : Text("Parts and split bookings can’t belong to a transfer"))
                    Button("Split", systemImage: "rectangle.split.3x1") {
                        guard let booking else { return }
                        Task { await store.split(booking: booking.id, parts: selected.filter { $0.id != booking.id }.map(\.id)) }
                    }
                    .disabled(!FinanceStore.canSplit(selected))
                    .help(booking.map { b in
                        FinanceStore.canSplit(selected)
                            ? Text("\(b.title) (\(store.money(b.amountCents, sign: b.amountCents > 0))) becomes the booking, the others its parts")
                            : Text("Only transactions that aren’t part of a transfer or split booking yet can be combined")
                    } ?? Text(verbatim: ""))
                }
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(selected.map(\.id)) } }
                Button("Clear selection", systemImage: "xmark") { store.selected = [] }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}
#endif

import SwiftUI

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

/// The filtered transactions of the period: a list grouped by day on iPhone and iPad, a table
/// on the Mac. Editors change categories inline, combine the ticked rows into a transfer or a
/// split booking, and undo from the toast.
struct FinanceTransactionsView: View {
    @Bindable var store: FinanceStore
    @Environment(FamilyContext.self) private var family
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
        let info = FinanceLinkInfo(list.transactions)
        #if os(macOS)
        VStack(spacing: 12) {
            header(list).padding(.horizontal, 20).padding(.top, 8)
            if list.transactions.isEmpty {
                empty.frame(maxHeight: .infinity)
            } else {
                FinanceTransactionTable(store: store, transactions: list.transactions, info: info, onEdit: onEdit)
                if list.total > list.transactions.count { more(list) }
            }
        }
        #else
        List(selection: $store.selected) {
            header(list)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
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
        .opacity(store.loadingList ? 0.6 : 1)
        .animation(.default, value: store.loadingList)
        #endif
    }

    private func header(_ list: FinanceTransactionList) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.accounts.isEmpty { FinanceAccountCards(store: store) }
            FinanceStatTiles(income: list.incomeCents, expense: list.expenseCents, currency: store.currency)
            FinanceFilterBar(store: store)
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
            .buttonStyle(.glass)
            .padding(.bottom, 8)
    }

    #if os(iOS)
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
            if let trip = store.shoppingLinks.list(for: t.date, categoryId: t.categoryId) {
                Button("Shopping list", systemImage: "cart") { family.open(.shoppingList(id: trip.id)) }
                    .tint(ModuleTint.meals)
            }
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
                    if store.shoppingLinks.list(for: t.date, categoryId: t.categoryId) != nil {
                        Image(systemName: "cart").accessibilityLabel("Shopping list of this day")
                    }
                    if !t.note.isEmpty {
                        Image(systemName: "note.text").accessibilityLabel("Note")
                    }
                    if t.imported {
                        Image(systemName: "square.and.arrow.down").accessibilityLabel("Imported from a bank statement")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The amount: green in, red out; muted for a transfer leg (it counts once, by the group's sum)
/// and a split booking (it counts through its parts).
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
    @Environment(FamilyContext.self) private var family
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
        if let trip = store.shoppingLinks.list(for: t.date, categoryId: t.categoryId) {
            Button("Shopping list of this day", systemImage: "cart") { family.open(.shoppingList(id: trip.id)) }
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

#if os(macOS)
/// The Mac's table of transactions: multiple selection, a double click edits, ⌫ deletes.
struct FinanceTransactionTable: View {
    @Bindable var store: FinanceStore
    @Environment(FamilyContext.self) private var family
    let transactions: [FinanceTransaction]
    let info: FinanceLinkInfo
    let onEdit: (FinanceTransaction) -> Void

    var body: some View {
        Table(transactions, selection: $store.selected) {
            TableColumn("Date") { t in
                Text(Day(t.date)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? t.date)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 130)
            TableColumn("Payee") { t in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.title).lineLimit(1)
                        if let trip = store.shoppingLinks.list(for: t.date, categoryId: t.categoryId) {
                            Button {
                                family.open(.shoppingList(id: trip.id))
                            } label: {
                                Label("Shopping list of this day", systemImage: "cart").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Shopping list of this day")
                        }
                        if t.imported {
                            Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary)
                                .help("Imported from a bank statement")
                        }
                    }
                    if let (icon, text) = info.detail(t, store: store) {
                        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if !t.payee.isEmpty && !t.description.isEmpty {
                        Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Category") { t in
                if store.canEdit {
                    Menu {
                        FinanceCategoryMenuItems(tree: store.tree, selection: t.categoryId,
                                                 fits: { FinanceCategoryTree.fits($0, income: t.amountCents > 0) }) { id in
                            Task { await store.setCategory([t.id], to: id) }
                        }
                    } label: {
                        FinanceCategoryLabel(category: store.category(t.categoryId))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help(store.category(t.categoryId).map { store.tree.path($0.id) } ?? "")
                } else {
                    FinanceCategoryLabel(category: store.category(t.categoryId))
                }
            }
            .width(min: 120, ideal: 180)
            TableColumn("Account") { t in
                if let account = store.account(t.accountId) { FinanceAccountChip(account: account) }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Amount") { t in
                FinanceAmountText(store: store, transaction: t)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)
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
        .onDeleteCommand {
            guard store.canEdit, !store.selected.isEmpty else { return }
            Task { await store.delete(Array(store.selected)) }
        }
        .scrollContentBackground(.hidden)
        .opacity(store.loadingList ? 0.6 : 1)
    }
}
#endif

/// The actions on several ticked transactions (Mac context menu).
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
        Button("Combine into a transfer", systemImage: "link") { Task { await store.link(selected.map(\.id)) } }
            .disabled(!FinanceStore.canLink(selected))
        Button("Combine into a split booking", systemImage: "rectangle.split.3x1") {
            guard let booking = FinanceStore.splitBooking(of: selected) else { return }
            Task { await store.split(booking: booking.id, parts: selected.filter { $0.id != booking.id }.map(\.id)) }
        }
        .disabled(!FinanceStore.canSplit(selected))
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(selected.map(\.id)) } }
    }
}

/// What the ticked rows add up to, and what can be done with them: set their category, combine
/// them into a transfer or a split booking, delete them.
struct FinanceSelectionBar: View {
    @Bindable var store: FinanceStore

    var body: some View {
        let selected = store.selectedTransactions
        let net = selected.reduce(0) { $0 + $1.amountCents }
        let booking = FinanceStore.splitBooking(of: selected)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selected.count) selected · sum \(store.money(net, sign: true))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                if selected.count >= 2 {
                    Text(net == 0 ? String(localized: "Adds up to 0: counts neither as income nor as an expense.")
                         : net > 0 ? String(localized: "Counts once, as income of \(store.money(abs(net))).")
                         : String(localized: "Counts once, as an expense of \(store.money(abs(net)))."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(selected.map(\.id)) } }
                Button("Clear selection", systemImage: "xmark") { store.selected = [] }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

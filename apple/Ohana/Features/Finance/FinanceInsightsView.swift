import SwiftUI

// What the finance overview points out (GET /finance/insights, server/lib/finance/insights.ts)
// and how its numbers open what's behind them: a category's payees (GET /finance/payees), the
// transactions of a payee, a kind, a month, a finding's transaction.

/// What the overview's numbers open; `FinanceScreen` gives them (the transactions tab, the
/// editor, the suggested transfers), the overview adds the category sheet and hands them to its
/// cards.
struct FinanceOverviewActions {
    /// The transactions matching a filter, in a period (nil: the one shown).
    var showTransactions: (FinanceFilter, FinancePeriod?) -> Void = { _, _ in }
    var edit: (FinanceTransaction) -> Void = { _ in }
    /// The suggested transfers (editors).
    var findTransfers: (() -> Void)?
    /// A category's payees.
    var category: (FinanceCategoryPick) -> Void = { _ in }

    func with(category: @escaping (FinanceCategoryPick) -> Void) -> FinanceOverviewActions {
        var copy = self
        copy.category = category
        return copy
    }
}

/// A category (nil: uncategorized) of the period, its expenses or its income.
struct FinanceCategoryPick: Identifiable, Hashable {
    var categoryId: String?
    var income: Bool
    var id: String { (income ? "income:" : "expense:") + (categoryId ?? "none") }

    /// Its transactions (subcategories included), of its kind.
    var filter: FinanceFilter {
        FinanceFilter(category: categoryId ?? "none", kind: income ? .income : .expense)
    }
}

/// How often a regular payment comes ("monthly").
@MainActor
enum FinanceInsightText {
    static func interval(_ interval: String) -> String {
        switch interval {
        case "week": String(localized: "weekly")
        case "month": String(localized: "monthly")
        case "quarter": String(localized: "quarterly")
        case "half": String(localized: "every six months")
        case "year": String(localized: "yearly")
        default: interval
        }
    }

    static func day(_ string: String) -> String {
        Day(string)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? string
    }

    static func month(_ string: String) -> String {
        Day(string)?.formatted(.dateTime.month(.abbreviated).year()) ?? string
    }

    static func category(_ store: FinanceStore, _ id: String?) -> String {
        store.category(id)?.label ?? String(localized: "Uncategorized")
    }
}

/// A finding's row: an icon, what it is, the detail, an amount; tap and a menu.
private struct FinanceInsightRow<Menu: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var detail: String?
    var amount: String?
    var amountTint: Color = .primary
    var action: () -> Void
    @ViewBuilder var menu: Menu

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: action) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.subheadline).lineLimit(2)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if let amount {
                        Text(amount).font(.subheadline.monospacedDigit()).foregroundStyle(amountTint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            menu
        }
    }
}

/// The ellipsis menu at a row's end.
private struct FinanceRowMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

// MARK: Worth a look

/// What looks wrong in the period's data: likely duplicates, transfers missing their other leg,
/// unusual amounts and categories, transfers not combined yet, bank balances that differ, what
/// has no category. Hidden while there is nothing.
struct FinanceWorthALookCard: View {
    @Bindable var store: FinanceStore
    var actions = FinanceOverviewActions()
    @State private var showsAll = false
    @State private var comparing: FinanceInsights.Issue?

    private static let shown = 5

    var body: some View {
        if let insights = store.insights, hasContent(insights) {
            CardSection("Worth a look", systemImage: "exclamationmark.magnifyingglass", tint: ModuleTint.finance) {
                content(insights)
            }
            .sheet(item: $comparing) { issue in
                FinanceDuplicateSheet(store: store, issue: issue, actions: actions)
            }
        }
    }

    private func hasContent(_ i: FinanceInsights) -> Bool {
        !i.issues.isEmpty || !i.balanceDrift.isEmpty || i.uncategorized.count > 0
            || (i.transferSuggestions > 0 && actions.findTransfers != nil)
    }

    @ViewBuilder
    private func content(_ insights: FinanceInsights) -> some View {
        ForEach(insights.balanceDrift) { drift in
            let account = store.account(drift.accountId)
            FinanceInsightRow(
                icon: "building.columns", tint: .orange,
                title: String(localized: "Balance differs: \(account?.label ?? drift.accountId)"),
                detail: String(localized: "Bank \(store.money(drift.bankCents)) · Ohana \(store.money(drift.ohanaCents)). Look for transactions not from the bank."),
                amount: store.money(drift.ohanaCents - drift.bankCents, sign: true), amountTint: .orange
            ) {
                // What the bank doesn't list: duplicates from a CSV file, typed ones.
                actions.showTransactions(FinanceFilter(account: drift.accountId, source: .notBank), nil)
            } menu: { EmptyView() }
        }
        if insights.transferSuggestions > 0, let find = actions.findTransfers {
            FinanceInsightRow(
                icon: "arrow.left.arrow.right", tint: .indigo,
                title: FinanceText.inflected("^[\(insights.transferSuggestions) transfer](inflect: true) not combined yet"),
                detail: String(localized: "Until then, money moved between your accounts counts as spent and earned."),
                amount: nil, action: find
            ) { EmptyView() }
        }
        let issues = showsAll ? insights.issues : Array(insights.issues.prefix(Self.shown))
        ForEach(issues) { issue in
            issueRow(issue)
        }
        if insights.issues.count > Self.shown {
            Button(showsAll ? String(localized: "Show fewer") : String(localized: "Show all \(insights.issues.count)")) {
                withAnimation { showsAll.toggle() }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        if insights.uncategorized.count > 0 {
            let u = insights.uncategorized
            FinanceInsightRow(
                icon: "tag.slash", tint: .secondary,
                title: FinanceText.inflected("^[\(u.count) transaction](inflect: true) without a category"),
                detail: u.incomeCents > 0
                    ? String(localized: "\(store.money(u.expenseCents)) out, \(store.money(u.incomeCents)) in")
                    : nil,
                amount: u.expenseCents > 0 ? store.money(u.expenseCents) : nil
            ) {
                actions.showTransactions(FinanceFilter(category: "none"), nil)
            } menu: { EmptyView() }
        }
        if insights.dismissed > 0 {
            Text(FinanceText.inflected("^[\(insights.dismissed) finding](inflect: true) marked as fine"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func issueRow(_ issue: FinanceInsights.Issue) -> some View {
        if let t = issue.transactions.first {
            let look = describe(issue, t)
            FinanceInsightRow(icon: look.icon, tint: look.tint, title: look.title, detail: look.detail,
                              amount: store.money(t.amountCents, sign: t.amountCents > 0)) {
                if issue.kind == "duplicate" { comparing = issue } else { actions.edit(t) }
            } menu: {
                FinanceRowMenu {
                    if issue.kind == "duplicate" {
                        Button("Compare", systemImage: "rectangle.split.2x1") { comparing = issue }
                    }
                    ForEach(issue.transactions) { tx in
                        Button(issue.transactions.count > 1 ? String(localized: "Edit \(FinanceInsightText.day(tx.date))") : String(localized: "Edit"),
                               systemImage: "pencil") { actions.edit(tx) }
                    }
                    if store.canEdit {
                        Divider()
                        Button(issue.kind == "duplicate" ? String(localized: "Not a Duplicate") : String(localized: "Looks Fine"),
                               systemImage: "checkmark.circle") {
                            Task { await store.dismissInsight(issue.key) }
                        }
                    }
                }
            }
        }
    }

    private func describe(_ issue: FinanceInsights.Issue, _ t: FinanceTransaction)
        -> (icon: String, tint: Color, title: String, detail: String) {
        switch issue.kind {
        case "duplicate":
            let days = issue.transactions.map { FinanceInsightText.day($0.date) }
            let origins = issue.transactions.compactMap { $0.origin?.title }
            return ("doc.on.doc", Color.red, String(localized: "Possibly booked twice: \(t.title)"),
                    ([days.joined(separator: " · ")] + (Set(origins).count > 1 ? [origins.joined(separator: " / ")] : []))
                        .joined(separator: " — "))
        case "unpaired":
            return ("arrow.left.arrow.right.circle", Color.indigo, String(localized: "Transfer without its other side: \(t.title)"),
                    t.amountCents < 0
                        ? String(localized: "\(FinanceInsightText.day(t.date)) · counted as an expense")
                        : String(localized: "\(FinanceInsightText.day(t.date)) · counted as income"))
        case "amount":
            return ("exclamationmark.triangle", Color.orange, String(localized: "Unusually high: \(t.title)"),
                    String(localized: "\(FinanceInsightText.day(t.date)) · usually \(store.money(issue.usualCents ?? 0))"))
        default:
            return ("tag", Color.purple, String(localized: "Unusual category: \(t.title)"),
                    String(localized: "In “\(FinanceInsightText.category(store, t.categoryId))”, usually “\(FinanceInsightText.category(store, issue.usualCategoryId))”"))
        }
    }
}

/// Two transactions that may be one booking twice, side by side: delete one, or mark them as
/// two.
struct FinanceDuplicateSheet: View {
    @Bindable var store: FinanceStore
    let issue: FinanceInsights.Issue
    var actions = FinanceOverviewActions()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Same amount, a day or two apart and the same payee. If it's one booking, delete the copy; the bank's row is usually the one to keep.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(issue.transactions) { t in
                    Section {
                        LabeledContent("Date", value: FinanceInsightText.day(t.date))
                        LabeledContent("Amount", value: store.money(t.amountCents, sign: t.amountCents > 0))
                        if !t.payee.isEmpty { LabeledContent("Payee", value: t.payee) }
                        if !t.description.isEmpty {
                            LabeledContent("Description") { Text(t.description).lineLimit(3) }
                        }
                        LabeledContent("Account", value: store.account(t.accountId)?.label ?? String(localized: "Without account"))
                        LabeledContent("Category", value: FinanceInsightText.category(store, t.categoryId))
                        if let origin = t.origin { LabeledContent("Origin", value: origin.title) }
                        if store.canEdit {
                            Button("Delete This One", systemImage: "trash", role: .destructive) {
                                Task {
                                    await store.delete([t.id])
                                    dismiss()
                                }
                            }
                        }
                        Button("Edit", systemImage: "pencil") {
                            dismiss()
                            actions.edit(t)
                        }
                    }
                }
                if store.canEdit {
                    Section {
                        Button("Not a Duplicate", systemImage: "checkmark.circle") {
                            Task {
                                await store.dismissInsight(issue.key)
                                dismiss()
                            }
                        }
                    } footer: {
                        Text("Both stay, and Ohana doesn't point them out again.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Possibly Booked Twice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .financeSheetFrame(minWidth: 460, minHeight: 520)
    }
}

// MARK: What changed

/// The categories whose spending per month grew most against the family's usual month (the
/// months before the period), each with the payees behind it.
struct FinanceChangesCard: View {
    @Bindable var store: FinanceStore
    var actions = FinanceOverviewActions()

    var body: some View {
        if let insights = store.insights, let baseline = insights.baseline {
            CardSection("What changed", systemImage: "chart.line.uptrend.xyaxis", tint: ModuleTint.finance) {
                Text("per month").font(.caption).foregroundStyle(.secondary)
            } content: {
                Text(caption(insights, baseline))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if insights.changes.isEmpty {
                    Text("No category grew noticeably.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(insights.changes) { change in row(change) }
                }
            }
        }
    }

    private func caption(_ insights: FinanceInsights, _ baseline: FinanceInsights.Baseline) -> String {
        let usual = FinanceText.inflected("Compared with the average of ^[\(baseline.months) month](inflect: true) before (\(FinanceInsightText.month(baseline.from)) – \(FinanceInsightText.month(baseline.to)))")
        return insights.partial ? usual + " · " + String(localized: "this period so far") : usual
    }

    private func row(_ change: FinanceInsights.Change) -> some View {
        let category = store.category(change.categoryId)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                actions.category(FinanceCategoryPick(categoryId: change.categoryId, income: false))
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    if let category { FinanceColorDot(hex: category.color) }
                    Text(FinanceInsightText.category(store, change.categoryId)).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(store.money(change.deltaCents, sign: true, whole: true))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.red)
                        Text(verbatim: "\(store.money(change.usualCents, whole: true)) → \(store.money(change.currentCents, whole: true))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            ForEach(change.payees) { payee in
                Button {
                    actions.showTransactions(FinanceFilter(category: change.categoryId ?? "none", kind: .expense,
                                                           payee: payee.key, payeeName: payee.name), nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").imageScale(.small).foregroundStyle(.tertiary)
                        Text(payee.name).lineLimit(1)
                        Text(verbatim: "\(payee.count)×").foregroundStyle(.secondary)
                        Spacer()
                        Text(store.money(payee.deltaCents, sign: true, whole: true)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.leading, 6)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Regular payments

/// Payments that come back regularly (subscriptions, insurance, rent), by what they cost a year,
/// with price changes, new ones and those that stopped.
struct FinanceRecurringCard: View {
    @Bindable var store: FinanceStore
    var actions = FinanceOverviewActions()
    @State private var showsAll = false

    private static let shown = 8

    var body: some View {
        if let insights = store.insights, !insights.recurring.isEmpty {
            CardSection("Regular payments", systemImage: "repeat", tint: ModuleTint.finance) {
                Text("\(store.money(insights.recurringYearlyCents, whole: true)) a year")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } content: {
                let items = showsAll ? insights.recurring : Array(insights.recurring.prefix(Self.shown))
                ForEach(items) { r in row(r) }
                if insights.recurring.count > Self.shown {
                    Button(showsAll ? String(localized: "Show fewer") : String(localized: "Show all \(insights.recurring.count)")) {
                        withAnimation { showsAll.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
        }
    }

    private func row(_ r: FinanceInsights.Recurring) -> some View {
        let stopped = r.status == "stopped"
        return FinanceInsightRow(
            icon: stopped ? "pause.circle" : r.change != nil ? "arrow.up.circle" : r.status == "new" ? "sparkle" : "repeat",
            tint: stopped ? .secondary : r.change != nil ? .orange : r.status == "new" ? .blue : ModuleTint.finance,
            title: r.name,
            detail: detail(r),
            amount: "\(store.money(r.yearlyCents, whole: true))",
            amountTint: stopped ? .secondary : .primary
        ) {
            // Its history: all time.
            actions.showTransactions(FinanceFilter(payee: r.payee, payeeName: r.name),
                                     FinancePeriod(mode: .all, year: store.period.year, month: store.period.month))
        } menu: {
            if store.canEdit {
                FinanceRowMenu {
                    Button("Not a Regular Payment", systemImage: "xmark.circle") {
                        Task { await store.dismissInsight(r.key) }
                    }
                }
            }
        }
        .opacity(stopped ? 0.75 : 1)
    }

    private func detail(_ r: FinanceInsights.Recurring) -> String {
        var parts = ["\(FinanceInsightText.interval(r.interval)) · \(store.money(r.amountCents))"]
        if let change = r.change {
            parts.append(String(localized: "was \(store.money(change.previousCents)) until \(FinanceInsightText.month(change.since))"))
        }
        switch r.status {
        case "stopped": parts.append(String(localized: "last on \(FinanceInsightText.day(r.lastDay)): stopped?"))
        case "new": parts.append(String(localized: "new since \(FinanceInsightText.month(r.firstDay))"))
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Adds up

/// Payees with many small expenses in the period: what never stands out on its own.
struct FinanceFrequentCard: View {
    @Bindable var store: FinanceStore
    var actions = FinanceOverviewActions()

    var body: some View {
        if let insights = store.insights, !insights.frequent.isEmpty {
            CardSection("Small amounts that add up", systemImage: "cart", tint: ModuleTint.finance) {
                ForEach(insights.frequent) { f in
                    FinanceInsightRow(
                        icon: "circle.grid.3x3", tint: ModuleTint.finance, title: f.name,
                        detail: insights.months > 1
                            ? String(localized: "\(f.count)× · Ø \(store.money(f.averageCents)) · \(store.money(f.perMonthCents, whole: true)) a month")
                            : String(localized: "\(f.count)× · Ø \(store.money(f.averageCents))"),
                        amount: store.money(f.totalCents, whole: true)
                    ) {
                        actions.showTransactions(FinanceFilter(kind: .expense, payee: f.payee, payeeName: f.name), nil)
                    } menu: { EmptyView() }
                }
            }
        }
    }
}

// MARK: A category's payees

/// A category of the period: its total and its payees (largest first), each opening its
/// transactions, and all of them.
struct FinanceCategoryDetailSheet: View {
    @Bindable var store: FinanceStore
    let pick: FinanceCategoryPick
    let show: (FinanceFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loaded = .loading

    private enum Loaded {
        case loading
        case done(FinancePayeeList)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        .listRowBackground(Color.clear)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .done(let list):
                    content(list)
                }
                Section {
                    Button {
                        show(pick.filter)
                    } label: {
                        Label("Show All Transactions", systemImage: "list.bullet")
                    }
                }
            }
            .navigationTitle(FinanceInsightText.category(store, pick.categoryId))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
        .financeSheetFrame(minWidth: 440, minHeight: 480)
    }

    private func load() async {
        do {
            state = .done(try await store.payees(category: pick.categoryId, income: pick.income))
        } catch {
            if !(error is CancellationError) { state = .failed(error.localizedDescription) }
        }
    }

    @ViewBuilder
    private func content(_ list: FinancePayeeList) -> some View {
        let cents = { (p: FinancePayee) in pick.income ? p.incomeCents : p.expenseCents }
        let total = list.payees.reduce(0) { $0 + cents($1) }
        let max = list.payees.map(cents).max() ?? 1
        Section {
            ForEach(list.payees) { payee in
                Button {
                    var filter = pick.filter
                    filter.payee = payee.key
                    filter.payeeName = payee.name
                    show(filter)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(payee.name.isEmpty ? String(localized: "No payee") : payee.name).lineLimit(1)
                            Text(verbatim: "\(payee.count)×").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(store.money(cents(payee))).monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(ModuleTint.finance.opacity(0.6))
                                .frame(width: Swift.max(3, geo.size.width * CGFloat(cents(payee)) / CGFloat(Swift.max(max, 1))), height: 5)
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        } header: {
            HStack {
                Text(pick.income ? LocalizedStringKey("Income by payee") : LocalizedStringKey("Expenses by payee"))
                Spacer()
                Text(store.money(total)).monospacedDigit()
            }
        } footer: {
            if list.more > 0 {
                Text(FinanceText.inflected("And ^[\(list.more) more payee](inflect: true)"))
            }
        }
        if list.payees.isEmpty {
            Text("No transactions in this period yet.").foregroundStyle(.secondary)
        }
    }
}

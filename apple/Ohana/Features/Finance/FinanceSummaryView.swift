import Charts
import SwiftUI

/// The finance overview of the period (summary-view.tsx): headline numbers, the comparison
/// with other periods, the statistic average, income and expenses per month, and where the
/// money went.
struct FinanceSummaryView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        ScrollView {
            Group {
                if let summary = store.summary {
                    content(summary)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding()
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .task { await store.loadSummary() }
    }

    @ViewBuilder
    private func content(_ summary: FinanceSummary) -> some View {
        if summary.count == 0 {
            // Nothing in the period, but maybe in those it is compared with.
            VStack(spacing: 16) {
                ContentUnavailableView("No transactions in this period yet.", systemImage: "chart.bar")
                FinanceComparisonCard(store: store)
                FinanceBenchmarkCard(store: store)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        FinanceStatTiles(income: summary.incomeCents, expense: summary.expenseCents, currency: summary.currency)
                        FinanceComparisonCard(store: store)
                        FinanceBenchmarkCard(store: store)
                    }
                    VStack(spacing: 16) {
                        if store.period.mode != .month { FinanceMonthlyChart(store: store, summary: summary) }
                        FinanceCategoryBreakdown(store: store, summary: summary)
                    }
                }
                .frame(minWidth: 860)
                VStack(spacing: 16) {
                    FinanceStatTiles(income: summary.incomeCents, expense: summary.expenseCents, currency: summary.currency)
                    FinanceComparisonCard(store: store)
                    FinanceBenchmarkCard(store: store)
                    if store.period.mode != .month { FinanceMonthlyChart(store: store, summary: summary) }
                    FinanceCategoryBreakdown(store: store, summary: summary)
                }
            }
        }
    }
}

// MARK: Comparison

/// The period next to others, all per month (comparison-view.tsx): a month with the month
/// before, a year's average completed month with the year before's, all time's average month.
struct FinanceComparisonCard: View {
    @Bindable var store: FinanceStore

    private struct Row: Identifiable {
        var id: String
        var label: String
        /// Higher is better (income, the balance) or worse (expenses).
        var higherIsGood: Bool
        var strong = false
        var get: (Values) -> Int
    }

    struct Values {
        var income: Int
        var expense: Int
        var byIncome: [String: Int]
        var byExpense: [String: Int]
    }

    var body: some View {
        CardSection("Comparison", systemImage: "arrow.left.arrow.right", tint: ModuleTint.finance) {
            Text("all per month").font(.caption).foregroundStyle(.secondary)
        } content: {
            if let comparisons = store.comparisons {
                table(comparisons)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
    }

    private func values(_ c: FinanceComparison) -> Values? {
        guard c.months > 0 else { return nil }
        let (income, expense) = c.byTop(store.tree)
        return Values(income: c.incomeCents, expense: c.expenseCents, byIncome: income, byExpense: expense)
    }

    private func label(_ id: String) -> String {
        store.category(id.isEmpty ? nil : id)?.label ?? String(localized: "Uncategorized")
    }

    /// The categories with an amount in any column, largest (in the first column that has one) first.
    private func categoryRows(_ columns: [Values?], income: Bool) -> [Row] {
        func side(_ v: Values) -> [String: Int] { income ? v.byIncome : v.byExpense }
        let keys = Set(columns.flatMap { $0.map { Array(side($0).keys) } ?? [] })
        func sizes(_ k: String) -> [Int] { columns.map { $0.flatMap { side($0)[k] } ?? 0 } }
        return keys.sorted { a, b in
            let sa = sizes(a), sb = sizes(b)
            guard let i = sa.indices.first(where: { sa[$0] != sb[$0] }) else { return a < b }
            return sa[i] > sb[i]
        }
        .map { k in Row(id: (income ? "income:" : "expense:") + k, label: label(k), higherIsGood: income) { side($0)[k] ?? 0 } }
    }

    @ViewBuilder
    private func table(_ comparisons: [FinanceComparison]) -> some View {
        let columns = comparisons.map(values)
        let totals = [
            Row(id: "income", label: String(localized: "Income"), higherIsGood: true) { $0.income },
            Row(id: "expense", label: String(localized: "Expenses"), higherIsGood: false) { $0.expense },
            Row(id: "net", label: String(localized: "Net"), higherIsGood: true, strong: true) { $0.income - $0.expense },
        ]
        let groups: [(String?, [Row])] = [
            (nil, totals),
            (String(localized: "Expenses by category"), categoryRows(columns, income: false)),
            (String(localized: "Income by category"), categoryRows(columns, income: true)),
        ].filter { !$0.1.isEmpty }
        ScrollView(.horizontal) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(Array(comparisons.enumerated()), id: \.offset) { i, c in
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(c.key.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(i == 0 ? .primary : .secondary)
                            Text(c.detail ?? String(localized: "nothing to compare yet"))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    if let title = group.0 {
                        GridRow {
                            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .gridCellColumns(columns.count + 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(group.1) { row in
                        GridRow(alignment: .top) {
                            Text(row.label)
                                .font(row.strong ? .subheadline.weight(.semibold) : .subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: 180, alignment: .leading)
                                .gridColumnAlignment(.leading)
                            ForEach(Array(columns.enumerated()), id: \.offset) { i, v in
                                cell(row, value: v.map(row.get), current: columns.first.flatMap { $0 }.map(row.get), first: i == 0,
                                     firstTitle: comparisons[0].key.title)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        if columns.count > 1, columns.first.flatMap({ $0 }) != nil {
            Text("Ø = average of the completed months. The percentages show how “\(comparisons[0].key.title)” differs from each column.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cell(_ row: Row, value: Int?, current: Int?, first: Bool, firstTitle: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let value {
                Text(store.money(value, sign: row.id == "net", whole: true))
                    .font(row.strong || first ? .subheadline.weight(.semibold).monospacedDigit() : .subheadline.monospacedDigit())
                    .foregroundStyle(row.id == "net" && value < 0 ? .red : first || row.strong ? .primary : .secondary)
                if !first, let delta = delta(row, base: current, value: value) {
                    Text(delta.0).font(.caption2).foregroundStyle(delta.1 ? .green : .red)
                        .help(Text("\(firstTitle): \(store.money((current ?? 0) - value, sign: true, whole: true)) per month"))
                }
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }
        }
    }

    /// How the first column differs from this one, in percent of this one; and whether that is good.
    private func delta(_ row: Row, base: Int?, value: Int) -> (String, Bool)? {
        guard let base, value != 0, base != value else { return nil }
        let pct = Int((Double(base - value) / Double(abs(value)) * 100).rounded())
        guard pct != 0 else { return nil }
        let better = row.higherIsGood ? base > value : base < value
        return (pct > 0 ? "+\(pct) %" : "−\(-pct) %", better)
    }
}

// MARK: Benchmark

/// Where the period is within the statistic average the family set (benchmark-view.tsx):
/// income, expenses and the top-level categories that have a range, each as a band with the
/// period's value per month on it. Hidden while none is set.
struct FinanceBenchmarkCard: View {
    @Bindable var store: FinanceStore
    @Environment(FamilyContext.self) private var family

    private struct Row: Identifiable {
        var id: String
        var label: String
        var range: FinanceCentsRange
        var cents: Int?
        var higherIsGood: Bool
    }

    var body: some View {
        if let benchmark = store.overview?.benchmark, let comparisons = store.comparisons, let first = comparisons.first {
            let rows = rows(benchmark, first)
            CardSection("Statistic average", systemImage: "chart.bar.xaxis", tint: ModuleTint.finance) {
                Text("all per month").font(.caption).foregroundStyle(.secondary)
            } content: {
                let basis = first.months > 0
                    ? "\(first.key.title) (\(first.detail ?? ""))"
                    : String(localized: "nothing to compare yet")
                Text([benchmark.label, basis].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in rowView(row) }
                HStack(spacing: 14) {
                    Label { Text("statistic range") } icon: {
                        RoundedRectangle(cornerRadius: 3).fill(ModuleTint.finance.opacity(0.35)).frame(width: 16, height: 9)
                    }
                    Label { Text(first.key.title) } icon: {
                        Capsule().fill(.primary).frame(width: 3, height: 12)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if store.canEdit, let overview = store.overview, overview.benchmark == nil {
            // None set yet: it's set in Settings → Finance.
            Button {
                family.open(.settings(.finance))
            } label: {
                Label("Compare with a statistic average…", systemImage: "chart.bar.xaxis")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            .help("Set household figures from the statistics office in the finance settings")
        }
    }

    private func rows(_ benchmark: FinanceBenchmark, _ column: FinanceComparison) -> [Row] {
        let values = column.months > 0 ? column.byTop(store.tree) : nil
        var rows: [Row] = []
        if let income = benchmark.income {
            rows.append(Row(id: "income", label: String(localized: "Income"), range: income,
                            cents: values == nil ? nil : column.incomeCents, higherIsGood: true))
        }
        if let expense = benchmark.expense {
            rows.append(Row(id: "expense", label: String(localized: "Expenses"), range: expense,
                            cents: values == nil ? nil : column.expenseCents, higherIsGood: false))
        }
        let own = Dictionary(benchmark.categories.map { ($0.categoryId, $0.range) }) { _, b in b }
        for node in store.tree.children(of: nil) {
            guard let range = Self.categoryRange(store.tree, own: own, id: node.id) else { continue }
            let income = node.category.kind == .income
            rows.append(Row(id: node.id, label: node.category.label, range: range,
                            cents: values.map { (income ? $0.income : $0.expense)[node.id] ?? 0 }, higherIsGood: income))
        }
        return rows
    }

    /// A top-level category's range: its own, or else the sum of those set on its subcategories.
    static func categoryRange(_ tree: FinanceCategoryTree, own: [String: FinanceCentsRange], id: String) -> FinanceCentsRange? {
        if let range = own[id] { return range }
        let below = tree.subtree(id).compactMap { own[$0] }
        guard !below.isEmpty else { return nil }
        return FinanceCentsRange(lowCents: below.reduce(0) { $0 + $1.lowCents }, highCents: below.reduce(0) { $0 + $1.highCents })
    }

    private func span(_ r: FinanceCentsRange) -> String {
        r.lowCents == r.highCents ? store.money(r.lowCents, whole: true)
            : "\(store.money(r.lowCents, whole: true)) – \(store.money(r.highCents, whole: true))"
    }

    private func rowView(_ row: Row) -> some View {
        let standing = row.cents.map { FinanceStanding.of($0, range: row.range) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label).lineLimit(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.cents.map { store.money($0, whole: true) } ?? "—")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    if let standing {
                        let tone = standing.tone(higherIsGood: row.higherIsGood)
                        Text(standing.text).font(.caption2)
                            .foregroundStyle(tone == nil ? Color.secondary : tone! ? Color.green : Color.red)
                    }
                }
            }
            FinanceRangeBar(range: row.range, cents: row.cents)
            Text(span(row.range)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The range as a band on a track, the value as a line across it; from 0 to a bit beyond the
/// larger of the two.
struct FinanceRangeBar: View {
    let range: FinanceCentsRange
    let cents: Int?

    var body: some View {
        GeometryReader { geo in
            let maxValue = Double(max(range.highCents, cents ?? 0)) * 1.25
            let scale = maxValue > 0 ? geo.size.width / maxValue : 0
            let x = { (v: Int) in CGFloat(Double(v)) * scale }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)
                if range.lowCents == range.highCents {
                    Capsule().fill(ModuleTint.finance.opacity(0.7)).frame(width: 4, height: 16)
                        .offset(x: x(range.lowCents) - 2)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(ModuleTint.finance.opacity(0.35))
                        .frame(width: max(2, x(range.highCents - range.lowCents)), height: 12)
                        .offset(x: x(range.lowCents))
                }
                if let cents {
                    Capsule().fill(.primary).frame(width: 3, height: 20).offset(x: x(cents) - 1.5)
                }
            }
            .frame(height: 20)
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: Per month

/// Income and expenses per month (a year: all 12 months; all time: the months with transactions).
struct FinanceMonthlyChart: View {
    @Bindable var store: FinanceStore
    let summary: FinanceSummary
    @State private var selected: Date?
    /// The same numbers as a table (screen readers, exact amounts); remembered per device.
    @AppStorage("finance.monthlyTable") private var asTable = false

    /// Every month of the range: a whole year (months without transactions as 0), or all time's
    /// months with transactions (summary-view.tsx monthsOf).
    static func months(_ summary: FinanceSummary, period: FinancePeriod) -> [FinanceSummaryMonth] {
        guard period.mode == .year else { return summary.months }
        let byMonth = Dictionary(summary.months.map { ($0.month, $0) }) { a, _ in a }
        return (1...12).map { m in
            let key = String(format: "%04d-%02d", period.year, m)
            return byMonth[key] ?? FinanceSummaryMonth(month: key, incomeCents: 0, expenseCents: 0)
        }
    }

    var body: some View {
        let months = Self.months(summary, period: store.period)
        CardSection("Per month", systemImage: "chart.bar", tint: ModuleTint.finance) {
            chart(months)
            DisclosureGroup("As table", isExpanded: $asTable) {
                // Phones: scrolls sideways when the amounts don't fit.
                ViewThatFits(in: .horizontal) {
                    table(months)
                    ScrollView(.horizontal) { table(months) }.scrollIndicators(.hidden)
                }
            }
            .font(.callout)
        }
    }

    /// Month, income, expenses and net per row (summary-view.tsx's "as table").
    private func table(_ months: [FinanceSummaryMonth]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Month").gridColumnAlignment(.leading)
                Text("Income")
                Text("Expenses")
                Text("Net")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            ForEach(months) { m in
                Divider().gridCellUnsizedAxes(.horizontal)
                let net = m.incomeCents - m.expenseCents
                GridRow {
                    Text(FinanceDates.monthDate(m.month).formatted(.dateTime.month(.abbreviated).year()))
                        .lineLimit(1)
                    Text(store.money(m.incomeCents))
                    Text(store.money(m.expenseCents))
                    Text(store.money(net, sign: true)).foregroundStyle(net < 0 ? .red : .primary)
                }
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 8)
    }

    private func chart(_ months: [FinanceSummaryMonth]) -> some View {
        let income = String(localized: "Income"), expenses = String(localized: "Expenses")
        return Group {
            Chart {
                ForEach(months) { m in
                    BarMark(x: .value("Month", FinanceDates.monthDate(m.month), unit: .month),
                            y: .value("Amount", Double(m.incomeCents) / 100))
                        .foregroundStyle(by: .value("Kind", income))
                        .position(by: .value("Kind", income))
                    BarMark(x: .value("Month", FinanceDates.monthDate(m.month), unit: .month),
                            y: .value("Amount", Double(m.expenseCents) / 100))
                        .foregroundStyle(by: .value("Kind", expenses))
                        .position(by: .value("Kind", expenses))
                }
                if let month = selectedMonth(months) {
                    RuleMark(x: .value("Month", FinanceDates.monthDate(month.month), unit: .month))
                        .foregroundStyle(.secondary.opacity(0.3))
                        .zIndex(-1)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(month)
                        }
                }
            }
            .chartForegroundStyleScale([income: Color.green, expenses: Color.orange])
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Decimal(v).formatted(.currency(code: store.currency).notation(.compactName).precision(.fractionLength(0))))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: max(1, months.count / 12))) { _ in
                    AxisValueLabel(format: store.period.mode == .all ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.narrow))
                }
            }
            .frame(height: 220)
        }
    }

    private func selectedMonth(_ months: [FinanceSummaryMonth]) -> FinanceSummaryMonth? {
        guard let selected else { return nil }
        let day = Day(selected)
        let key = String(format: "%04d-%02d", day.year, day.month)
        return months.first { $0.month == key }
    }

    private func tooltip(_ m: FinanceSummaryMonth) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(FinanceDates.monthDate(m.month).formatted(.dateTime.month(.wide).year())).font(.caption.weight(.semibold))
            LabeledContent("Income", value: store.money(m.incomeCents))
            LabeledContent("Expenses", value: store.money(m.expenseCents))
            LabeledContent("Net", value: store.money(m.incomeCents - m.expenseCents, sign: true))
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .frame(width: 200)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: By category

/// Where the money went (or came from): one row per top-level category, largest first, its
/// subcategories folded in and opening below it; a donut of the top level.
struct FinanceCategoryBreakdown: View {
    @Bindable var store: FinanceStore
    let summary: FinanceSummary
    @State private var income = false

    struct Row: Identifiable, Hashable {
        var id: String
        var label: String
        var color: String?
        var cents: Int
        var depth: Int
        var children: [Row]
        var direct = false
    }

    /// The rows (with their open-able children) and the total.
    static func rows(_ summary: FinanceSummary, tree: FinanceCategoryTree, income: Bool) -> [Row] {
        var own: [String: Int] = [:]
        var uncategorized = 0
        for c in summary.categories {
            let cents = income ? c.incomeCents : c.expenseCents
            if let id = c.categoryId, tree.node(id) != nil { own[id, default: 0] += cents } else { uncategorized += cents }
        }
        var totals: [String: Int] = [:]
        func sum(_ id: String) -> Int {
            let cents = (tree.node(id)?.children ?? []).reduce(own[id] ?? 0) { $0 + sum($1) }
            totals[id] = cents
            return cents
        }
        tree.roots.forEach { _ = sum($0) }
        func rows(_ ids: [String], depth: Int) -> [Row] {
            ids.compactMap { id -> Row? in
                guard let node = tree.node(id), let cents = totals[id], cents > 0 else { return nil }
                var children = rows(node.children, depth: depth + 1)
                if !children.isEmpty, let direct = own[id], direct > 0 {
                    children.append(Row(id: id + ":direct", label: String(localized: "Directly in “\(node.category.name)”"),
                                        color: nil, cents: direct, depth: depth + 1, children: [], direct: true))
                }
                return Row(id: id, label: node.category.label, color: node.category.color, cents: cents, depth: depth,
                           children: children.sorted { $0.cents > $1.cents })
            }
            .sorted { $0.cents > $1.cents }
        }
        var top = rows(tree.roots, depth: 0)
        if uncategorized > 0 {
            top.append(Row(id: "none", label: String(localized: "Uncategorized"), color: nil, cents: uncategorized, depth: 0, children: []))
            top.sort { $0.cents > $1.cents }
        }
        return top
    }

    var body: some View {
        let rows = Self.rows(summary, tree: store.tree, income: income)
        let total = rows.reduce(0) { $0 + $1.cents }
        CardSection("By category", systemImage: "chart.pie", tint: ModuleTint.finance) {
            Picker("Kind", selection: $income) {
                Text("Expenses").tag(false)
                Text("Income").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if rows.isEmpty {
                Text("No transactions in this period yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        donut(rows, total: total).frame(width: 180, height: 180)
                        list(rows, total: total).frame(minWidth: 320)
                    }
                    VStack(spacing: 16) {
                        donut(rows, total: total).frame(height: 180)
                        list(rows, total: total)
                    }
                }
            }
        }
    }

    private func donut(_ rows: [Row], total: Int) -> some View {
        Chart(rows) { row in
            SectorMark(angle: .value("Amount", row.cents), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(row.color.map(FinanceColor.color) ?? Color.secondary.opacity(0.4))
        }
        .chartBackground { _ in
            VStack(spacing: 0) {
                Text(income ? String(localized: "Income") : String(localized: "Expenses")).font(.caption).foregroundStyle(.secondary)
                Text(store.money(total, whole: true)).font(.headline.monospacedDigit())
            }
        }
    }

    private func list(_ rows: [Row], total: Int) -> some View {
        let max = rows.first?.cents ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                FinanceBreakdownRowView(store: store, row: row, total: total, max: max)
            }
        }
    }
}

/// A row of the breakdown; a category with subcategories opens to show them.
struct FinanceBreakdownRowView: View {
    @Bindable var store: FinanceStore
    let row: FinanceCategoryBreakdown.Row
    let total: Int
    let max: Int
    @State private var open = false

    var body: some View {
        if row.children.isEmpty {
            line
        } else {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(row.children) { child in
                        FinanceBreakdownRowView(store: store, row: child, total: total, max: max)
                    }
                }
                .padding(.top, 6)
            } label: {
                line
            }
        }
    }

    private var line: some View {
        let share = total > 0 ? Int((Double(row.cents) / Double(total) * 100).rounded()) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                if let color = row.color { FinanceColorDot(hex: color) }
                Text(row.label)
                    .italic(row.direct)
                    .foregroundStyle(row.depth > 0 ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Text(store.money(row.cents)).font(.subheadline.monospacedDigit())
                Text(verbatim: "\(share) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            GeometryReader { geo in
                Capsule()
                    .fill((row.color.map(FinanceColor.color) ?? .secondary).opacity(row.depth > 0 ? 0.55 : 0.9))
                    .frame(width: Swift.max(3, geo.size.width * CGFloat(row.cents) / CGFloat(Swift.max(max, 1))), height: 6)
            }
            .frame(height: 6)
        }
        .padding(.leading, CGFloat(min(row.depth, 6)) * 12)
    }
}

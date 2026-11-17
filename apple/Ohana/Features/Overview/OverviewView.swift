import SwiftUI

/// The family overview (the web app's app/(app)/f/[familyId]/page.tsx): one dashboard over all
/// modules: today, the meals, today's chores, the next birthdays, what comes up, this month's
/// finances and the appointment searches' latest finds, as content cards. A card's header opens
/// its module; each row opens its exact place (a day of the calendar, a recipe, a category's
/// transactions, an appointment slot, a chore). What belongs to a
/// module the server has off doesn't show; any card can be hidden on this device (its context
/// menu, the toolbar's Cards menu: `OverviewCardKind`).
struct OverviewView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<OverviewDashboard> = .idle
    @AppStorage(OverviewCardKind.hiddenKey) private var hidden = ""
    /// The week ahead, pushed (its card, a notification's link).
    @State private var showsWeekAhead = false

    /// Every area's revision: anything that changes elsewhere reloads the overview.
    private var reloadKey: [Int] { DataArea.allCases.map { family.revision($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LoadStateView(state: state, retry: load) { dashboard in
                    OverviewGrid(dashboard: dashboard)
                }
                .frame(minHeight: state.value == nil ? 280 : nil)
            }
            .padding()
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .ohanaBackground(ModuleTint.overview)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Menu {
                    Section("Cards") {
                        ForEach(OverviewCardKind.available(family)) { kind in
                            Toggle(isOn: shows(kind)) { Label(kind.title, systemImage: kind.systemImage) }
                        }
                    }
                    if !OverviewCardKind.hidden(in: hidden).isEmpty {
                        Button("Show All Cards", systemImage: "eye") { hidden = "" }
                    }
                } label: {
                    Label("Cards", systemImage: "rectangle.grid.2x2")
                }
                .help("Choose the cards to show")
            }
        }
        .refreshable { await load() }
        .task(id: reloadKey) { await load() }
        .navigationDestination(isPresented: $showsWeekAhead) { WeekAheadView().shellPageItems() }
        .onChange(of: family.pendingRoute, initial: true) {
            // The week ahead is pushed; the overview itself pops back to it.
            guard let route = family.takeRoute(for: .overview) else { return }
            showsWeekAhead = route == .weekAhead
        }
    }

    private func load() async {
        await LoadState.run($state, Self.request(family.api))
    }

    private func shows(_ kind: OverviewCardKind) -> Binding<Bool> {
        Binding(get: { !OverviewCardKind.hidden(in: hidden).contains(kind) },
                set: { hidden = OverviewCardKind.setting(kind, hidden: !$0, in: hidden) })
    }

    /// The overview's GET (the prefetch asks the same): filed without `today`, so yesterday's
    /// copy still shows offline.
    static func request(_ api: FamilyAPI) -> CachedGet<OverviewDashboard> {
        api.cached("/overview", query: ["today": Day.today.description], key: "/overview")
    }
}

private struct OverviewGrid: View {
    @Environment(FamilyContext.self) private var family
    @AppStorage(OverviewCardKind.hiddenKey) private var hidden = ""
    let dashboard: OverviewDashboard

    /// The cards to show, in order: those of modules the family has on and not hidden here, and
    /// only those with something to say where an empty one would be noise.
    private var cards: [OverviewCardKind] {
        let hidden = OverviewCardKind.hidden(in: self.hidden)
        return OverviewCardKind.available(family).filter { kind in
            guard !hidden.contains(kind) else { return false }
            switch kind {
            case .weekAhead: return dashboard.weekAhead?.hasIssues == true
            case .birthdays: return !dashboard.birthdays.isEmpty
            default: return true
            }
        }
    }

    var body: some View {
        let shown = cards
        if shown.isEmpty {
            ContentUnavailableView {
                Label("All cards are hidden", systemImage: "rectangle.grid.2x2")
            } actions: {
                Button("Show All Cards") { hidden = "" }
            }
        } else {
            OverviewColumns {
                ForEach(shown) { kind in
                    card(kind)
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ kind: OverviewCardKind) -> some View {
        switch kind {
        case .today: OverviewTodayCard(dashboard: dashboard)
        case .weekAhead: if let weekAhead = dashboard.weekAhead { OverviewWeekAheadCard(summary: weekAhead) }
        case .meals: OverviewMealsCard(meals: dashboard.meals, awayToday: dashboard.awayToday)
        case .chores: OverviewChoresCard(today: .today)
        case .birthdays: OverviewBirthdaysCard(birthdays: dashboard.birthdays, today: dashboard.today)
        case .upcoming: OverviewUpcomingCard(items: dashboard.upcoming, today: dashboard.today)
        case .finance: OverviewFinanceCard(summary: dashboard.finance)
        case .searches: OverviewSearchesCard(searches: dashboard.searches)
        }
    }
}

/// The overview's cards, in their order. Hiding one is this device's choice (`hiddenKey`, the
/// raw values joined by commas), for every family.
enum OverviewCardKind: String, CaseIterable, Identifiable {
    case today, weekAhead, meals, chores, birthdays, upcoming, finance, searches

    static let hiddenKey = "overviewHiddenCards"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .weekAhead: "Week ahead"
        case .meals: "Meals"
        case .chores: "Chores"
        case .birthdays: "Birthdays"
        case .upcoming: "Coming up"
        case .finance: "Finance"
        case .searches: "Appointment searches"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max.fill"
        case .weekAhead: "calendar.badge.exclamationmark"
        case .meals: "fork.knife"
        case .chores: Module.chores.systemImage
        case .birthdays: "birthday.cake.fill"
        case .upcoming: "calendar"
        case .finance: "banknote"
        case .searches: "stethoscope"
        }
    }

    /// The module the card belongs to; nil: the calendar's, always on.
    var module: Module? {
        switch self {
        case .meals: .meals
        case .chores: .chores
        case .finance: .finance
        case .searches: .appointments
        default: nil
        }
    }

    /// The cards of the modules the family has on.
    @MainActor
    static func available(_ family: FamilyContext) -> [OverviewCardKind] {
        allCases.filter { $0.module.map(family.isEnabled) ?? true }
    }

    static func hidden(in raw: String) -> Set<OverviewCardKind> {
        Set(raw.split(separator: ",").compactMap { OverviewCardKind(rawValue: String($0)) })
    }

    /// `raw` with `kind` hidden or shown.
    static func setting(_ kind: OverviewCardKind, hidden isHidden: Bool, in raw: String) -> String {
        var set = hidden(in: raw)
        if isHidden { set.insert(kind) } else { set.remove(kind) }
        return allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

/// The cards in columns, each one under the column that is shortest so far (in order, the leftmost
/// on a tie): a short card never leaves a gap beside a tall one, as a grid's rows would. As many
/// columns of at least `minColumnWidth` as fit, at most `maxColumns`; one on iPhone.
struct OverviewColumns: Layout {
    var minColumnWidth: CGFloat = 320
    var maxColumns = 3
    var spacing: CGFloat = 16

    struct Cache {
        var frames: [CGRect] = []
        var height: CGFloat = 0
        /// The width `frames` were arranged for.
        var width: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = width(for: proposal)
        arrange(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        // Placed at the width just measured (the usual pass), the cards aren't measured twice.
        if cache.width != bounds.width || cache.frames.count != subviews.count {
            arrange(width: bounds.width, subviews: subviews, cache: &cache)
        }
        for (subview, frame) in zip(subviews, cache.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// The width to lay out in: the proposal's, else (ideal, unbounded) one column or all of them.
    private func width(for proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width else { return minColumnWidth }
        guard width.isFinite else { return minColumnWidth * CGFloat(maxColumns) + spacing * CGFloat(maxColumns - 1) }
        return max(width, 0)
    }

    static func columnCount(width: CGFloat, minColumnWidth: CGFloat, maxColumns: Int, spacing: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    private func arrange(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        // Measured again on every size request (a handful of cards): a card's height changes with
        // its data; placing reuses what was measured for its width.
        let count = Self.columnCount(width: width, minColumnWidth: minColumnWidth, maxColumns: maxColumns, spacing: spacing)
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var bottoms = Array(repeating: CGFloat(0), count: count)
        var filled = Array(repeating: false, count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let y = filled[column] ? bottoms[column] + spacing : 0
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            bottoms[column] = y + height
            filled[column] = true
        }
        cache = Cache(frames: frames, height: bottoms.max() ?? 0, width: width)
    }
}

// MARK: Cards

/// A card: its header (a heading for VoiceOver) opens the module (or `route`), the content's rows
/// open their own places (`OverviewRow`).
private struct OverviewCard<Content: View>: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(OverviewCardKind.hiddenKey) private var hidden = ""
    /// Which card it is, for hiding it.
    let kind: OverviewCardKind
    let title: Text
    let systemImage: String
    let module: Module
    var route: AppRoute?
    /// What the header opens, for VoiceOver; the module's name when nil.
    var destination: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                family.open(route ?? .module(module))
            } label: {
                HStack(spacing: 10) {
                    TintedIcon(systemImage: systemImage, tint: module.tint, size: 30)
                    title
                        .font(.headline)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(Text("Opens \(destination ?? Text(module.title))"))
            content
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentCard()
        #if os(iOS)
        // The lifted preview's shape; macOS has no preview (and no such content shape kind).
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 24, style: .continuous))
        #endif
        .contextMenu {
            Button("Hide Card", systemImage: "eye.slash") {
                withAnimation(.snappy) { hidden = OverviewCardKind.setting(kind, hidden: true, in: hidden) }
            }
        }
    }
}

/// A row of a card that opens `route`: one button for VoiceOver, its parts read together.
private struct OverviewRow<Label: View>: View {
    @Environment(FamilyContext.self) private var family
    let route: AppRoute
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button {
            family.open(route)
        } label: {
            label
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// A row's text and its trailing value (a date, an amount) side by side, the value under the
/// text at accessibility sizes, where both wouldn't fit on one line.
private struct OverviewLine<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 8
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: spacing) { leading }
                trailing
            }
        } else {
            HStack(spacing: spacing) {
                leading
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

private struct OverviewTodayCard: View {
    let dashboard: OverviewDashboard

    var body: some View {
        OverviewCard(kind: .today, title: Text("Today · \(dashboard.today.formatted())"), systemImage: "sun.max.fill",
                     module: .calendar, route: .calendarDay(dashboard.today)) {
            VStack(alignment: .leading, spacing: 6) {
                if dashboard.todayEvents.isEmpty {
                    Text("No appointments today.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dashboard.todayEvents, id: \.uid) { event in
                        OverviewRow(route: OverviewLinks.route(for: event, today: dashboard.today)) {
                            HStack(spacing: 10) {
                                Image(systemName: event.searchId != nil ? "stethoscope" : (event.rrule != nil ? "repeat" : "clock"))
                                    .foregroundStyle(ModuleTint.calendar)
                                Text(event.time(on: dashboard.today) ?? String(localized: "All day"))
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                                    .frame(minWidth: 44, alignment: .leading)
                                Text(event.label)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                Divider()
                if let gap = dashboard.calendar.nextGap {
                    OverviewRow(route: .calendarDay(gap)) {
                        Label("Next uncovered day: \(gap.formatted())", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fontWeight(.medium)
                    }
                } else {
                    Label("No uncovered days coming up.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

/// The week ahead's open conflicts and warnings and the first few of them; the header opens them all.
private struct OverviewWeekAheadCard: View {
    let summary: WeekAheadSummary

    var body: some View {
        OverviewCard(kind: .weekAhead, title: Text("Week ahead"), systemImage: "calendar.badge.exclamationmark",
                     module: .calendar,
                     route: .weekAhead, destination: Text("Week ahead")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    if summary.conflicts > 0 {
                        Label(String(localized: "\(summary.conflicts) conflicts"), systemImage: WeekAheadSeverity.conflict.systemImage)
                            .foregroundStyle(WeekAheadSeverity.conflict.tint)
                    }
                    if summary.warnings > 0 {
                        Label(String(localized: "\(summary.warnings) warnings"), systemImage: WeekAheadSeverity.warning.systemImage)
                            .foregroundStyle(WeekAheadSeverity.warning.tint)
                    }
                }
                .fontWeight(.medium)
                ForEach(summary.top) { issue in
                    OverviewRow(route: .calendarDay(issue.date)) {
                        OverviewLine {
                            Image(systemName: issue.severity.systemImage)
                                .font(.caption)
                                .foregroundStyle(issue.severity.tint)
                                .frame(width: 14)
                                .accessibilityLabel(Text(issue.severity.label))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(issue.sentence).lineLimit(2)
                                if !issue.names.isEmpty {
                                    Text(issue.names)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        } trailing: {
                            Text(issue.date.formatted())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct OverviewMealsCard: View {
    @Environment(FamilyContext.self) private var family
    let meals: OverviewMealsSummary
    let awayToday: [String]

    var body: some View {
        OverviewCard(kind: .meals, title: Text("Meals"), systemImage: "fork.knife", module: .meals) {
            HStack(spacing: 8) {
                OverviewRow(route: OverviewLinks.meal(meals)) {
                    HStack(spacing: 10) {
                        if let meal = meals.today {
                            Image(systemName: "fork.knife").foregroundStyle(ModuleTint.meals)
                            Text(meal.recipeTitle).fontWeight(.medium).lineLimit(2)
                            if meal.isLeftover {
                                Text("Leftovers").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if !awayToday.isEmpty {
                            Image(systemName: "suitcase.rolling").foregroundStyle(.secondary)
                            Text("Away · \(awayToday.joined(separator: ", "))").foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "fork.knife").foregroundStyle(.secondary)
                            Text("Nothing planned").foregroundStyle(.secondary)
                        }
                    }
                }
                if let meal = meals.today {
                    Button("Cook", systemImage: "flame") { family.open(.cook(recipeID: meal.recipeId)) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open the cook view")
                }
            }
        }
    }
}

/// Today's chores from the family's `ChoresStore` (on the device, synced in the background): the
/// overdue ones, then today's open ones by part of the day, ticked off right here; a row opens the
/// chore on its day.
private struct OverviewChoresCard: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    let today: Day

    /// Rows shown before "+ n more".
    private static let limit = 6

    private struct Row: Identifiable {
        let item: ChoreItem
        let overdue: Bool
        var id: String { item.id }
    }

    private var store: ChoresStore { family.chores }

    var body: some View {
        OverviewCard(kind: .chores, title: Text("Chores"), systemImage: Module.chores.systemImage, module: .chores) {
            content
        }
        .task(id: family.revision(.chores)) {
            store.me = app.me?.id
            await store.refresh()
        }
    }

    @ViewBuilder private var content: some View {
        if let page = store.page {
            let todays = store.items(on: today)
            let overdue = store.overdue(today: today)
            let open = ChoreParts.items(todays).flatMap(\.items).filter { !$0.done }
            let rows = overdue.map { Row(item: $0, overdue: true) } + open.map { Row(item: $0, overdue: false) }
            if rows.isEmpty {
                let message: LocalizedStringKey = page.chores.isEmpty ? "No chores yet"
                    : todays.isEmpty ? "Nothing to do" : "All done for today"
                Label(message, systemImage: todays.isEmpty ? "checklist" : "checkmark.circle.fill")
                    .foregroundStyle(todays.isEmpty ? Color.secondary : Color.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows.prefix(Self.limit)) { row in
                        ChoreItemRow(item: row.item, today: today, overdue: row.overdue,
                                     canTick: store.canTick(row.item),
                                     tick: { store.toggleDone(row.item) },
                                     open: { family.open(.chore(id: row.item.choreId, day: row.item.day)) })
                    }
                    if rows.count > Self.limit {
                        OverviewRow(route: .module(.chores)) {
                            Text("+ \(rows.count - Self.limit) more").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else if case .failed = store.phase {
            Text("Couldn’t load the chores.").foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

private struct OverviewBirthdaysCard: View {
    let birthdays: [OverviewBirthday]
    let today: Day

    var body: some View {
        OverviewCard(kind: .birthdays, title: Text("Birthdays"), systemImage: "birthday.cake.fill", module: .calendar,
                     route: birthdays.first.map(OverviewLinks.route(for:))) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(birthdays) { birthday in
                    OverviewRow(route: OverviewLinks.route(for: birthday)) {
                        OverviewLine {
                            Text(verbatim: "🎂").accessibilityHidden(true)
                            Text("\(birthday.name) turns \(birthday.age)")
                        } trailing: {
                            if birthday.day == today {
                                Text("Today")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.ohana)
                            } else {
                                Text(birthday.day.formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// What's coming up, under its days: a time (or a type's badge) in a column, then the title on
/// one line; a run or an event that spans days says until when.
private struct OverviewUpcomingCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var leadWidth: CGFloat = 44
    let items: [OverviewUpcomingItem]
    let today: Day

    var body: some View {
        OverviewCard(kind: .upcoming, title: Text("Coming up"), systemImage: "calendar", module: .calendar) {
            if items.isEmpty {
                Text("Nothing planned for the next weeks.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(OverviewUpcomingItem.byDay(items, today: today)) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(OverviewFormat.dayHeading(group.day, today: today))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, 2)
                            ForEach(group.items) { item in
                                OverviewRow(route: OverviewLinks.route(for: item)) { row(item, on: group.day) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var lineLimit: Int? { typeSize.isAccessibilitySize ? nil : 1 }

    @ViewBuilder
    private func row(_ item: OverviewUpcomingItem, on day: Day) -> some View {
        switch item {
        case let .entry(_, to, name, color, icon, member):
            line {
                CalendarTypeBadge(name: name, color: color, icon: icon, member: member, size: 18)
            } title: {
                // The badge reads the name (with the member's).
                Text(name).lineLimit(lineLimit).accessibilityHidden(true)
            } trailing: {
                until(to, after: day)
            }
        case let .event(_, event):
            line {
                if let start = event.start {
                    Text(start)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } title: {
                Text(event.title).lineLimit(lineLimit)
                if !event.person.isEmpty {
                    Text(verbatim: "· \(event.person)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            } trailing: {
                until(event.endDate ?? event.date, after: day)
                if event.searchId != nil {
                    Image(systemName: "stethoscope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Appointment"))
                }
            }
        }
    }

    private func line(@ViewBuilder lead: () -> some View, @ViewBuilder title: () -> some View,
                      @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            // The column keeps its width without a time (an all-day event), so titles line up.
            ZStack(alignment: .leading) {
                Color.clear.frame(width: leadWidth, height: 0)
                lead()
            }
            HStack(spacing: 4) { title() }
            Spacer(minLength: 4)
            trailing()
        }
    }

    @ViewBuilder
    private func until(_ last: Day, after day: Day) -> some View {
        if last > day {
            Text("until \(last.formatted(.dateTime.day().month(.abbreviated)))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct OverviewFinanceCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let summary: OverviewMonthSummary

    private var monthName: String {
        summary.monthDay?.date.formatted(.dateTime.month(.wide).year()) ?? summary.month
    }

    var body: some View {
        OverviewCard(kind: .finance, title: Text("Finance"), systemImage: "banknote", module: .finance) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This month · \(monthName)")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if summary.count == 0 {
                    Text("No transactions this month yet.")
                        .foregroundStyle(.secondary)
                } else {
                    OverviewRow(route: .financeTransactions(categoryID: nil)) {
                        // The three figures side by side, one under another at accessibility sizes.
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            figure("In", OverviewFormat.money(summary.incomeCents, currency: summary.currency), color: .green)
                            figure("Out", OverviewFormat.money(summary.expenseCents, currency: summary.currency), color: .red)
                            figure("Balance", OverviewFormat.signedMoney(summary.netCents, currency: summary.currency),
                                   color: nil, negative: summary.netCents < 0)
                        }
                    }
                    if let top = summary.topExpense {
                        OverviewRow(route: OverviewLinks.topExpense(summary)) {
                            OverviewLine {
                                Circle().fill(Color(overviewHex: top.color)).frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                Text("Most went to \(top.icon.isEmpty ? top.name : "\(top.icon) \(top.name)")")
                                    .lineLimit(2)
                            } trailing: {
                                Text(OverviewFormat.money(top.expenseCents, currency: summary.currency))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let balance = summary.balanceCents {
                    Text("On the accounts: \(OverviewFormat.money(balance, currency: summary.currency))")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: String, color: Color?, negative: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let color {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.7)
                .foregroundStyle(negative ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewSearchesCard: View {
    let searches: [OverviewSearchFind]

    var body: some View {
        OverviewCard(kind: .searches, title: Text("Appointment searches"), systemImage: "stethoscope",
                     module: .appointments) {
            if searches.isEmpty {
                Text("No searches yet: Ohana can watch Doctolib and jameda for you.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(searches.prefix(6)) { search in
                        OverviewRow(route: OverviewLinks.route(for: search)) { row(search) }
                    }
                }
            }
        }
    }

    private func row(_ search: OverviewSearchFind) -> some View {
        OverviewLine(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(search.name).fontWeight(.medium).lineLimit(2)
                    if !search.enabled {
                        Text("paused")
                            .font(.caption2)
                            .chip()
                    }
                }
                subtitle(search)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } trailing: {
            if let date = search.first?.date {
                Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(ModuleTint.appointments)
            }
        }
    }

    private func subtitle(_ search: OverviewSearchFind) -> Text {
        if let first = search.first {
            return search.doctors > 1
                ? Text(OverviewFormat.doctorAndMore(first.doctorName, more: search.doctors - 1))
                : Text(first.doctorName)
        }
        return search.enabled ? Text("Nothing found yet") : Text("not scheduled")
    }
}

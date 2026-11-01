import SwiftUI

/// The family overview (the web app's app/(app)/f/[familyId]/page.tsx): one dashboard over all
/// modules. "Ask Ohana…", today, the meals, the next birthdays, what comes up, this month's
/// finances and the appointment searches' latest finds, as content cards. A card's header opens
/// its module; each row opens its exact place (a day of the calendar, a recipe, a category's
/// transactions, an appointment slot). What belongs to a
/// module the server has off doesn't show.
struct OverviewView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<OverviewDashboard> = .idle

    /// Every area's revision: anything that changes elsewhere reloads the overview.
    private var reloadKey: [Int] { DataArea.allCases.map { family.revision($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if family.isEnabled(.assistant) { OverviewAskField() }
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
        .refreshable { await load() }
        .task(id: reloadKey) { await load() }
    }

    private func load() async {
        await LoadState.run($state, Self.request(family.api))
    }

    /// The overview's GET (the prefetch asks the same): filed without `today`, so yesterday's
    /// copy still shows offline.
    static func request(_ api: FamilyAPI) -> CachedGet<OverviewDashboard> {
        api.cached("/overview", query: ["today": Day.today.description], key: "/overview")
    }
}

/// "Ask Ohana…": a question typed here goes to a new chat with the assistant.
private struct OverviewAskField: View {
    @Environment(FamilyContext.self) private var family
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let question = OverviewAsk.question(text) {
                    send(question)
                } else {
                    family.ask(newChat: true)
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ModuleTint.assistant)
                    .frame(width: iconSize, height: iconSize)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Ask the assistant"))
            .help(Text("Ask the assistant"))
            TextField("Ask Ohana…", text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit {
                    if let question = OverviewAsk.question(text) { send(question) }
                }
            if OverviewAsk.question(text) != nil {
                Button {
                    if let question = OverviewAsk.question(text) { send(question) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(ModuleTint.assistant)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Send"))
                .help(Text("Send"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(Color.cardBackground)
                .overlay { Capsule().fill(ModuleTint.assistant.opacity(0.1)) }
        }
        .animation(reduceMotion ? nil : .snappy, value: OverviewAsk.question(text) == nil)
    }

    private func send(_ question: String) {
        family.ask(question, send: true, newChat: true)
        text = ""
        focused = false
    }
}

private struct OverviewGrid: View {
    @Environment(FamilyContext.self) private var family
    let dashboard: OverviewDashboard

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 16, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            OverviewTodayCard(dashboard: dashboard)
            if family.isEnabled(.meals) {
                OverviewMealsCard(meals: dashboard.meals, awayToday: dashboard.awayToday)
            }
            if !dashboard.birthdays.isEmpty {
                OverviewBirthdaysCard(birthdays: dashboard.birthdays, today: dashboard.today)
            }
            OverviewUpcomingCard(items: dashboard.upcoming, today: dashboard.today)
            if family.isEnabled(.finance) {
                OverviewFinanceCard(summary: dashboard.finance)
            }
            if family.isEnabled(.appointments) {
                OverviewSearchesCard(searches: dashboard.searches)
            }
        }
    }
}

// MARK: Cards

/// A card: its header (a heading for VoiceOver) opens the module (or `route`), the content's rows
/// open their own places (`OverviewRow`).
private struct OverviewCard<Content: View>: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: Text
    let systemImage: String
    let module: Module
    var route: AppRoute?
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
            .accessibilityHint(Text("Opens \(Text(module.title))"))
            content
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentCard()
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
        OverviewCard(title: Text("Today · \(dashboard.today.formatted())"), systemImage: "sun.max.fill",
                     module: .calendar, route: .calendarDay(dashboard.today)) {
            VStack(alignment: .leading, spacing: 6) {
                if dashboard.todayEvents.isEmpty {
                    Text("No appointments today.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dashboard.todayEvents) { event in
                        OverviewRow(route: OverviewLinks.route(for: event)) {
                            HStack(spacing: 10) {
                                Image(systemName: event.searchId != nil ? "stethoscope" : "clock")
                                    .foregroundStyle(ModuleTint.calendar)
                                Text(event.start ?? String(localized: "All day"))
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

private struct OverviewMealsCard: View {
    @Environment(FamilyContext.self) private var family
    let meals: OverviewMealsSummary
    let awayToday: [String]

    var body: some View {
        OverviewCard(title: Text("Meals"), systemImage: "fork.knife", module: .meals) {
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

private struct OverviewBirthdaysCard: View {
    let birthdays: [OverviewBirthday]
    let today: Day

    var body: some View {
        OverviewCard(title: Text("Birthdays"), systemImage: "birthday.cake.fill", module: .calendar,
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

private struct OverviewUpcomingCard: View {
    let items: [OverviewUpcomingItem]
    let today: Day

    var body: some View {
        OverviewCard(title: Text("Coming up"), systemImage: "calendar", module: .calendar) {
            if items.isEmpty {
                Text("Nothing planned for the next weeks.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        OverviewRow(route: OverviewLinks.route(for: item)) { row(item) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: OverviewUpcomingItem) -> some View {
        switch item {
        case let .entry(date, to, name, color):
            OverviewLine {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(overviewHex: color))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(name).lineLimit(2)
            } trailing: {
                Text(OverviewFormat.range(date, to))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case let .event(date, event):
            OverviewLine {
                Image(systemName: event.searchId != nil ? "stethoscope" : "clock")
                    .font(.caption)
                    .foregroundStyle(ModuleTint.calendar)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(event.label).lineLimit(2)
            } trailing: {
                Text(event.start.map { "\(date.formatted()), \($0)" } ?? date.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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
        OverviewCard(title: Text("Finance"), systemImage: "banknote", module: .finance) {
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
        OverviewCard(title: Text("Appointment searches"), systemImage: "stethoscope", module: .appointments) {
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

import SwiftUI

/// The family overview (the web app's app/(app)/f/[familyId]/page.tsx): one dashboard over all
/// modules. Today, the meals and the shopping list, the next birthdays, what comes up, this
/// month's finances and the appointment searches' latest finds, as glass cards; each card opens
/// its module.
struct OverviewView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<OverviewDashboard> = .idle

    /// Every area's revision: anything that changes elsewhere reloads the overview.
    private var reloadKey: [Int] { DataArea.allCases.map { family.revision($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OverviewHeader(familyName: family.family.name, userName: app.me?.name ?? "")
                OverviewModuleChips()
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
        let api = family.api
        await LoadState.run($state) {
            try await api.get("/overview", query: ["today": Day.today.description])
        }
    }
}

/// "Good morning, Anna" and the family's name.
private struct OverviewHeader: View {
    let familyName: String
    let userName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(OverviewFormat.greeting(hour: Calendar.current.component(.hour, from: Date()),
                                         name: userName.split(separator: " ").first.map(String.init) ?? ""))
                .font(.largeTitle.bold())
            Text("Welcome to \(familyName)")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The modules as glass chips (the web overview's module links).
private struct OverviewModuleChips: View {
    private let modules: [Module] = [.calendar, .finance, .meals, .appointments]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(modules) { module in
                        Button {
                            module.open()
                        } label: {
                            Label(module.title, systemImage: module.systemImage)
                                .foregroundStyle(module.tint)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }
}

private struct OverviewGrid: View {
    let dashboard: OverviewDashboard

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 600), spacing: 16, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            OverviewTodayCard(dashboard: dashboard)
            OverviewMealsCard(meals: dashboard.meals, awayToday: dashboard.awayToday)
            if !dashboard.birthdays.isEmpty {
                OverviewBirthdaysCard(birthdays: dashboard.birthdays, today: dashboard.today)
            }
            OverviewUpcomingCard(items: dashboard.upcoming, today: dashboard.today)
            OverviewFinanceCard(summary: dashboard.finance)
            OverviewSearchesCard(searches: dashboard.searches)
        }
    }
}

// MARK: Cards

/// A glass card that opens a module when tapped.
private struct OverviewCard<Content: View>: View {
    let title: Text
    let systemImage: String
    let module: Module
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            module.open()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TintedIcon(systemImage: systemImage, tint: module.tint, size: 30)
                    title
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                content
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassCard(interactive: true)
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens \(Text(module.title))"))
    }
}

private struct OverviewTodayCard: View {
    let dashboard: OverviewDashboard

    var body: some View {
        OverviewCard(title: Text("Today · \(dashboard.today.formatted())"), systemImage: "sun.max.fill",
                     module: .calendar) {
            VStack(alignment: .leading, spacing: 10) {
                if dashboard.todayEvents.isEmpty {
                    Text("No appointments today.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dashboard.todayEvents) { event in
                        HStack(spacing: 10) {
                            Image(systemName: "clock")
                                .foregroundStyle(ModuleTint.calendar)
                            Text(event.start ?? String(localized: "All day"))
                                .monospacedDigit()
                                .fontWeight(.medium)
                                .frame(minWidth: 44, alignment: .leading)
                            Text(event.label)
                                .lineLimit(1)
                        }
                    }
                }
                Divider()
                if let gap = dashboard.calendar.nextGap {
                    Label("Next uncovered day: \(gap.formatted())", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fontWeight(.medium)
                } else {
                    Label("No uncovered days coming up.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

private struct OverviewMealsCard: View {
    let meals: OverviewMealsSummary
    let awayToday: [String]

    var body: some View {
        OverviewCard(title: Text("Meals"), systemImage: "fork.knife", module: .meals) {
            VStack(alignment: .leading, spacing: 12) {
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
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Shopping list", systemImage: "cart")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let date = meals.shopping?.shoppingDate {
                            Text(date.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let shopping = meals.shopping, shopping.total > 0 {
                        if shopping.open == 0 {
                            Text("Everything bought")
                        } else {
                            Text("\(shopping.open) of \(shopping.total) items left to buy")
                        }
                        ProgressView(value: shopping.progress)
                            .tint(ModuleTint.meals)
                    } else {
                        Text("No shopping list yet").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct OverviewBirthdaysCard: View {
    let birthdays: [OverviewBirthday]
    let today: Day

    var body: some View {
        OverviewCard(title: Text("Birthdays"), systemImage: "birthday.cake.fill", module: .calendar) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(birthdays) { birthday in
                    HStack(spacing: 8) {
                        Text(verbatim: "🎂")
                        Text("\(birthday.name) turns \(birthday.age)")
                            .lineLimit(1)
                        Spacer(minLength: 8)
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

private struct OverviewUpcomingCard: View {
    let items: [OverviewUpcomingItem]
    let today: Day

    var body: some View {
        OverviewCard(title: Text("Coming up"), systemImage: "calendar", module: .calendar) {
            if items.isEmpty {
                Text("Nothing planned for the next weeks.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: OverviewUpcomingItem) -> some View {
        switch item {
        case let .entry(date, to, name, color):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(overviewHex: color))
                    .frame(width: 12, height: 12)
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                Text(OverviewFormat.range(date, to))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case let .event(date, event):
            HStack(spacing: 8) {
                Image(systemName: event.searchId != nil ? "stethoscope" : "clock")
                    .font(.caption)
                    .foregroundStyle(ModuleTint.calendar)
                    .frame(width: 12)
                Text(event.label).lineLimit(1)
                Spacer(minLength: 8)
                Text(event.start.map { "\(date.formatted()), \($0)" } ?? date.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OverviewFinanceCard: View {
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
                    HStack(alignment: .top, spacing: 12) {
                        figure("In", OverviewFormat.money(summary.incomeCents, currency: summary.currency), color: .green)
                        figure("Out", OverviewFormat.money(summary.expenseCents, currency: summary.currency), color: .red)
                        figure("Balance", OverviewFormat.signedMoney(summary.netCents, currency: summary.currency),
                               color: nil, negative: summary.netCents < 0)
                    }
                    if let top = summary.topExpense {
                        HStack(spacing: 8) {
                            Circle().fill(Color(overviewHex: top.color)).frame(width: 10, height: 10)
                            Text("Most went to \(top.icon.isEmpty ? top.name : "\(top.icon) \(top.name)")")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(OverviewFormat.money(top.expenseCents, currency: summary.currency))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
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
                }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(searches.prefix(6)) { search in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(search.name).fontWeight(.medium).lineLimit(1)
                                    if !search.enabled {
                                        Text("paused")
                                            .font(.caption2)
                                            .glassChip()
                                    }
                                }
                                subtitle(search)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let date = search.first?.date {
                                Text(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(ModuleTint.appointments)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(_ search: OverviewSearchFind) -> Text {
        if let first = search.first {
            return search.doctors > 1
                ? Text("\(first.doctorName) and \(search.doctors - 1) more")
                : Text(first.doctorName)
        }
        return search.enabled ? Text("Nothing found yet") : Text("not scheduled")
    }
}

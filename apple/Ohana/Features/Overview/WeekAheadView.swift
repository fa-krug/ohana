import SwiftUI

/// The week ahead (route `/f/{id}/digest`, the weekly notification's link): the next two weeks
/// for each member — the clashes and the plans that don't work out, checked by the server
/// (server/lib/digest) — with the days the family is away and the birthdays. Each issue opens
/// its day in the calendar. Editors mark one "Looks fine" (it's hidden for everyone) and can
/// restore it from "Hidden". Pushed onto the overview's stack.
struct WeekAheadView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<WeekAheadDigest> = .idle
    @State private var showsHidden = false

    /// Dismissing waits while it's the copy on the device.
    private var canEdit: Bool { family.canEdit && !state.isSaved }

    private var reloadKey: [Int] {
        [DataArea.events, .calendar, .family, .digest].map { family.revision($0) }
    }

    var body: some View {
        LoadStateView(state: state, retry: load) { digest in
            content(digest)
        }
        .ohanaBackground(ModuleTint.overview)
        .navigationTitle("Week ahead")
        .task(id: reloadKey) { await load() }
    }

    private func load() async {
        await LoadState.run($state, Self.request(family.api))
    }

    /// The digest's GET (the prefetch asks the same): filed without `today`, like the overview.
    static func request(_ api: FamilyAPI) -> CachedGet<WeekAheadDigest> {
        api.cached("/digest", query: ["today": Day.today.description], key: "/digest")
    }

    private func content(_ digest: WeekAheadDigest) -> some View {
        let groups = WeekAheadGroups(digest)
        return List {
            WeekAheadHeader(digest: digest, groups: groups)

            if groups.isClear {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No conflicts").fontWeight(.medium)
                            Text("Nothing clashes in the next two weeks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }

            ForEach(groups.groups) { group in
                Section {
                    ForEach(group.issues) { issue in
                        WeekAheadIssueRow(issue: issue)
                            .swipeActions(edge: .trailing) {
                                if canEdit {
                                    Button("Looks fine", systemImage: "checkmark") { setDismissed(issue, true) }
                                        .tint(.green)
                                }
                            }
                            .contextMenu { menu(for: issue) }
                    }
                } header: {
                    WeekAheadGroupHeader(group: group)
                }
            }

            if !groups.clear.isEmpty, !groups.isClear {
                Section("All clear") {
                    ForEach(groups.clear) { person in
                        LabeledContent {
                            Text(String(localized: "\(person.events) events")).monospacedDigit()
                        } label: {
                            Label(person.name, systemImage: "checkmark.circle")
                        }
                    }
                }
            }

            if family.canEdit, !groups.hidden.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsHidden) {
                        ForEach(groups.hidden) { issue in
                            HStack(spacing: 8) {
                                WeekAheadIssueRow(issue: issue, showsPeople: true)
                                    .opacity(0.7)
                                Button("Restore") { setDismissed(issue, false) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(!canEdit)
                                    .help("Show it again")
                            }
                        }
                    } label: {
                        Text("Hidden (\(groups.hidden.count))")
                    }
                } footer: {
                    Text("Marked as looking fine. Restore one to see it again.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }

    @ViewBuilder private func menu(for issue: WeekAheadIssue) -> some View {
        Button("Show in Calendar", systemImage: "calendar") { family.open(.calendarDay(issue.date)) }
        if canEdit {
            Button("Looks fine", systemImage: "checkmark") { setDismissed(issue, true) }
        }
    }

    /// Hides or restores `issue` right away; on a failure the page reloads and the banner says why.
    private func setDismissed(_ issue: WeekAheadIssue, _ dismissed: Bool) {
        if case var .loaded(digest) = state, let i = digest.issues.firstIndex(where: { $0.key == issue.key }) {
            digest.issues[i].dismissed = dismissed
            withAnimation(.snappy) { state = .loaded(digest) }
        }
        perform {
            do {
                if dismissed {
                    try await WeekAheadActions.dismiss(family, key: issue.key)
                } else {
                    try await WeekAheadActions.restore(family, key: issue.key)
                }
            } catch {
                await load()
                throw error
            }
        }
    }
}

/// The two weeks at a glance: their days, how many issues, the days away and the birthdays.
private struct WeekAheadHeader: View {
    @Environment(FamilyContext.self) private var family
    let digest: WeekAheadDigest
    let groups: WeekAheadGroups

    private var open: [WeekAheadIssue] { digest.issues.filter { !$0.dismissed } }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                TintedIcon(systemImage: "calendar", tint: ModuleTint.calendar, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(OverviewFormat.range(digest.from, digest.to)).fontWeight(.medium)
                    counts
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            ForEach(digest.away) { run in
                row(route: .calendarDay(run.from)) {
                    Label {
                        Text("Away · \(run.names.joined(separator: ", "))")
                    } icon: {
                        Image(systemName: "suitcase.rolling").foregroundStyle(ModuleTint.calendar)
                    }
                } trailing: {
                    Text(OverviewFormat.range(run.from, run.to))
                }
            }
            ForEach(digest.birthdays) { birthday in
                row(route: .calendarDay(birthday.day)) {
                    Label {
                        Text("\(birthday.name) turns \(birthday.age)")
                    } icon: {
                        Image(systemName: "birthday.cake").foregroundStyle(.pink)
                    }
                } trailing: {
                    Text(birthday.day.formatted())
                }
            }
        } footer: {
            if !digest.geocoding {
                Text("Travel isn’t estimated: the server doesn’t look up the events’ places, so only differing place names count.")
            }
        }
    }

    private var counts: Text {
        let conflicts = open.filter { $0.severity == .conflict }.count
        let warnings = open.filter { $0.severity == .warning }.count
        if conflicts == 0, warnings == 0 { return Text("No conflicts") }
        var parts: [String] = []
        if conflicts > 0 { parts.append(String(localized: "\(conflicts) conflicts")) }
        if warnings > 0 { parts.append(String(localized: "\(warnings) warnings")) }
        return Text(parts.joined(separator: " · "))
    }

    private func row<Leading: View, Trailing: View>(route: AppRoute, @ViewBuilder leading: () -> Leading,
                                                    @ViewBuilder trailing: () -> Trailing) -> some View {
        Button {
            family.open(route)
        } label: {
            HStack {
                leading()
                Spacer(minLength: 8)
                trailing()
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A person's name over their issues (a child marked), or "Unassigned".
private struct WeekAheadGroupHeader: View {
    let group: WeekAheadGroups.Group

    var body: some View {
        HStack(spacing: 6) {
            if let person = group.person {
                Text(person.name)
                if person.child {
                    Text("Child").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let name = group.name {
                Text(name)
            } else {
                Text("Unassigned")
            }
        }
    }
}

/// One issue: its severity, the sentence, the day and what it's about, and the events' times.
/// A tap opens the day in the calendar.
struct WeekAheadIssueRow: View {
    @Environment(FamilyContext.self) private var family
    let issue: WeekAheadIssue
    /// Names who it's about (outside a person's section).
    var showsPeople = false

    private var caption: String {
        var parts = [issue.date.formatted(), WeekAheadText.title(kind: issue.kind)]
        if showsPeople, !issue.names.isEmpty { parts.append(issue.names) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            family.open(.calendarDay(issue.date))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: issue.severity.systemImage)
                    .foregroundStyle(issue.severity.tint)
                    .frame(width: 22)
                    .accessibilityLabel(Text(issue.severity.label))
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.sentence)
                        .fontWeight(issue.severity == .conflict ? .medium : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(issue.events.enumerated()), id: \.offset) { _, event in
                        Text(event.line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows the day in the calendar"))
    }
}

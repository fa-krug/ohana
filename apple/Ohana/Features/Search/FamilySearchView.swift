import SwiftUI

/// The search tab (⌘K): one search across the modules — recipes, calendar events and notes,
/// transactions, appointment searches, people, knowledge documents (editors) and the user's
/// assistant chats. A hit opens where
/// it lives with `family.open(_:)`. Inside the shell's navigation stack; on iPhone the field
/// sits in the tab bar, on the Mac it is the toolbar's (`ShellSearchField`, on every page:
/// `family.searchQuery`).
struct FamilySearchView: View {
    @Environment(FamilyContext.self) private var family
    #if os(macOS)
    private var query: String { family.searchQuery }
    #else
    @State private var query = ""
    @FocusState private var focused: Bool
    #endif
    @State private var result: FamilySearchResult?
    @State private var failure: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Searches again when the query or any data changes (the assistant, another window).
    private var searchKey: [String] {
        [trimmed] + DataArea.allCases.map { String(family.revision($0)) }
    }

    var body: some View {
        content
            .ohanaBackground()
            .navigationTitle("Search")
            .task(id: searchKey) { await search() }
            #if os(macOS)
            .onChange(of: family.searchSubmitRequest) { openFirstHit() }
            #else
            .searchable(text: $query, prompt: Text("Recipes, events, transactions, people…"))
            .searchFocused($focused)
            // Return opens the first hit.
            .onSubmit(of: .search) { openFirstHit() }
            .onChange(of: family.searchRequest, initial: true) {
                if family.searchRequest > 0 { focused = true }
            }
            #endif
    }

    private func openFirstHit() {
        if let route = result?.results.lazy.compactMap(\.route).first { family.open(route) }
    }

    private func search() async {
        let q = trimmed
        guard !q.isEmpty else {
            result = nil
            failure = nil
            return
        }
        // As you type, a moment after the last key.
        if q != result?.query { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        do {
            let found = try await family.api.get("/search", query: ["q": q, "today": Day.today.description],
                                                 as: FamilySearchResult.self)
            guard !Task.isCancelled else { return }
            result = found
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    @ViewBuilder private var content: some View {
        if trimmed.isEmpty {
            ContentUnavailableView {
                Label("Search the family", systemImage: "magnifyingglass")
            } description: {
                Text("Find recipes, calendar events and notes, transactions, appointment searches, people and chats.")
            }
        } else if let failure, result == nil {
            ContentUnavailableView {
                Label("Couldn’t search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try again") { Task { await search() } }
                    .buttonStyle(.glassProminent)
            }
        } else if let result {
            if result.groups.isEmpty {
                ContentUnavailableView.search(text: result.query)
            } else {
                list(result)
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ result: FamilySearchResult) -> some View {
        List {
            ForEach(result.groups, id: \.kind) { group in
                Section {
                    ForEach(group.hits) { hit in
                        SearchHitRow(hit: hit, kind: group.kind, currency: result.currency)
                    }
                } header: {
                    Text(group.kind.title)
                } footer: {
                    if let more = result.more[group.kind.rawValue], more > 0 {
                        Text("\(more) more – add a word to narrow it down.")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }
}

/// One hit: the module's symbol, title and detail, and its day, time or amount.
private struct SearchHitRow: View {
    @Environment(FamilyContext.self) private var family
    let hit: FamilySearchHit
    let kind: FamilySearchHit.Kind
    let currency: String

    var body: some View {
        Button {
            if let route = hit.route { family.open(route) }
        } label: {
            HStack(spacing: 12) {
                // A note's own symbol, in the theme color as on the calendar.
                if kind == .note, let icon = hit.icon.flatMap({ CalendarSymbol.drawable($0) }) {
                    Image(systemName: icon)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                } else if kind == .knowledge {
                    // A document: its file's kind.
                    Image(systemName: hit.fileKind.systemImage)
                        .foregroundStyle(kind.module.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: kind.systemImage)
                        .foregroundStyle(kind.module.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    if !hit.detail.isEmpty {
                        Text(kind == .knowledge ? KnowledgePath.breadcrumb(hit.detail) : hit.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let snippet = hit.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(hit.route == nil)
    }

    /// A note with only an icon is called by it.
    private var title: String {
        if hit.title.isEmpty, kind == .note, let icon = hit.icon, !icon.isEmpty { return CalendarSymbol.title(icon) }
        return hit.title
    }

    @ViewBuilder private var trailing: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let cents = hit.amountCents {
                Text(FinanceMoney.format(cents, currency: currency))
                    .monospacedDigit()
                    .foregroundStyle(cents > 0 ? .green : .primary)
            }
            if let day = hit.day {
                Text(dayLabel(day))
                    .font(hit.amountCents == nil ? .callout : .caption)
                    .foregroundStyle(.secondary)
            }
            if kind == .event, hit.day != nil {
                Text(hit.time ?? String(localized: "All day"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if kind == .knowledge, let page = hit.page, page >= 1 {
                Text("Page \(page)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hit.account == false {
                Text("No account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    /// The day, with its year when it isn't this year's.
    private func dayLabel(_ day: Day) -> String {
        day.year == Day.today.year
            ? day.formatted(.dateTime.day().month(.abbreviated))
            : day.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

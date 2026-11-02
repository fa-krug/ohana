import SwiftUI

/// What the chores page shows: the chores (for the people, whether the account edits, the
/// editor) and the agenda around the day on screen.
struct ChoresScreen: Equatable {
    var page: ChoresPage
    var agenda: ChoreAgenda
}

/// Chores: a day at a time (today first, stepped back and forth), its chores by morning, day and
/// evening, on today the overdue ones above. A chore (a repeating one's occurrence) is ticked off
/// here by editors and by the member it's for; anyone turns its notification on or off for
/// themselves (the bell). Editors add (File ▸ New Chore, ⌘N), edit and delete; every chore is on
/// the All Chores page (`ChoresAllView`, the More menu). Inside the shell's navigation stack.
struct ChoresView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<ChoresScreen> = .idle
    /// The day on screen.
    @State private var shown = Day.today
    @State private var filter: ChoreFilter = .everyone
    @State private var editing: ChoreEditorTarget?
    @State private var deleting: ChoreItem?
    @State private var showAll = false
    @State private var pickingDay = false
    /// The agenda of another range is being asked for.
    @State private var loading = false
    /// A chore a route asked for, opened once the list is there.
    @State private var pendingChoreID: String?
    /// A chore a notification led to, marked on its day for a moment.
    @State private var highlighted: String?
    /// Items (and chores) being changed right now.
    @State private var busy: Set<String> = []

    private var today: Day { Day.today }

    /// Changes to what's shown wait while it's the copy on the device.
    private var canEdit: Bool { (state.value?.page.canEdit ?? family.canEdit) && !state.isSaved }

    var body: some View {
        LoadStateView(state: state, retry: load) { screen in
            content(screen)
        }
        .ohanaBackground(ModuleTint.chores)
        .navigationTitle("Chores")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaBar(edge: .top) {
            if state.value != nil { dayBar.padding(.horizontal).padding(.vertical, 8) }
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.newItem, canEdit ? NewItemAction(title: "New Chore") { editing = .new } : nil)
        .focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Chores") { moduleMenu })
        .task(id: LoadKey(revision: family.revision(.chores), from: ChoreAgenda.window(around: shown, today: today).from)) {
            await load()
        }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .chores) else { return }
            switch route {
            case .newChore: if canEdit { editing = .new }
            case let .chore(id, day?):
                // A notification's: the chore on its day.
                shown = day
                highlighted = id
            case let .chore(id, nil): pendingChoreID = id
            default: break
            }
            openPending()
        }
        .onChange(of: state.value) { openPending() }
        .navigationDestination(isPresented: $showAll) {
            ChoresAllView(filter: $filter).assistantButton()
        }
        .sheet(item: $editing) { target in
            ChoreEditorHost(target: target, page: state.value?.page, canEdit: canEdit, filter: filter, day: shown)
        }
        .confirmationDialog(
            Text("Delete “\(deleting?.title ?? "")”?"), isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { item in
            Button("Delete", role: .destructive) {
                perform { try await ChoreActions.delete(family, item.choreId) }
            }
        }
    }

    private struct LoadKey: Equatable {
        let revision: Int
        let from: Day
    }

    private func load() async {
        let pageGet = Self.request(family.api), agendaGet = Self.agendaRequest(family.api, around: shown)
        loading = true
        defer { loading = false }
        await LoadState.run($state, saved: {
            guard let page = pageGet.saved(), let agenda = agendaGet.saved() else { return nil }
            return Saved(value: ChoresScreen(page: page.value, agenda: agenda.value), date: min(page.date, agenda.date))
        }) {
            let page = try await pageGet.fetch()
            return ChoresScreen(page: page, agenda: try await agendaGet.fetch())
        }
    }

    /// The chores' GET (the prefetch asks the same); its copy is kept whatever the day.
    static func request(_ api: FamilyAPI) -> CachedGet<ChoresPage> {
        api.cached("/chores", query: ["today": Day.today.description], key: "/chores")
    }

    /// The agenda of the two weeks around `day` (`ChoreAgenda.window`); those around today are
    /// kept whatever the day, so the page opens offline.
    static func agendaRequest(_ api: FamilyAPI, around day: Day, today: Day = .today) -> CachedGet<ChoreAgenda> {
        let window = ChoreAgenda.window(around: day, today: today)
        let query: [String: String?] = ["from": window.from.description, "to": window.to.description,
                                        "today": today.description]
        let current = window == ChoreAgenda.window(around: today, today: today)
        return api.cached("/chores/agenda", query: query, key: current ? "/chores/agenda" : nil)
    }

    // MARK: Day

    private var dayBar: some View {
        HStack(spacing: 8) {
            Button { shown = shown.adding(days: -1) } label: {
                Label("Previous Day", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .buttonBorderShape(.circle)
            Button { pickingDay = true } label: {
                Text(ChoreText.dayName(shown, today: today))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Picks a day"))
            .popover(isPresented: $pickingDay) {
                DatePicker("Day", selection: Binding(get: { shown.date }, set: { shown = Day($0); pickingDay = false }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .frame(minWidth: 300)
                    .presentationCompactAdaptation(.popover)
            }
            if shown != today {
                Button("Today") { shown = today }
            }
            Button { shown = shown.adding(days: 1) } label: {
                Label("Next Day", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .buttonBorderShape(.circle)
        }
        .buttonStyle(.glass)
    }

    // MARK: Toolbar and menus

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button("New Chore", systemImage: "plus") { editing = .new }
                    .help("New Chore (⌘N)")
            }
        }
        ToolbarItem {
            Menu {
                Picker("Whose chores", selection: $filter) { ChoreFilterChoices(people: state.value?.page.people ?? []) }
                    .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: filter == .everyone
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        ToolbarItem {
            Menu {
                Section {
                    Button("All Chores", systemImage: "list.bullet") { showAll = true }
                }
                Section {
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    /// The Chores menu (Mac menu bar, the iPad's ⌘-hold list).
    @ViewBuilder
    private var moduleMenu: some View {
        Picker("Whose Chores", selection: $filter) { ChoreFilterChoices(people: state.value?.page.people ?? []) }
            .pickerStyle(.inline)
        Divider()
        Button("Previous Day") { shown = shown.adding(days: -1) }
        Button("Next Day") { shown = shown.adding(days: 1) }
        Button("Today") { shown = today }
        Divider()
        Button("All Chores") { showAll = true }
        Button("Reload") { Task { await load() } }
            .keyboardShortcut("r", modifiers: .command)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ screen: ChoresScreen) -> some View {
        let overdue = shown == today ? screen.agenda.overdue.filter { filter.matches($0.assignee) } : []
        if screen.page.chores.isEmpty {
            ContentUnavailableView {
                Label("No chores yet", systemImage: Module.chores.systemImage)
            } actions: {
                if canEdit {
                    Button("New Chore", systemImage: "plus") { editing = .new }
                        .buttonStyle(.glassProminent)
                }
            }
        } else if let items = screen.agenda.items(on: shown) {
            let parts = ChoreParts.items(items, filter: filter)
            if parts.isEmpty && overdue.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to do", systemImage: "checkmark.circle")
                } actions: {
                    if filter != .everyone {
                        Button("Show Everyone’s") { filter = .everyone }
                            .buttonStyle(.glass)
                    }
                }
            } else {
                list(parts: parts, overdue: overdue)
            }
        } else if loading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func list(parts: [(part: ChorePart, items: [ChoreItem])], overdue: [ChoreItem]) -> some View {
        ScrollViewReader { proxy in
            List {
                if !overdue.isEmpty {
                    Section("Overdue") {
                        ForEach(overdue) { row($0, overdue: true) }
                    }
                }
                ForEach(parts, id: \.part) { part in
                    Section {
                        ForEach(part.items) { row($0, overdue: false) }
                    } header: {
                        Label(part.part.title, systemImage: part.part.systemImage)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .refreshable { await load() }
            .task(id: highlighted) {
                guard let id = highlighted else { return }
                if let item = (overdue + parts.flatMap(\.items)).first(where: { $0.choreId == id }) {
                    withAnimation { proxy.scrollTo(item.id, anchor: .center) }
                }
                try? await Task.sleep(for: .seconds(3))
                withAnimation { highlighted = nil }
            }
        }
    }

    private func row(_ item: ChoreItem, overdue: Bool) -> some View {
        ChoreItemRow(item: item, today: today, overdue: overdue, canTick: canTick(item),
                     canSubscribe: !state.isSaved, busy: busy.contains(item.id) || busy.contains(item.choreId),
                     tick: { tick(item) }, subscribe: { subscribe(item.choreId, !item.subscribed) },
                     open: { open(item.choreId) })
            .id(item.id)
            .listRowBackground(highlighted == item.choreId ? ModuleTint.chores.opacity(0.15) : nil)
            .contextMenu {
                if canTick(item) {
                    Button(item.done ? "Not Done" : "Done", systemImage: item.done ? "circle" : "checkmark.circle") {
                        tick(item)
                    }
                }
                if !state.isSaved {
                    Button(item.subscribed ? "Don’t Notify Me" : "Notify Me", systemImage: item.subscribed ? "bell.slash" : "bell") {
                        subscribe(item.choreId, !item.subscribed)
                    }
                }
                Button(canEdit ? "Edit" : "Show", systemImage: canEdit ? "pencil" : "info.circle") { open(item.choreId) }
                if canEdit {
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                }
            }
            .swipeActions(edge: .trailing) {
                if canEdit {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                    Button("Edit", systemImage: "pencil") { open(item.choreId) }
                        .tint(ModuleTint.chores)
                }
            }
            .swipeActions(edge: .leading) {
                if canTick(item) {
                    Button(item.done ? "Not Done" : "Done", systemImage: item.done ? "arrow.uturn.backward" : "checkmark") {
                        tick(item)
                    }
                    .tint(.green)
                }
            }
    }

    // MARK: Actions

    /// Editors tick off any chore, the member it's for theirs.
    private func canTick(_ item: ChoreItem) -> Bool {
        guard !state.isSaved else { return false }
        if state.value?.page.canEdit ?? family.canEdit { return true }
        guard let me = app.me?.id, let assignee = item.assignee else { return false }
        return assignee.id == me
    }

    private func tick(_ item: ChoreItem) {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        let body = ChoreDoneBody(toggling: item)
        perform {
            defer { busy.remove(item.id) }
            let chore = try await ChoreActions.setDone(family, item.choreId, body)
            // At once, before the reload the change starts.
            change(chore) { agenda in
                agenda.update(choreID: item.choreId, day: item.day) { $0.done = body.done }
                if body.done { agenda.overdue.removeAll { $0.id == item.id } }
            }
        }
    }

    private func subscribe(_ id: String, _ on: Bool) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        perform {
            defer { busy.remove(id) }
            let chore = try await ChoreActions.subscribe(family, id, on)
            change(chore) { $0.update(choreID: id) { $0.subscribed = chore.subscribed } }
        }
    }

    /// What's on screen with `chore` as the server answered it.
    private func change(_ chore: Chore, agenda: (inout ChoreAgenda) -> Void) {
        guard case var .loaded(screen) = state else { return }
        if let index = screen.page.chores.firstIndex(where: { $0.id == chore.id }) { screen.page.chores[index] = chore }
        agenda(&screen.agenda)
        state = .loaded(screen)
    }

    private func open(_ id: String) {
        pendingChoreID = id
        openPending()
    }

    /// Opens the chore a route asked for: from the list, else asked of the server.
    private func openPending() {
        guard let id = pendingChoreID, let page = state.value?.page else { return }
        pendingChoreID = nil
        if let chore = page.chores.first(where: { $0.id == id }) {
            editing = .chore(chore)
            return
        }
        perform {
            let response: ChoreResponse = try await family.api.get("/chores/\(id)", query: ChoreActions.today)
            editing = .chore(response.chore)
        }
    }
}

/// Whose chores a list shows: everyone, mine, each person, nobody in particular.
struct ChoreFilterChoices: View {
    @Environment(AppModel.self) private var app
    let people: [ChorePerson]

    var body: some View {
        Text("Everyone").tag(ChoreFilter.everyone)
        if let me = app.me?.id, people.contains(where: { $0.id == me }) {
            Text("Only mine").tag(ChoreFilter.person(me))
        }
        ForEach(people.filter { $0.id != app.me?.id }) { person in
            Text(verbatim: person.name).tag(ChoreFilter.person(person.id))
        }
        Text("Nobody in particular").tag(ChoreFilter.nobody)
    }
}

/// One chore on the day: the tick, its title, the time, the repeat sign and whom it's for (an
/// overdue one its day), and the bell of its notification.
struct ChoreItemRow: View {
    let item: ChoreItem
    let today: Day
    let overdue: Bool
    let canTick: Bool
    let canSubscribe: Bool
    let busy: Bool
    let tick: () -> Void
    let subscribe: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            tickButton
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .lineLimit(2)
                    details
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the chore"))
            Button(action: subscribe) {
                Image(systemName: item.subscribed ? "bell.fill" : "bell")
                    .foregroundStyle(item.subscribed ? ModuleTint.chores : .secondary)
                    .rowHitTarget()
            }
            .buttonStyle(.borderless)
            .disabled(!canSubscribe || busy)
            .accessibilityLabel(item.subscribed ? Text("Notifies you") : Text("Doesn’t notify you"))
            .help(item.subscribed ? Text("Notifies you") : Text("Doesn’t notify you"))
        }
    }

    @ViewBuilder private var details: some View {
        let hasDetails = overdue || item.time != nil || item.repeating || item.assignee != nil
        if hasDetails {
            HStack(spacing: 6) {
                if overdue {
                    Text(ChoreText.dayName(item.day, today: today)).foregroundStyle(.red)
                }
                if let time = item.time {
                    Text(verbatim: time)
                }
                if item.repeating {
                    Image(systemName: "repeat").accessibilityLabel(Text("Repeating"))
                }
                if let assignee = item.assignee {
                    Label(assignee.name, systemImage: "person.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder private var tickButton: some View {
        if busy {
            ProgressView().controlSize(.small).frame(width: 26)
        } else {
            Button(action: tick) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? ModuleTint.chores : .secondary)
                    .frame(width: 26)
                    .rowHitTarget()
            }
            .buttonStyle(.borderless)
            .disabled(!canTick)
            .accessibilityLabel(item.done ? Text("Done") : Text("Not done"))
            .accessibilityHint(Text(item.done ? "Opens it again" : "Ticks it off"))
        }
    }
}

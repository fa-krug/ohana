import SwiftUI

/// Chores: the family's chores, once or repeating, for someone or for nobody in particular, in
/// sections (overdue, today, upcoming, repeating, done lately) and filtered by person. A single
/// chore is ticked off here (by editors, and by its own person); repeating ones are ticked off in
/// Reminders. Editors add (File ▸ New Chore, ⌘N), edit and delete. The chores go into a Reminders
/// list of the user's choice (`ChoreRemindersView`, the More menu). Inside the shell's
/// navigation stack.
struct ChoresView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<ChoresPage> = .idle
    @State private var filter: ChoreFilter = .everyone
    @State private var editing: ChoreEditorTarget?
    @State private var deleting: Chore?
    @State private var showReminders = false
    /// A chore a route asked for, opened once the list is there.
    @State private var pendingChoreID: String?
    /// Chores being ticked off (or opened again) right now.
    @State private var ticking: Set<String> = []

    private var today: Day { Day.today }

    /// Changes to what's shown wait while it's the copy on the device.
    private var canEdit: Bool { (state.value?.canEdit ?? family.canEdit) && !state.isSaved }

    var body: some View {
        LoadStateView(state: state, retry: load) { page in
            content(page)
        }
        .ohanaBackground(ModuleTint.chores)
        .navigationTitle("Chores")
        .toolbar { toolbar }
        .focusedSceneValue(\.newItem, canEdit ? NewItemAction(title: "New Chore") { editing = .new } : nil)
        .focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Chores") { moduleMenu })
        .task(id: family.revision(.chores)) { await load() }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .chores) else { return }
            switch route {
            case .newChore: if canEdit { editing = .new }
            case let .chore(id): pendingChoreID = id
            default: break
            }
            openPending()
        }
        .onChange(of: state.value) { openPending() }
        .sheet(item: $editing) { target in
            editor(target)
        }
        .sheet(isPresented: $showReminders) { ChoreRemindersSheet() }
        .confirmationDialog(
            Text("Delete “\(deleting?.title ?? "")”?"), isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { chore in
            Button("Delete", role: .destructive) {
                perform { try await ChoreActions.delete(family, chore.id) }
            }
        }
    }

    private func load() async {
        await LoadState.run($state, Self.request(family.api))
    }

    /// The chores' GET (the prefetch asks the same); its copy is kept whatever the day.
    static func request(_ api: FamilyAPI) -> CachedGet<ChoresPage> {
        api.cached("/chores", query: ["today": Day.today.description], key: "/chores")
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
                Picker("Whose chores", selection: $filter) { filterChoices }
                    .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: filter == .everyone
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        ToolbarItem {
            Menu {
                moreMenu
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    @ViewBuilder
    private var filterChoices: some View {
        let people = state.value?.people ?? []
        Text("Everyone").tag(ChoreFilter.everyone)
        if let me = app.me?.id, people.contains(where: { $0.id == me }) {
            Text("Only mine").tag(ChoreFilter.person(me))
        }
        ForEach(people.filter { $0.id != app.me?.id }) { person in
            Text(verbatim: person.name).tag(ChoreFilter.person(person.id))
        }
        Text("Nobody in particular").tag(ChoreFilter.nobody)
    }

    @ViewBuilder
    private var moreMenu: some View {
        if !family.api.client.isDemo {
            Section {
                Button("Chores in Reminders", systemImage: "checklist") { showReminders = true }
                if ChoreReminders.shared.settings(for: family.api).listID != nil {
                    Button("Sync with Reminders", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await ChoreReminders.shared.sync(family, reason: .manual) }
                    }
                }
            }
        }
        Section {
            Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
        }
    }

    /// The Chores menu (Mac menu bar, the iPad's ⌘-hold list).
    @ViewBuilder
    private var moduleMenu: some View {
        Picker("Whose Chores", selection: $filter) { filterChoices }
            .pickerStyle(.inline)
        Divider()
        if !family.api.client.isDemo {
            Button("Chores in Reminders…") { showReminders = true }
        }
        Button("Reload") { Task { await load() } }
            .keyboardShortcut("r", modifiers: .command)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ page: ChoresPage) -> some View {
        let sections = ChoreSections.make(page.chores, today: today, filter: filter)
        if page.chores.isEmpty {
            emptyState
        } else if sections.isEmpty {
            ContentUnavailableView {
                Label("No chores here", systemImage: Module.chores.systemImage)
            } description: {
                Text("Nobody’s chores match the filter.")
            } actions: {
                Button("Show Everyone’s") { filter = .everyone }
                    .buttonStyle(.glass)
            }
        } else {
            List {
                ForEach(ChoreSections.Kind.allCases, id: \.self) { kind in
                    let chores = sections.chores(kind)
                    if !chores.isEmpty {
                        Section {
                            ForEach(chores) { row($0) }
                        } header: {
                            Text(Self.title(kind))
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .refreshable { await load() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No chores yet", systemImage: Module.chores.systemImage)
        } description: {
            Text("Chores are the family’s jobs: once or repeating, for someone or for whoever gets to it. They can go into Reminders on each device.")
        } actions: {
            if canEdit {
                Button("New Chore", systemImage: "plus") { editing = .new }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    static func title(_ kind: ChoreSections.Kind) -> LocalizedStringKey {
        switch kind {
        case .overdue: "Overdue"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .repeating: "Repeating"
        case .done: "Done"
        }
    }

    private func row(_ chore: Chore) -> some View {
        ChoreRow(chore: chore, today: today, canTick: canTick(chore), ticking: ticking.contains(chore.id),
                 tick: { tick(chore) }, open: { open(chore) })
            .contextMenu {
                if canTick(chore) {
                    Button(chore.done ? "Not Done" : "Done", systemImage: chore.done ? "circle" : "checkmark.circle") {
                        tick(chore)
                    }
                }
                Button(canEdit ? "Edit" : "Show", systemImage: canEdit ? "pencil" : "info.circle") { open(chore) }
                if canEdit {
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = chore }
                }
            }
            .swipeActions(edge: .trailing) {
                if canEdit {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = chore }
                    Button("Edit", systemImage: "pencil") { open(chore) }
                        .tint(ModuleTint.chores)
                }
            }
            .swipeActions(edge: .leading) {
                if canTick(chore) {
                    Button(chore.done ? "Not Done" : "Done", systemImage: chore.done ? "arrow.uturn.backward" : "checkmark") {
                        tick(chore)
                    }
                    .tint(.green)
                }
            }
    }

    // MARK: Actions

    /// A single chore can be ticked off by editors, and by the member it's for.
    private func canTick(_ chore: Chore) -> Bool {
        guard !chore.isRepeating, !state.isSaved else { return false }
        if state.value?.canEdit ?? family.canEdit { return true }
        guard let me = app.me?.id, let assignee = chore.assignee else { return false }
        return assignee.id == me
    }

    private func tick(_ chore: Chore) {
        guard !ticking.contains(chore.id) else { return }
        ticking.insert(chore.id)
        perform {
            defer { ticking.remove(chore.id) }
            let changed = try await ChoreActions.setDone(family, chore.id, !chore.done)
            // At once, before the reload the change starts.
            if case var .loaded(page) = state, let index = page.chores.firstIndex(where: { $0.id == changed.id }) {
                page.chores[index] = changed
                state = .loaded(page)
            }
        }
    }

    private func open(_ chore: Chore) {
        editing = .chore(chore)
    }

    /// Opens the chore a route asked for: from the list, else asked of the server.
    private func openPending() {
        guard let id = pendingChoreID, let page = state.value else { return }
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

    @ViewBuilder
    private func editor(_ target: ChoreEditorTarget) -> some View {
        let people = state.value?.people ?? []
        switch target {
        case .new:
            // A filter on someone: the new chore is theirs.
            let assignee: String? = if case let .person(id) = filter { id } else { nil }
            ChoreEditor(chore: nil, people: people, draft: .new(on: today, for: assignee))
        case let .chore(chore):
            ChoreEditor(chore: chore, people: people, readOnly: !canEdit, draft: ChoreDraft(input: ChoreInput(chore)))
        }
    }
}

/// One chore: the tick (a single chore) or the repeat sign, its title, when it's due and whom
/// it's for, its note.
struct ChoreRow: View {
    let chore: Chore
    let today: Day
    let canTick: Bool
    let ticking: Bool
    let tick: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            leading
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chore.title)
                        .strikethrough(chore.done)
                        .foregroundStyle(chore.done ? .secondary : .primary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(ChoreText.schedule(chore, today: today))
                            .foregroundStyle(chore.isOverdue(today: today) ? .red : .secondary)
                        if let assignee = chore.assignee {
                            Text(verbatim: "·").foregroundStyle(.tertiary)
                            Label(assignee.name, systemImage: "person.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(2)
                    if !chore.note.isEmpty {
                        Text(chore.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the chore"))
        }
    }

    @ViewBuilder private var leading: some View {
        if chore.isRepeating {
            Image(systemName: "repeat")
                .font(.body.weight(.semibold))
                .foregroundStyle(ModuleTint.chores)
                .frame(width: 26)
                .accessibilityLabel(Text("Repeating"))
        } else if ticking {
            ProgressView().controlSize(.small).frame(width: 26)
        } else {
            Button(action: tick) {
                Image(systemName: chore.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chore.done ? ModuleTint.chores : .secondary)
                    .frame(width: 26)
                    .rowHitTarget()
            }
            .buttonStyle(.borderless)
            .disabled(!canTick)
            .accessibilityLabel(chore.done ? Text("Done") : Text("Not done"))
            .accessibilityHint(Text(chore.done ? "Opens it again" : "Ticks it off"))
        }
    }
}

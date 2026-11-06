import SwiftUI

/// Chores: a day at a time (today first, stepped back and forth), its chores by morning, day and
/// evening, on today the overdue ones above. A chore (a repeating one's occurrence) is ticked off
/// here by editors and by the member it's for; anyone turns its notification on or off for
/// themselves (context menu, swipe, editor; a bell marks theirs). Editors add (File ▸ New Chore, ⌘N),
/// edit and delete; every chore is on the All Chores page (`ChoresAllView`, in the Filter menu). Everything shows and changes at once from
/// the family's `ChoresStore`, which syncs with the server in the background. Inside the shell's
/// navigation stack.
struct ChoresView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    /// The day on screen.
    @State private var shown = Day.today
    /// The last step went to a later day: the list slides in from the trailing edge.
    @State private var steppedForward = true
    @State private var filter: ChoreFilter = .everyone
    @State private var editing: ChoreEditorTarget?
    @State private var deleting: ChoreItem?
    @State private var showAll = false
    @State private var pickingDay = false
    /// A chore a route asked for, opened once the list is there.
    @State private var pendingChoreID: String?
    /// A chore a notification led to, marked on its day for a moment.
    @State private var highlighted: String?

    private var today: Day { Day.today }
    private var store: ChoresStore { family.chores }
    private var canEdit: Bool { store.canEdit }

    var body: some View {
        Group {
            if let page = store.page {
                // Another day slides in from the side it lies on.
                ZStack {
                    content(page)
                        .id(shown)
                        .transition(.push(from: steppedForward ? .trailing : .leading))
                }
            } else if case let .failed(message) = store.phase {
                ContentUnavailableView {
                    Label("Couldn’t load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await store.refresh() } }
                        .buttonStyle(.glassProminent)
                }
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ohanaBackground(ModuleTint.chores)
        .navigationTitle("Chores")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaBar(edge: .top) {
            // As wide as the list below (`readableWidth`), not the window.
            if store.page != nil { dayBar.frame(maxWidth: 760).padding(.horizontal).padding(.vertical, 8) }
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.newItem, canEdit ? NewItemAction(title: "New Chore") { editing = .new } : nil)
        .focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Chores") { moduleMenu })
        .task(id: family.revision(.chores)) {
            store.me = app.me?.id
            await store.refresh()
        }
        .onChange(of: shown, initial: true) { store.show(shown) }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await store.refresh() } }
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
        .onChange(of: store.page) { openPending() }
        .navigationDestination(isPresented: $showAll) {
            ChoresAllView(filter: $filter).assistantButton()
        }
        .sheet(item: $editing) { target in
            ChoreEditorHost(target: target, filter: filter, day: shown)
        }
        .confirmationDialog(
            Text("Delete “\(deleting?.title ?? "")”?"), isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { item in
            Button("Delete", role: .destructive) { store.delete(item.choreId) }
        }
    }

    // MARK: Day

    private func go(to day: Day) {
        guard day != shown else { return }
        steppedForward = day > shown
        withAnimation(.snappy) { shown = day }
    }

    private var dayBar: some View {
        HStack(spacing: 8) {
            Button { go(to: shown.adding(days: -1)) } label: {
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
                DatePicker("Day", selection: Binding(get: { shown.date }, set: { go(to: Day($0)); pickingDay = false }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .frame(minWidth: 300)
                    .presentationCompactAdaptation(.popover)
            }
            if shown != today {
                Button("Today") { go(to: today) }
            }
            Button { go(to: shown.adding(days: 1)) } label: {
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
                Picker("Whose chores", selection: $filter) { ChoreFilterChoices(people: store.page?.people ?? [], me: store.me) }
                    .pickerStyle(.inline)
                Divider()
                Button("All Chores", systemImage: "list.bullet") { showAll = true }
            } label: {
                Label("Filter", systemImage: filter == .everyone
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }

    /// The Chores menu (Mac menu bar, the iPad's ⌘-hold list).
    @ViewBuilder
    private var moduleMenu: some View {
        Picker("Whose Chores", selection: $filter) { ChoreFilterChoices(people: store.page?.people ?? [], me: store.me) }
            .pickerStyle(.inline)
        Divider()
        Button("Previous Day") { go(to: shown.adding(days: -1)) }
        Button("Next Day") { go(to: shown.adding(days: 1)) }
        Button("Today") { go(to: today) }
        Divider()
        Button("All Chores") { showAll = true }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ page: ChoresPage) -> some View {
        let overdue = shown == today ? store.overdue(today: today).filter { filter.matches($0.assignee) } : []
        if page.chores.isEmpty {
            ContentUnavailableView {
                Label("No chores yet", systemImage: Module.chores.systemImage)
            } actions: {
                if canEdit {
                    Button("New Chore", systemImage: "plus") { editing = .new }
                        .buttonStyle(.glassProminent)
                }
            }
        } else {
            let parts = ChoreParts.items(store.items(on: shown), filter: filter)
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
            .readableWidth()
            .refreshable { await store.refresh() }
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
        let canTick = store.canTick(item)
        return ChoreItemRow(item: item, today: today, overdue: overdue, canTick: canTick,
                            tick: { store.toggleDone(item) }, open: { open(item.choreId) })
            .id(item.id)
            .listRowBackground(highlighted == item.choreId ? ModuleTint.chores.opacity(0.15) : nil)
            .contextMenu {
                if canTick {
                    Button(item.done ? "Not Done" : "Done", systemImage: item.done ? "circle" : "checkmark.circle") {
                        withAnimation(.snappy) { store.toggleDone(item) }
                    }
                }
                Button(item.subscribed ? "Don’t Notify Me" : "Notify Me", systemImage: item.subscribed ? "bell.slash" : "bell") {
                    withAnimation(.snappy) { store.subscribe(item.choreId, !item.subscribed) }
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
                if canTick {
                    Button(item.done ? "Not Done" : "Done", systemImage: item.done ? "arrow.uturn.backward" : "checkmark") {
                        withAnimation(.snappy) { store.toggleDone(item) }
                    }
                    .tint(.green)
                }
                Button(item.subscribed ? "Don’t Notify Me" : "Notify Me", systemImage: item.subscribed ? "bell.slash" : "bell") {
                    withAnimation(.snappy) { store.subscribe(item.choreId, !item.subscribed) }
                }
                .tint(ModuleTint.chores)
            }
    }

    // MARK: Opening a chore

    private func open(_ id: String) {
        pendingChoreID = id
        openPending()
    }

    /// Opens the chore a route asked for: from the list, else asked of the server.
    private func openPending() {
        guard let id = pendingChoreID, store.page != nil else { return }
        pendingChoreID = nil
        if let chore = store.chore(id) {
            editing = .chore(chore)
            return
        }
        perform {
            let response: ChoreResponse = try await family.api.get("/chores/\(id)", query: ChoresStore.todayQuery)
            editing = .chore(response.chore)
        }
    }
}

/// Whose chores a list shows: everyone, mine, each person, nobody in particular. Takes `me` rather
/// than reading the environment: it is also drawn into the Mac's menu bar (the Chores menu), which
/// has no `AppModel` in its environment (reading it there crashes).
struct ChoreFilterChoices: View {
    let people: [ChorePerson]
    /// The signed-in account's id.
    let me: String?

    var body: some View {
        Text("Everyone").tag(ChoreFilter.everyone)
        if let me, people.contains(where: { $0.id == me }) {
            Text("Only mine").tag(ChoreFilter.person(me))
        }
        ForEach(people.filter { $0.id != me }) { person in
            Text(verbatim: person.name).tag(ChoreFilter.person(person.id))
        }
        Text("Nobody in particular").tag(ChoreFilter.nobody)
    }
}

/// One chore on the day: the tick, its title, the time, the repeat sign and whom it's for (an
/// overdue one its day), and a bell when it notifies the signed-in account.
struct ChoreItemRow: View {
    let item: ChoreItem
    let today: Day
    let overdue: Bool
    let canTick: Bool
    let tick: () -> Void
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
            if item.subscribed {
                Image(systemName: "bell.fill")
                    .foregroundStyle(ModuleTint.chores)
                    .transition(.symbolEffect(.appear))
                    .accessibilityLabel(Text("Notifies you"))
                    .help(Text("Notifies you"))
            }
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

    /// Counts the taps that ticked it off here (not a change from elsewhere): the bounce and the
    /// haptic follow it.
    @State private var ticked = 0

    private var tickButton: some View {
        Button {
            if !item.done { ticked += 1 }
            withAnimation(.snappy) { tick() }
        } label: {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(item.done ? ModuleTint.chores : .secondary)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                .symbolEffect(.bounce, value: ticked)
                .frame(width: 26)
                .rowHitTarget()
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: ticked)
        .disabled(!canTick)
        .accessibilityLabel(item.done ? Text("Done") : Text("Not done"))
        .accessibilityHint(Text(item.done ? "Opens it again" : "Ticks it off"))
    }
}

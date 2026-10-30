import SwiftUI

/// The calendar (the web app's components/calendar/calendar-page.tsx): entry types per year,
/// day entries, notes, timed events and birthdays. Phones scroll through the year's months with
/// a glass selection bar at the bottom; iPad and Mac show the year grid (12 months × 31 days,
/// like the web) or one month in detail, with the selection's panel underneath.
struct CalendarView: View {
    @Environment(FamilyContext.self) private var family
    @State private var store: CalendarStore?

    var body: some View {
        Group {
            if let store {
                CalendarPlannerView(store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ohanaBackground(ModuleTint.calendar)
        .navigationTitle("Calendar")
        .onAppear {
            if store == nil { store = CalendarStore(api: family.api, readOnly: !family.canEdit) }
        }
    }
}

enum CalendarMode: String {
    case year, month
}

struct CalendarPlannerView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var store: CalendarStore
    @State private var actions: CalendarActions
    @AppStorage("ohana.calendar.mode") private var mode: CalendarMode = .year
    @State private var month = Day.today.month
    @State private var scrollTarget: Int?
    @State private var showSettings = false
    @FocusState private var focused: Bool

    init(store: CalendarStore) {
        self.store = store
        _actions = State(initialValue: CalendarActions(store: store))
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var reloadKey: [Int] { [family.revision(.calendar), family.revision(.events), family.revision(.family)] }

    var body: some View {
        @Bindable var actions = actions
        LoadStateView(state: loadState, retry: { await store.load() }) { _ in
            if compact { phoneLayout } else { wideLayout }
        }
        .toolbar { toolbar }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $actions.sheet) { sheet in
            switch sheet {
            case let .note(days): CalendarNoteSheet(store: store, days: days)
            case let .event(draft): CalendarEventSheet(store: store, draft: draft)
            case .details: CalendarDetailsSheet(store: store, actions: actions)
            }
        }
        .navigationDestination(isPresented: $showSettings) { CalendarSettingsView() }
        .environment(actions)
        .modifier(CalendarToast(text: store.toast))
        .overlay(alignment: .topTrailing) { syncBadge }
        .task(id: reloadKey) { await store.load(quiet: store.isLoaded) }
        .task { await store.poll() }
        .onAppear {
            let family = family
            store.notify = { area in family.didChange(area) }
        }
        .onChange(of: store.focus) { _, day in
            if let day, day.year == store.year {
                month = day.month
                scrollTarget = day.month
            }
        }
    }

    private var loadState: LoadState<Bool> {
        switch store.phase {
        case .loading: .loading
        case .loaded: .loaded(true)
        case let .failed(message): .failed(message)
        case .notFound:
            .failed(String(localized: "This calendar can’t be loaded: the family doesn’t exist (anymore), or you’re not a member of it."))
        }
    }

    // MARK: Phones

    private var phoneLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.readOnly { readOnlyNote }
                    CalendarCoveragePill(store: store)
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(1...12, id: \.self) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(CalendarText.month(year: store.year, month: m))
                                    .font(.title3.bold())
                                    .foregroundStyle(m == Day.today.month && store.year == Day.today.year ? Color.accentColor : .primary)
                                CalendarWeekdayHeader()
                                CalendarMonthGrid(store: store, year: store.year, month: m, style: .compact, rowHeight: 54, touch: true)
                            }
                            .id(m)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .refreshable { await store.load() }
            .safeAreaInset(edge: .bottom) {
                CalendarSelectionBar(store: store, actions: actions)
            }
            .task(id: store.year) {
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(store.year == Day.today.year ? Day.today.month : 1, anchor: .top)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
    }

    // MARK: iPad and Mac

    private var wideLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    CalendarTypeChips(store: store)
                    Spacer(minLength: 0)
                    CalendarCoveragePill(store: store)
                }
                if store.readOnly { readOnlyNote }
                Group {
                    if mode == .year {
                        CalendarYearGrid(store: store, onBegin: { focused = true })
                    } else {
                        monthDetail
                    }
                }
                .glassCard(cornerRadius: 22, padding: 12)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handleKey($0) }
                #if os(macOS)
                .onCopyCommand { copyItems() }
                .onCutCommand { cutItems() }
                .onPasteCommand(of: [.plainText]) { _ in store.paste(text: CalendarPasteboard.string) }
                #endif
                CalendarSelectionPanel(store: store, actions: actions)
            }
            .padding()
        }
        .refreshable { await store.load() }
    }

    private var monthDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(CalendarText.month(year: store.year, month: month)).font(.title2.bold())
                Spacer()
                Button {
                    stepMonth(-1)
                } label: {
                    Label("Previous month", systemImage: "chevron.left")
                }
                Button("Today") {
                    store.setYear(Day.today.year)
                    month = Day.today.month
                }
                Button {
                    stepMonth(1)
                } label: {
                    Label("Next month", systemImage: "chevron.right")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            CalendarWeekdayHeader()
            CalendarMonthGrid(store: store, year: store.year, month: month, style: .detail, rowHeight: 104, touch: false,
                              onBegin: { focused = true })
        }
    }

    private func stepMonth(_ delta: Int) {
        var m = month + delta
        if m < 1 { store.setYear(store.year - 1); m = 12 }
        if m > 12 { store.setYear(store.year + 1); m = 1 }
        month = m
    }

    /// "Saving…" while changes are on their way, "Offline – retrying" while the server can't
    /// be reached (the changes stay and are sent again).
    @ViewBuilder
    private var syncBadge: some View {
        switch store.sync {
        case .idle:
            EmptyView()
        case .saving:
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .glassChip()
                .padding(8)
        case .retrying:
            Label("Offline – retrying", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.red)
                .glassChip(tint: .red)
                .padding(8)
        }
    }

    private var readOnlyNote: some View {
        Label("You are a viewer in this family: you can look at the calendar but not change it.", systemImage: "eye")
            .font(.subheadline)
            .glassCard(cornerRadius: 16, padding: 12, tint: ModuleTint.calendar)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            CalendarYearSwitcher(store: store)
        }
        if !compact {
            ToolbarItem {
                Picker("View", selection: $mode) {
                    Label("Year", systemImage: "calendar").tag(CalendarMode.year)
                    Label("Month", systemImage: "calendar.day.timeline.left").tag(CalendarMode.month)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .fixedSize()
            }
        }
        if !store.readOnly {
            ToolbarItemGroup {
                Button {
                    store.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo)
                .help("Undo (⌘Z)")
                if !compact {
                    Button {
                        store.redo()
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!store.canRedo)
                    .help("Redo (⇧⌘Z)")
                }
            }
            #if os(iOS)
            ToolbarSpacer(.fixed)
            #endif
        }
        ToolbarItem {
            Menu {
                if !store.readOnly {
                    if compact {
                        Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                            .disabled(!store.canRedo)
                    }
                    Button("Add event", systemImage: "calendar.badge.plus") { actions.addEvent() }
                    Button("Icon & note", systemImage: "face.smiling") { actions.editNote() }
                    Divider()
                }
                Button("Select all", systemImage: "checkmark.circle") { store.selectAll() }
                if !store.needsCoverTypes.isEmpty {
                    Button("Next gap", systemImage: "arrow.right.circle") { store.nextGap() }
                }
                Divider()
                Button("Copy days", systemImage: "doc.on.doc") { copy() }
                    .disabled(store.selection.isEmpty)
                if !store.readOnly {
                    Button("Cut days", systemImage: "scissors") { copy(); store.clearSelectedDays() }
                        .disabled(store.selection.isEmpty)
                    Button("Paste", systemImage: "doc.on.clipboard") { store.paste(text: CalendarPasteboard.string) }
                        .disabled(store.selection.isEmpty)
                    Toggle("Skip weekends", isOn: $store.skipWeekends)
                }
                Divider()
                Button("Reload", systemImage: "arrow.clockwise") { Task { await store.load() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Calendar settings", systemImage: "slider.horizontal.3") { showSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        if !compact {
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Label("Calendar settings", systemImage: "slider.horizontal.3")
                }
                .help("Entry types and the calendar feed")
            }
        }
    }

    // MARK: Keyboard and clipboard

    private func copy() {
        if let text = store.copySelection() { CalendarPasteboard.copy(text) }
    }

    #if os(macOS)
    private func copyItems() -> [NSItemProvider] {
        guard let text = store.copySelection() else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }

    private func cutItems() -> [NSItemProvider] {
        let items = copyItems()
        if !items.isEmpty { store.clearSelectedDays() }
        return items
    }
    #endif

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)
        let week = mode == .year ? 31 : 7
        switch press.key {
        case .leftArrow: store.moveFocus(-1, extend: shift)
        case .rightArrow: store.moveFocus(1, extend: shift)
        case .upArrow: store.moveFocus(-week, extend: shift)
        case .downArrow: store.moveFocus(week, extend: shift)
        case .escape: store.deselect()
        case .delete, .deleteForward: store.clearSelectedDays()
        case .pageUp: store.setYear(store.year - 1)
        case .pageDown: store.setYear(store.year + 1)
        default:
            let key = press.characters.lowercased()
            if command {
                switch key {
                case "z": shift ? store.redo() : store.undo()
                case "y": store.redo()
                case "a": store.selectAll()
                #if os(iOS)
                case "c": copy()
                case "x": copy(); store.clearSelectedDays()
                case "v": store.paste(text: CalendarPasteboard.string)
                #endif
                default: return .ignored
                }
            } else if let n = Int(key), (1...9).contains(n) {
                guard n <= store.types.count else { return .ignored }
                store.toggleOnSelection(store.types[n - 1].id)
            } else if key == "n" {
                actions.editNote()
            } else if key == "g" {
                store.nextGap()
            } else if key == "e" {
                actions.addEvent()
            } else if key == "i" || key == "\r" {
                if !store.selection.isEmpty { actions.showDetails() }
            } else {
                return .ignored
            }
        }
        return .handled
    }
}

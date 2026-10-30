import SwiftUI

/// The calendar (the web app's components/calendar/calendar-page.tsx): entry types per year,
/// day entries, notes, timed events and birthdays. A narrow calendar (phones, or a window or
/// split view under 880 points, like the web) scrolls through the year's months with a glass
/// selection bar at the bottom; a wide one shows the year grid (12 months × 31 days, zoomable)
/// or one month in detail, with the selection's panel underneath.
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
    @Environment(\.undoManager) private var undoManager
    @Bindable var store: CalendarStore
    @State private var actions: CalendarActions
    @AppStorage("ohana.calendar.mode") private var mode: CalendarMode = .year
    @AppStorage(CalendarZoom.key) private var zoom = CalendarZoom.initial
    @State private var month = Day.today.month
    @State private var reveal: CalendarReveal?
    @State private var width: CGFloat?
    @State private var monthFrames: [Int: CGRect] = [:]
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

    /// The list of months instead of the year grid: by the calendar's own width.
    private var monthList: Bool { CalendarLayoutRule.monthList(width: width, compact: compact) }

    private var reloadKey: [Int] { [family.revision(.calendar), family.revision(.events), family.revision(.family)] }

    var body: some View {
        @Bindable var actions = actions
        LoadStateView(state: loadState, retry: { await store.load() }) { _ in
            if monthList { listLayout } else { wideLayout }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .toolbar { toolbar }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $actions.sheet) { sheet in
            switch sheet {
            case let .note(days): CalendarNoteSheet(store: store, days: days)
            case let .event(draft): CalendarEventSheet(store: store, draft: draft)
            case .details: CalendarDetailsSheet(store: store, actions: actions)
            case .repeatDays: CalendarRepeatSheet(store: store)
            case .help: CalendarHelpSheet()
            }
        }
        .environment(actions)
        .modifier(CalendarToast(text: store.toast))
        .overlay(alignment: .topTrailing) { syncBadge }
        .background { zoomShortcuts }
        .task(id: reloadKey) { await store.load(quiet: store.isLoaded) }
        .task { await store.poll() }
        .onAppear {
            let family = family
            store.notify = { area in family.didChange(area) }
            store.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, manager in store.undoManager = manager }
        .onChange(of: family.pendingRoute, initial: true) {
            if let route = family.takeRoute(for: .calendar) { open(route) }
        }
        .onChange(of: store.focus) { _, day in
            if let day, day.year == store.year { month = day.month }
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

    // MARK: Routes

    /// `.calendarDay`: the day's year and month, the day selected with its details.
    private func open(_ route: AppRoute) {
        guard case let .calendarDay(day) = route else { return }
        store.show(day)
        month = day.month
        reveal = CalendarReveal(day)
        if monthList { actions.showDetails() } else { actions.sheet = nil }
    }

    private func jumpToGap() {
        if let day = store.nextGap() { reveal = CalendarReveal(day) }
    }

    /// The day to show when a year opens: the selected one, else today in its year.
    private var startDay: Day? {
        if let focus = store.focus, focus.year == store.year { return focus }
        return store.year == Day.today.year ? Day.today : nil
    }

    // MARK: List of months (phones, narrow windows)

    private var listLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.readOnly { readOnlyNote }
                    CalendarCoveragePill(store: store, onJump: { reveal = CalendarReveal($0) })
                    let list = monthListHit
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(1...12, id: \.self) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(CalendarText.month(year: store.year, month: m))
                                    .font(.title3.bold())
                                    .foregroundStyle(m == Day.today.month && store.year == Day.today.year ? Color.accentColor : .primary)
                                CalendarWeekdayHeader()
                                CalendarMonthGrid(store: store, year: store.year, month: m, style: .compact, rowHeight: Self.listRowHeight,
                                                  touch: calendarTouchInput, list: list, onBegin: { focused = true },
                                                  onDoubleTap: { _ in actions.editNote() })
                                    .onGeometryChange(for: CGRect.self) {
                                        $0.frame(in: .named(CalendarMonthList.space))
                                    } action: { monthFrames[m] = $0 }
                            }
                            .id(m)
                        }
                    }
                    .coordinateSpace(.named(CalendarMonthList.space))
                    .modifier(keyboard(enabled: !compact))
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
                proxy.scrollTo(startDay?.month ?? 1, anchor: .top)
            }
            .onChange(of: reveal) { _, reveal in
                guard let reveal, reveal.day.year == store.year else { return }
                withAnimation { proxy.scrollTo(reveal.day.month, anchor: reveal.center ? .top : nil) }
            }
        }
    }

    private static let listRowHeight: CGFloat = 54

    /// Finds days across the months on screen, so a drag can select a range over several.
    private var monthListHit: CalendarMonthList {
        let frames = monthFrames
        let year = store.year
        let firstWeekday = Calendar.current.firstWeekday
        return CalendarMonthList(hit: { point, clamp in
            CalendarGridLayout.day(at: point, inMonths: frames, year: year, firstWeekday: firstWeekday,
                                   rowHeight: Self.listRowHeight, clamp: clamp)
        })
    }

    // MARK: Year grid and month (iPad and Mac)

    private var wideLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        CalendarTypeChips(store: store, wrap: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CalendarCoveragePill(store: store, onJump: { reveal = CalendarReveal($0) })
                    }
                    if store.readOnly { readOnlyNote }
                    Group {
                        if mode == .year {
                            CalendarYearGrid(store: store, reveal: reveal, onBegin: { focused = true },
                                             onDoubleTap: { _ in actions.editNote() })
                        } else {
                            monthDetail
                        }
                    }
                    .glassCard(cornerRadius: 22, padding: 12)
                    .modifier(keyboard(enabled: true))
                    CalendarSelectionPanel(store: store, actions: actions, showZoom: mode == .year)
                }
                .padding()
            }
            .refreshable { await store.load() }
            .task(id: store.year) {
                try? await Task.sleep(for: .milliseconds(80))
                if let day = startDay { reveal = CalendarReveal(day) }
            }
            .onChange(of: reveal) { _, reveal in
                guard let reveal, reveal.day.year == store.year else { return }
                if mode == .year {
                    withAnimation { proxy.scrollTo(CalendarYearGrid.rowID(reveal.day.month), anchor: reveal.center ? .center : nil) }
                } else {
                    month = reveal.day.month
                }
            }
        }
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
            CalendarMonthGrid(store: store, year: store.year, month: month, style: .detail, rowHeight: 104,
                              touch: calendarTouchInput,
                              onBegin: { focused = true }, onDoubleTap: { _ in actions.editNote() })
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
        if !monthList {
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
                    store.performUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo)
                .help("Undo (⌘Z)")
                if !compact {
                    Button {
                        store.performRedo()
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
                        Button("Redo", systemImage: "arrow.uturn.forward") { store.performRedo() }
                            .disabled(!store.canRedo)
                    }
                    Button("Add event", systemImage: "calendar.badge.plus") { actions.addEvent() }
                    Button("Icon & note", systemImage: "face.smiling") { actions.editNote() }
                    Button("Repeat…", systemImage: "repeat") { actions.repeatSelection() }
                        .disabled(!store.canRepeat)
                    Divider()
                }
                Button("Select all", systemImage: "checkmark.circle") { store.selectAll() }
                if !store.needsCoverTypes.isEmpty {
                    Button("Next gap", systemImage: "arrow.right.circle") { jumpToGap() }
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
                if !monthList && mode == .year {
                    Divider()
                    Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = CalendarZoom.step(zoom, 1) }
                        .disabled(CalendarZoom.clamp(zoom) <= CalendarZoom.min)
                    Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = CalendarZoom.step(zoom, -1) }
                        .disabled(CalendarZoom.clamp(zoom) >= CalendarZoom.max)
                }
                Divider()
                Button("Reload", systemImage: "arrow.clockwise") { Task { await store.load() } }
                    .keyboardShortcut("r", modifiers: .command)
                if compact {
                    Button("Help & shortcuts", systemImage: "questionmark.circle") { actions.showHelp() }
                }
                Button("Calendar settings", systemImage: "slider.horizontal.3") { family.open(.settings(.calendar)) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
        if !compact {
            ToolbarItem {
                Button {
                    actions.showHelp()
                } label: {
                    Label("Help & shortcuts", systemImage: "questionmark.circle")
                }
                .help("Help & shortcuts (?)")
            }
            ToolbarItem {
                Button {
                    family.open(.settings(.calendar))
                } label: {
                    Label("Calendar settings", systemImage: "slider.horizontal.3")
                }
                .help("Entry types and the calendar feed")
            }
        }
    }

    /// ⌘+ / ⌘= / ⌘− / ⌘0 zoom the year grid wherever the focus is (like the web); hidden
    /// buttons carry the shortcuts.
    @ViewBuilder
    private var zoomShortcuts: some View {
        if !monthList && mode == .year {
            Group {
                Button("Zoom in") { zoom = CalendarZoom.step(zoom, 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom in") { zoom = CalendarZoom.step(zoom, 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom out") { zoom = CalendarZoom.step(zoom, -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual size") { zoom = CalendarZoom.step(zoom, 0) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Keyboard and clipboard

    private func keyboard(enabled: Bool) -> CalendarKeyboard {
        CalendarKeyboard(enabled: enabled, focused: $focused, handle: handleKey, copy: { store.copySelection() },
                         cut: {
                             let text = store.copySelection()
                             if text != nil { store.clearSelectedDays() }
                             return text
                         },
                         paste: { store.paste(text: $0) })
    }

    private func copy() {
        if let text = store.copySelection() { CalendarPasteboard.copy(text) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)
        let week = monthList || mode == .month ? 7 : 31
        let move = { (delta: Int) in
            if let day = store.moveFocus(delta, extend: shift) { reveal = CalendarReveal(day, center: false) }
        }
        switch press.key {
        case .leftArrow: move(-1)
        case .rightArrow: move(1)
        case .upArrow: move(-week)
        case .downArrow: move(week)
        case .escape: if !store.cancelFill() { store.deselect() }
        case .delete, .deleteForward: store.clearSelectedDays()
        case .pageUp: store.setYear(store.year - 1)
        case .pageDown: store.setYear(store.year + 1)
        default:
            if press.characters == "?" {
                actions.showHelp()
                return .handled
            }
            let key = press.characters.lowercased()
            if command {
                switch key {
                case "z": shift ? store.performRedo() : store.performUndo()
                case "y": store.performRedo()
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
                jumpToGap()
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

/// The calendar's keys (arrows, 1–9, N, G, ?, …) and, on the Mac, the Edit menu's copy, cut and
/// paste, while the grid has the focus.
struct CalendarKeyboard: ViewModifier {
    let enabled: Bool
    let focused: FocusState<Bool>.Binding
    let handle: (KeyPress) -> KeyPress.Result
    let copy: () -> String?
    let cut: () -> String?
    let paste: (String?) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable()
                .focused(focused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handle($0) }
                #if os(macOS)
                .onCopyCommand { items(copy()) }
                .onCutCommand { items(cut()) }
                .onPasteCommand(of: [.plainText]) { _ in paste(CalendarPasteboard.string) }
                #endif
        } else {
            content
        }
    }

    private func items(_ text: String?) -> [NSItemProvider] {
        guard let text else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }
}

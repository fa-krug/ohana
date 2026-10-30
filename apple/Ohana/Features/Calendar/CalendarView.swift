import SwiftUI

/// The calendar (the web app's components/calendar/calendar-page.tsx): entry types per year,
/// day entries, notes, timed events and birthdays. A narrow calendar (phones, or a window or
/// split view under 880 points, like the web) scrolls through the year's months like the web's
/// month view; a wide one shows the year grid (12 months × 31 days, zoomable) or one month in
/// detail, with the selected days' details underneath. On every size the selection's actions
/// and the type chips float in a glass bar at the bottom.
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
    @ScaledMetric(relativeTo: .caption2) private var detailRowHeight: CGFloat = 104

    /// The web month view's gap between the days.
    static let monthSpacing: CGFloat = 3

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
        .environment(\.calendarGridFocused, focused)
        .overlay(alignment: .topTrailing) { syncBadge }
        .background { zoomShortcuts }
        .focusedSceneValue(\.newItem, store.readOnly ? nil : NewItemAction(title: "New Event") {
            actions.addEvent(on: store.selection.isEmpty ? nil : store.focus)
        })
        .focusedSceneValue(\.moduleMenu, moduleMenu)
        .task(id: reloadKey) { await store.load(quiet: store.isLoaded) }
        .task { await store.poll() }
        .onAppear {
            let family = family
            store.notify = { area in family.didChange(area) }
            store.undoManager = undoManager
            // With a keyboard the arrows work right away, without a click into the grid first.
            if !compact { focused = true }
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

    /// Back to today: its year, and its month in view.
    private func showToday() {
        store.setYear(Day.today.year)
        month = Day.today.month
        reveal = CalendarReveal(Day.today)
    }

    /// The floating bar with the toast above it, at the bottom of the calendar.
    private func bottomBar(showDetails: Bool, showZoom: Bool) -> some View {
        VStack(spacing: 0) {
            CalendarToast(store: store)
            CalendarSelectionBar(store: store, actions: actions, showDetails: showDetails, showZoom: showZoom)
        }
    }

    // MARK: List of months (phones, narrow windows)

    /// The web's month view: one calendar per month for the whole year, the month's title
    /// sticking to the top while its days scroll by.
    private var listLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.readOnly { readOnlyNote }
                    CalendarCoveragePill(store: store, onJump: { reveal = CalendarReveal($0) })
                }
                .padding(.horizontal)
                .padding(.top, 8)
                let list = monthListHit
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: .sectionHeaders) {
                    ForEach(1...12, id: \.self) { m in
                        Section {
                            VStack(spacing: 0) {
                                CalendarWeekdayHeader(spacing: Self.monthSpacing)
                                CalendarMonthGrid(store: store, year: store.year, month: m, style: .month,
                                                  spacing: Self.monthSpacing, touch: calendarTouchInput, list: list,
                                                  onBegin: { focused = true }, onDoubleTap: { _ in actions.editNote() })
                                    .onGeometryChange(for: CGRect.self) {
                                        $0.frame(in: .named(CalendarMonthList.space))
                                    } action: { monthFrames[m] = $0 }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                        } header: {
                            monthTitle(m)
                        }
                    }
                }
                .frame(maxWidth: 736)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(CalendarMonthList.space))
                .modifier(keyboard(enabled: !compact))
            }
            .refreshable { await store.load() }
            .safeAreaInset(edge: .bottom) { bottomBar(showDetails: true, showZoom: false) }
            .task(id: store.year) {
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(Self.monthID(startDay?.month ?? 1), anchor: .top)
            }
            .onChange(of: reveal) { _, reveal in
                guard let reveal, reveal.day.year == store.year else { return }
                withAnimation { proxy.scrollTo(Self.monthID(reveal.day.month), anchor: reveal.center ? .top : nil) }
            }
        }
    }

    private static func monthID(_ month: Int) -> String { "calendar-month-\(month)" }

    /// A month's sticking title (the web's `.mv-title`): in the accent color for this month.
    private func monthTitle(_ m: Int) -> some View {
        let current = m == Day.today.month && store.year == Day.today.year
        return Text(CalendarText.month(year: store.year, month: m))
            .font(.headline)
            .foregroundStyle(current ? Color.accentColor : .primary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
            .id(Self.monthID(m))
    }

    /// Finds days across the months on screen, so a drag can select a range over several.
    private var monthListHit: CalendarMonthList {
        let frames = monthFrames
        let year = store.year
        let firstWeekday = Calendar.current.firstWeekday
        return CalendarMonthList(hit: { point, clamp in
            CalendarGridLayout.day(at: point, inMonths: frames, year: year, firstWeekday: firstWeekday,
                                   spacing: Self.monthSpacing, clamp: clamp)
        })
    }

    // MARK: Year grid and month (iPad and Mac)

    private var wideLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        if store.readOnly { readOnlyNote }
                        Spacer(minLength: 0)
                        CalendarCoveragePill(store: store, onJump: { reveal = CalendarReveal($0) })
                    }
                    Group {
                        if mode == .year {
                            CalendarYearGrid(store: store, reveal: reveal, onBegin: { focused = true },
                                             onDoubleTap: { _ in actions.editNote() })
                        } else {
                            monthDetail
                        }
                    }
                    .contentCard(cornerRadius: 22, padding: 12)
                    .modifier(keyboard(enabled: true))
                    CalendarSelectionDetailsCard(store: store, actions: actions)
                }
                .padding()
            }
            .refreshable { await store.load() }
            .safeAreaInset(edge: .bottom) { bottomBar(showDetails: false, showZoom: mode == .year) }
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
                Text(CalendarText.month(year: store.year, month: month))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    stepMonth(-1)
                } label: {
                    Label("Previous month", systemImage: "chevron.left")
                }
                Button("Today") { showToday() }
                Button {
                    stepMonth(1)
                } label: {
                    Label("Next month", systemImage: "chevron.right")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            CalendarWeekdayHeader()
            CalendarMonthGrid(store: store, year: store.year, month: month, style: .detail, rowHeight: detailRowHeight,
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
                .chip()
                .padding(8)
        case .retrying:
            Label("Offline – retrying", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.red)
                .chip(tint: .red)
                .padding(8)
        }
    }

    private var readOnlyNote: some View {
        Label("You are a viewer in this family: you can look at the calendar but not change it.", systemImage: "eye")
            .font(.subheadline)
            .contentCard(cornerRadius: 16, padding: 12, tint: ModuleTint.calendar)
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

    private var canZoom: Bool { !monthList && mode == .year }

    /// The Calendar menu (Mac menu bar, iPad ⌘-hold list): its commands with ⌘ shortcuts. The
    /// grid's own keys without ⌘ (N, E, G, 1–9…) only work while it has the focus.
    private var moduleMenu: ModuleMenu {
        ModuleMenu(title: "Calendar") {
            Button("Today") { showToday() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Previous Year") { store.setYear(store.year - 1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Year") { store.setYear(store.year + 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Next Gap") { jumpToGap() }
                .disabled(store.needsCoverTypes.isEmpty)
            Divider()
            Button("Details") { actions.showDetails() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.selection.isEmpty)
            if !store.readOnly {
                Button("Icon & Note…") { actions.editNote() }
                    .disabled(store.selection.isEmpty)
                Button("Repeat…") { actions.repeatSelection() }
                    .disabled(!store.canRepeat)
                Button("Clear Days") { store.clearSelectedDays() }
                    .disabled(store.selection.isEmpty)
            }
            Button("Clear Selection") { store.deselect() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            if !store.readOnly && !store.types.isEmpty {
                Divider()
                ForEach(Array(store.types.enumerated()), id: \.element.id) { index, type in
                    Toggle(type.name, isOn: Binding(get: { store.selectionHas(type.id) },
                                                    set: { _ in store.toggleOnSelection(type.id) }))
                        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))),
                                                                       modifiers: [.command, .option]) : nil)
                        .disabled(store.selection.isEmpty)
                }
            }
            Divider()
            Button("Zoom In") { zoom = CalendarZoom.step(zoom, 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!canZoom || CalendarZoom.clamp(zoom) <= CalendarZoom.min)
            Button("Zoom Out") { zoom = CalendarZoom.step(zoom, -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!canZoom || CalendarZoom.clamp(zoom) >= CalendarZoom.max)
            Button("Actual Size") { zoom = CalendarZoom.step(zoom, 0) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!canZoom)
            Divider()
            Button("Calendar Help") { actions.showHelp() }
        }
    }

    /// ⌘= zooms in too (the + key without Shift, like the web); a hidden button carries it.
    @ViewBuilder
    private var zoomShortcuts: some View {
        if canZoom {
            Button("Zoom In") { zoom = CalendarZoom.step(zoom, 1) }
                .keyboardShortcut("=", modifiers: .command)
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
                         paste: { store.paste(text: $0) }, delete: { store.clearSelectedDays() })
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

/// The calendar's keys (arrows, 1–9, N, G, ?, …) and, on the Mac, the Edit menu's copy, cut,
/// paste and delete, while the grid has the focus (which it has from the start).
struct CalendarKeyboard: ViewModifier {
    let enabled: Bool
    let focused: FocusState<Bool>.Binding
    let handle: (KeyPress) -> KeyPress.Result
    let copy: () -> String?
    let cut: () -> String?
    let paste: (String?) -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            // The focused day draws its own outline (`calendarGridFocused`), like the web's.
            content
                .focusable()
                .focused(focused)
                .defaultFocus(focused, true)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { handle($0) }
                #if os(macOS)
                .onCopyCommand { items(copy()) }
                .onCutCommand { items(cut()) }
                .onPasteCommand(of: [.plainText]) { _ in paste(CalendarPasteboard.string) }
                .onDeleteCommand { delete() }
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

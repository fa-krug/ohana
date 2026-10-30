import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// How long two clicks on a day may be apart to count as a double click.
private var doubleClickInterval: TimeInterval {
    #if os(macOS)
    NSEvent.doubleClickInterval
    #else
    0.35
    #endif
}

/// Pointer selection (Mac, iPad, grids outside of a scroll view): click selects a day, Shift
/// extends, ⌘ adds or removes one; dragging selects a range (with ⌘ added to the selection);
/// a double click opens the day's note. `hit` finds days in the coordinate space `space`.
struct CalendarPointerSelection: ViewModifier {
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }

    @State private var start: Day?
    @State private var base: Set<Day> = []
    @State private var moved = false
    @State private var lastTap: Day?
    @State private var lastTapTime = Date.distantPast

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        if start == nil {
                            guard let day = hit(value.startLocation, false) else { return }
                            start = day
                            moved = false
                            base = CalendarModifiers.current.contains(.command) ? store.selection : []
                            onBegin()
                        }
                        guard let start, let current = hit(value.location, true) else { return }
                        if !moved && current != start { moved = true }
                        if moved {
                            store.setSelection(base.union(CalendarMath.range(start, current)), anchor: start, focus: current)
                        }
                    }
                    .onEnded { _ in
                        defer { start = nil }
                        guard let start, !moved else { return }
                        let now = Date()
                        if lastTap == start && now.timeIntervalSince(lastTapTime) < doubleClickInterval {
                            lastTap = nil
                            store.select(start)
                            onDoubleTap(start)
                            return
                        }
                        lastTap = start
                        lastTapTime = now
                        let modifiers = CalendarModifiers.current
                        store.tap(start, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
                    }
            )
    }
}

/// Touch selection inside a scroll view: tap selects, long-press and drag selects a range (in
/// the list of months across months: `hit` and `space` cover all of them).
struct CalendarTouchSelection: ViewModifier {
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}

    @State private var start: Day?
    @State private var base: Set<Day> = []
    @State private var pressed = 0

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .named(space)) { location in
                if let day = hit(location, false) {
                    onBegin()
                    store.tap(day)
                }
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
                    .onChanged { value in
                        guard case let .second(true, drag?) = value else { return }
                        if start == nil {
                            guard let day = hit(drag.startLocation, false) else { return }
                            start = day
                            base = store.multiSelect ? store.selection : []
                            pressed += 1
                        }
                        guard let start, let current = hit(drag.location, true) else { return }
                        store.setSelection(base.union(CalendarMath.range(start, current)), anchor: start, focus: current)
                    }
                    .onEnded { _ in start = nil }
            )
            .sensoryFeedback(.selection, trigger: pressed)
    }
}

/// Picks the touch or pointer selection gestures.
struct CalendarSelectionStyle: ViewModifier {
    let touch: Bool
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }

    func body(content: Content) -> some View {
        if touch {
            content.modifier(CalendarTouchSelection(store: store, space: space, hit: hit, onBegin: onBegin))
        } else {
            content.modifier(CalendarPointerSelection(store: store, space: space, hit: hit, onBegin: onBegin,
                                                      onDoubleTap: onDoubleTap))
        }
    }
}

/// The ▪ at the corner of a selection of consecutive days (the web grid's fill handle):
/// dragging it repeats the selected days forwards or backwards over the days it passes.
struct CalendarFillHandle: View {
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var touch = false
    @State private var dragging = false

    var body: some View {
        let size: CGFloat = touch ? 12 : 8
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white, lineWidth: 1.5))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 1)
            .frame(width: touch ? 32 : 16, height: touch ? 32 : 16)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        if !dragging {
                            dragging = store.beginFill()
                            guard dragging else { return }
                        }
                        if let day = hit(value.location, true) { store.dragFill(to: day) }
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        store.endFill()
                    }
            )
            .sensoryFeedback(.selection, trigger: dragging)
            #if os(macOS)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            #endif
            .help("Drag to repeat the selected days")
            .accessibilityLabel("Drag to repeat the selected days")
    }
}

extension View {
    /// The fill handle at the bottom right of `frame` (the selection's last day), when there is
    /// one in this grid.
    func calendarFillHandle(_ frame: CGRect?, store: CalendarStore, space: String, touch: Bool = false,
                            hit: @escaping (CGPoint, Bool) -> Day?) -> some View {
        overlay(alignment: .topLeading) {
            if let frame {
                CalendarFillHandle(store: store, space: space, hit: hit, touch: touch)
                    .position(x: frame.maxX - 2, y: frame.maxY - 2)
            }
        }
    }
}

/// The year as the web shows it: 12 rows of months × 31 days, zoomable (how many days fit
/// across: ⌘+ / ⌘− / pinch / the slider), scrolling sideways when zoomed in. The month names stay.
struct CalendarYearGrid: View {
    let store: CalendarStore
    var reveal: CalendarReveal?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }
    @AppStorage("ohana.calendar.showWeekdays") private var alwaysWeekdays = false
    @AppStorage(CalendarZoom.key) private var zoom = CalendarZoom.initial
    @State private var width: CGFloat = 900
    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var pinchStart: Int?

    static let labelWidth: CGFloat = 40
    static let space = "calendar-year"

    /// The vertical scroll view's id of a month's row.
    static func rowID(_ month: Int) -> String { "calendar-year-month-\(month)" }

    /// Cell width and row height for the available width: all 31 days fill it at zoom 31,
    /// fewer days make the cells grow in both directions.
    static func metrics(width: CGFloat, zoom: Int) -> (cellWidth: CGFloat, rowHeight: CGFloat) {
        let available = max(31, width - labelWidth)
        let days = CGFloat(CalendarZoom.clamp(zoom))
        let row = min(max(available / 31 * 0.95, 22), 40)
        return (available / days, row * 31 / days)
    }

    var body: some View {
        let metrics = Self.metrics(width: width, zoom: zoom)
        let layout = CalendarGridLayout.Year(width: metrics.cellWidth * 31, labelWidth: 0, headerHeight: 22,
                                             rowHeight: metrics.rowHeight)
        HStack(alignment: .top, spacing: 0) {
            labels(layout)
            ScrollView(.horizontal) {
                grid(layout, cellWidth: metrics.cellWidth)
            }
            .scrollPosition($position)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(CalendarZoom.clamp(zoom) < CalendarZoom.max ? .automatic : .hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
        }
        .frame(height: layout.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? zoom
                    pinchStart = start
                    zoom = CalendarZoom.pinched(from: start, magnification: value.magnification)
                }
                .onEnded { _ in pinchStart = nil }
        )
        .onChange(of: zoom) { old, new in keepCenter(from: old, to: new) }
        .onChange(of: reveal) { _, reveal in
            if let reveal { scroll(to: reveal) }
        }
    }

    private func labels(_ layout: CalendarGridLayout.Year) -> some View {
        let year = store.year
        let today = Day.today
        return VStack(spacing: 0) {
            Color.clear.frame(width: Self.labelWidth, height: layout.headerHeight)
            ForEach(1...12, id: \.self) { month in
                Text(CalendarText.shortMonth(month))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(month == today.month && year == today.year ? Color.accentColor : .secondary)
                    .frame(width: Self.labelWidth, height: layout.rowHeight, alignment: .leading)
                    .id(Self.rowID(month))
            }
        }
    }

    private func grid(_ layout: CalendarGridLayout.Year, cellWidth: CGFloat) -> some View {
        let year = store.year
        let today = Day.today
        let zoomed = CalendarZoom.clamp(zoom)
        let showWeekday = alwaysWeekdays || zoomed <= CalendarZoom.showWeekdays || cellWidth >= 30
        let iconSize = min(max(layout.rowHeight * 0.42, 12), 32)
        let hit: (CGPoint, Bool) -> Day? = { layout.day(at: $0, year: year, clamp: $1) }
        let last = store.canRepeat ? store.selectedDays.last : nil
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(1...31, id: \.self) { d in
                    let isToday = year == today.year && d == today.day
                    Text(verbatim: String(d))
                        .font(.caption2.monospacedDigit().weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)
                        .frame(width: cellWidth)
                }
            }
            .frame(height: layout.headerHeight)
            ForEach(1...12, id: \.self) { month in
                HStack(spacing: 0) {
                    ForEach(1...31, id: \.self) { d in
                        if CalendarMath.isValid(year: year, month: month, day: d) {
                            CalendarDayCell(store: store, day: Day(year: year, month: month, day: d), style: .year,
                                            showWeekday: showWeekday, iconSize: iconSize)
                                .padding(1)
                                .frame(width: cellWidth, height: layout.rowHeight)
                                .modifier(CalendarCellMenu(store: store, day: Day(year: year, month: month, day: d)))
                        } else {
                            Color.clear.frame(width: cellWidth, height: layout.rowHeight)
                        }
                    }
                }
            }
        }
        .frame(width: cellWidth * 31, height: layout.height, alignment: .topLeading)
        // iPad: touch gestures, so swipes scroll the zoomed grid (a trackpad click is a tap there).
        .modifier(CalendarSelectionStyle(touch: calendarTouchInput, store: store, space: Self.space, hit: hit,
                                         onBegin: onBegin, onDoubleTap: onDoubleTap))
        .calendarFillHandle(last.map { layout.frame(of: $0) }, store: store, space: Self.space, touch: calendarTouchInput,
                            hit: hit)
        .coordinateSpace(.named(Self.space))
    }

    private var viewport: CGFloat { max(0, width - Self.labelWidth) }

    /// After a zoom: the focused day (else the day in the middle) stays in the middle.
    private func keepCenter(from old: Int, to new: Int) {
        let oldCell = Self.metrics(width: width, zoom: old).cellWidth
        let newCell = Self.metrics(width: width, zoom: new).cellWidth
        let center: CGFloat
        if let focus = store.focus, focus.year == store.year {
            center = (CGFloat(focus.day) - 0.5) * newCell
        } else {
            center = (offset + viewport / 2) / oldCell * newCell
        }
        scrollTo(x: center - viewport / 2, cellWidth: newCell)
    }

    /// Scrolls sideways so the day shows: in the middle, or just enough to see it.
    private func scroll(to reveal: CalendarReveal) {
        guard reveal.day.year == store.year else { return }
        let cell = Self.metrics(width: width, zoom: zoom).cellWidth
        let minX = CGFloat(reveal.day.day - 1) * cell
        if reveal.center {
            scrollTo(x: minX + cell / 2 - viewport / 2, cellWidth: cell)
        } else if minX < offset {
            scrollTo(x: minX, cellWidth: cell)
        } else if minX + cell > offset + viewport {
            scrollTo(x: minX + cell - viewport, cellWidth: cell)
        }
    }

    private func scrollTo(x: CGFloat, cellWidth: CGFloat) {
        let maxX = max(0, cellWidth * 31 - viewport)
        position.scrollTo(x: min(max(0, x), maxX))
    }
}

/// One month as weeks of seven days; `style` picks the cell (compact on phones, detailed in
/// the month view), `touch` the selection gestures (inside a scroll view). In the list of
/// months, `list` finds days across all of them, so a range can go over several months.
struct CalendarMonthGrid: View {
    let store: CalendarStore
    let year: Int
    let month: Int
    var style: CalendarDayCell.Style = .compact
    var rowHeight: CGFloat = 52
    var touch = true
    var list: CalendarMonthList?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }
    @State private var width: CGFloat = 350

    var body: some View {
        let layout = CalendarGridLayout.Month(year: year, month: month, firstWeekday: Calendar.current.firstWeekday,
                                              width: width, rowHeight: rowHeight)
        let own = "calendar-month-\(year)-\(month)"
        let space = list?.space ?? own
        let hit: (CGPoint, Bool) -> Day? = list?.hit ?? { layout.day(at: $0, clamp: $1) }
        let last = store.canRepeat ? store.selectedDays.last : nil
        let handle = last.flatMap { $0.year == year && $0.month == month ? layout.frame(of: $0) : nil }
        VStack(spacing: 0) {
            ForEach(0..<layout.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let n = row * 7 + col - layout.blanks + 1
                        if n >= 1 && n <= layout.dayCount {
                            CalendarDayCell(store: store, day: Day(year: year, month: month, day: n), style: style)
                                .padding(style == .detail ? 2 : 1.5)
                                .frame(width: layout.cellWidth, height: rowHeight)
                                .modifier(CalendarCellMenu(store: store, day: Day(year: year, month: month, day: n)))
                        } else {
                            Color.clear.frame(width: layout.cellWidth, height: rowHeight)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: layout.height, maxHeight: layout.height, alignment: .topLeading)
        .modifier(CalendarSelectionStyle(touch: touch, store: store, space: space, hit: hit, onBegin: onBegin,
                                         onDoubleTap: onDoubleTap))
        .calendarFillHandle(handle, store: store, space: space, touch: touch, hit: hit)
        .coordinateSpace(.named(own))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The list of months (phones, narrow windows): the coordinate space all of them share and
/// the days in it.
struct CalendarMonthList {
    nonisolated static let space = "calendar-months"
    var space = CalendarMonthList.space
    let hit: (CGPoint, Bool) -> Day?
}

/// Weekday letters above a month.
struct CalendarWeekdayHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalendarText.weekdayLetters.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Right-click on a day (Mac): its actions. Phones use the selection bar instead (a long press
/// selects a range there).
struct CalendarCellMenu: ViewModifier {
    let store: CalendarStore
    let day: Day
    @Environment(CalendarActions.self) private var actions: CalendarActions?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.contextMenu {
            if let actions {
                Button("Details…", systemImage: "info.circle") {
                    if !store.selection.contains(day) { store.select(day) }
                    actions.showDetails()
                }
                if !store.readOnly {
                    Button("Icon & note…", systemImage: "face.smiling") {
                        if !store.selection.contains(day) { store.select(day) }
                        actions.editNote()
                    }
                    Button("Add event…", systemImage: "calendar.badge.plus") { actions.addEvent(on: day) }
                    if store.canRepeat && store.selection.contains(day) {
                        Button("Repeat…", systemImage: "repeat") { actions.repeatSelection() }
                    }
                    Divider()
                    Button("Clear", systemImage: "eraser") {
                        if !store.selection.contains(day) { store.select(day) }
                        store.clearSelectedDays()
                    }
                }
            }
        }
        #else
        content
        #endif
    }
}

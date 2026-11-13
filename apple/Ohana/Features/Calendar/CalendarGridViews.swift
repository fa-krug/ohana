import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
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
/// Over an event that can be dragged (`onEvent`) the grid's gesture steps aside while the pointer
/// hovers there, so a drag from it moves the event (`CalendarEventDragSource`).
struct CalendarPointerSelection: ViewModifier {
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }
    var onEvent: ((CGPoint) -> Bool)?

    @State private var start: Day?
    @State private var base: Set<Day> = []
    @State private var moved = false
    @State private var lastTap: Day?
    @State private var lastTapTime = Date.distantPast
    /// The pointer is over an event: only the event's own gestures (its drag) get it.
    @State private var yielding = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        if start == nil {
                            guard let day = hit(value.startLocation, false),
                                  onEvent?(value.startLocation) != true else { return }
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
                    },
                including: yielding ? .subviews : .all
            )
            .onContinuousHover(coordinateSpace: .named(space)) { phase in
                // Not while selecting: a range may go over events.
                guard let onEvent, start == nil else { return }
                let over = if case let .active(point) = phase { onEvent(point) } else { false }
                if over != yielding { yielding = over }
            }
    }
}

/// Touch selection inside a scroll view: tap selects, long-press and drag selects a range (in
/// the list of months across months: `hit` and `space` cover all of them). With an iPad's
/// keyboard, Shift-tap extends the selection and ⌘-tap adds or removes a day, as on the Mac.
/// A long press on an event that can be dragged (`onEvent`) lifts the event instead.
struct CalendarTouchSelection: ViewModifier {
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}
    var onEvent: ((CGPoint) -> Bool)?

    @State private var start: Day?
    @State private var base: Set<Day> = []
    @State private var pressed = 0
    @State private var current: Day?
    @State private var pressEnded = Date.distantPast

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .named(space)) { location in
                // The lift that ends a long press isn't a tap as well.
                guard start == nil, Date().timeIntervalSince(pressEnded) > 0.1 else { return }
                if let day = hit(location, false) {
                    onBegin()
                    let modifiers = CalendarModifiers.current
                    store.tap(day, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
                }
            }
            #if os(iOS)
            // UIKit's long press, not SwiftUI's `LongPressGesture` sequenced before a
            // `DragGesture`: that one holds every touch (since iOS 18), and the scroll view
            // around the grid didn't scroll at all. A swipe fails this one and scrolls.
            .gesture(CalendarLongPressDrag(space: space, skips: onEvent ?? { _ in false }, began: began, moved: moved,
                                           ended: ended))
            #endif
            .sensoryFeedback(.selection, trigger: pressed)
            // A tick for every day the finger moves on to (the press itself has its own).
            .sensoryFeedback(.selection, trigger: current) { old, new in old != nil && new != nil }
    }

    private func began(_ location: CGPoint) {
        guard let day = hit(location, false) else { return }
        start = day
        base = store.multiSelect || CalendarModifiers.current.contains(.command) ? store.selection : []
        pressed += 1
        store.dragging = true
        onBegin()
        moved(location)
    }

    private func moved(_ location: CGPoint) {
        guard let start, let day = hit(location, true) else { return }
        current = day
        store.setSelection(base.union(CalendarMath.range(start, day)), anchor: start, focus: day)
    }

    private func ended() {
        start = nil
        current = nil
        store.dragging = false
        pressEnded = Date()
    }
}

#if os(iOS)
/// Long-press, then drag: where the finger is (in the coordinate space `space`) when the press
/// is recognized and while it moves. A touch that starts where `skips` says (an event that can be
/// dragged) fails it at once, so the event's drag (a UIKit drag interaction) can lift instead.
struct CalendarLongPressDrag: UIGestureRecognizerRepresentable {
    let space: String
    let skips: (CGPoint) -> Bool
    let began: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: () -> Void

    final class Coordinator {
        let converter: CoordinateSpaceConverter
        var skips: (CGPoint) -> Bool = { _ in false }
        init(converter: CoordinateSpaceConverter) { self.converter = converter }
    }

    /// Fails when its first touch starts where it should step aside.
    final class Recognizer: UILongPressGestureRecognizer {
        var skipsStart: () -> Bool = { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            if state == .possible && skipsStart() { state = .failed }
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        recognizer.minimumPressDuration = 0.35
        let coordinator = context.coordinator
        let space = space
        coordinator.skips = skips
        recognizer.skipsStart = { coordinator.skips(coordinator.converter.location(in: .named(space))) }
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        context.coordinator.skips = skips
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        switch recognizer.state {
        case .began: began(context.converter.location(in: .named(space)))
        case .changed: moved(context.converter.location(in: .named(space)))
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }
}
#endif

/// Picks the touch or pointer selection gestures.
struct CalendarSelectionStyle: ViewModifier {
    let touch: Bool
    let store: CalendarStore
    let space: String
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }
    /// Whether a point is on an event that can be dragged: the selection leaves it to the event.
    var onEvent: ((CGPoint) -> Bool)?

    func body(content: Content) -> some View {
        if touch {
            content.modifier(CalendarTouchSelection(store: store, space: space, hit: hit, onBegin: onBegin,
                                                    onEvent: onEvent))
        } else {
            content.modifier(CalendarPointerSelection(store: store, space: space, hit: hit, onBegin: onBegin,
                                                      onDoubleTap: onDoubleTap, onEvent: onEvent))
        }
    }
}

/// The ▪ at the corner of a selection of consecutive days (the web grid's fill handle):
/// dragging it repeats the selected days forwards or backwards over the days it passes. Its
/// touch target is 44 points while it looks small; a tap on it (no drag) reaches the day under it.
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
            .frame(width: touch ? 44 : 16, height: touch ? 44 : 16)
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
                    .onEnded { value in
                        guard dragging else { return }
                        dragging = false
                        let moved = hypot(value.translation.width, value.translation.height) > 4
                        if !moved, store.fill?.targets.isEmpty ?? true, let day = hit(value.location, false) {
                            store.cancelFill()
                            let modifiers = CalendarModifiers.current
                            store.tap(day, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
                        } else {
                            store.endFill()
                        }
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
/// With the weekdays aligned (a setting) the columns are weekdays instead: 37 of them, each month
/// from its 1st's weekday, the header naming the weekdays and each day its number.
struct CalendarYearGrid: View {
    let store: CalendarStore
    var reveal: CalendarReveal?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }
    @AppStorage("ohana.calendar.showWeekdays") private var alwaysWeekdays = false
    @AppStorage(CalendarZoom.key) private var zoom = CalendarZoom.initial
    @AppStorage(CalendarWeekdayAlignment.key) private var alignWeekdays = false
    @State private var width: CGFloat = 900
    @State private var position = ScrollPosition(edge: .leading)
    /// How far the grid is scrolled sideways. Not state: it changes at every frame of a scroll,
    /// and only the zoom and the reveal read it.
    @State private var scrolled = CalendarYearScroll()
    @State private var pinchStart: Int?
    /// The month names, the day numbers and the rows grow with Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 40
    @ScaledMetric(relativeTo: .caption2) private var headerHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var minRow: CGFloat = 22

    static let space = "calendar-year"

    /// Cells at least this wide show their weekday letter.
    static let weekdayCellWidth: CGFloat = 30

    /// The vertical scroll view's id of a month's row.
    static func rowID(_ month: Int) -> String { "calendar-year-month-\(month)" }

    /// Cell width and row height for the available width: all `columns` (31 days, 37 with the
    /// weekdays aligned) fill it at zoom 31, fewer make the cells grow in both directions (zoom 7
    /// shows 7 columns either way). Rows are at least `minRow` high (more with larger text).
    static func metrics(width: CGFloat, zoom: Int, columns: Int = 31, labelWidth: CGFloat = 40,
                        minRow: CGFloat = 22) -> (cellWidth: CGFloat, rowHeight: CGFloat) {
        let all = CGFloat(columns)
        let available = max(all, width - labelWidth)
        let span = CGFloat(CalendarZoom.max - CalendarZoom.min)
        let across = CGFloat(CalendarZoom.min) + CGFloat(CalendarZoom.clamp(zoom) - CalendarZoom.min) * (all - CGFloat(CalendarZoom.min)) / span
        let row = max(min(max(available / all * 0.95, 22), 40), minRow)
        return (available / across, row * all / across)
    }

    /// The grid's layout at a zoom, plain or aligned (in the grid's coordinates: no label column).
    private func yearLayout(zoom: Int, aligned: Bool) -> CalendarGridLayout.Year {
        let columns = CalendarGridLayout.Year.columns(aligned: aligned)
        let metrics = Self.metrics(width: width, zoom: zoom, columns: columns, labelWidth: labelWidth, minRow: minRow)
        return CalendarGridLayout.Year(width: metrics.cellWidth * CGFloat(columns), labelWidth: 0,
                                       headerHeight: headerHeight, rowHeight: metrics.rowHeight,
                                       firstWeekday: aligned ? Calendar.current.firstWeekday : nil)
    }

    var body: some View {
        let layout = yearLayout(zoom: zoom, aligned: alignWeekdays)
        HStack(alignment: .top, spacing: 0) {
            labels(layout)
            ScrollView(.horizontal) {
                grid(layout)
            }
            .scrollPosition($position)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(CalendarZoom.clamp(zoom) < CalendarZoom.max ? .automatic : .hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrolled.offset = x }
        }
        .frame(height: layout.height)
        .accessibilityElement(children: .contain)
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
        .onChange(of: zoom) { old, new in
            keepCenter(from: yearLayout(zoom: old, aligned: alignWeekdays), to: yearLayout(zoom: new, aligned: alignWeekdays))
        }
        .onChange(of: alignWeekdays) { old, new in
            keepCenter(from: yearLayout(zoom: zoom, aligned: old), to: yearLayout(zoom: zoom, aligned: new))
        }
        .onChange(of: reveal) { _, reveal in
            if let reveal { scroll(to: reveal) }
        }
    }

    private func labels(_ layout: CalendarGridLayout.Year) -> some View {
        let year = store.year
        let today = Day.today
        return VStack(spacing: 0) {
            Color.clear.frame(width: labelWidth, height: layout.headerHeight)
            ForEach(1...12, id: \.self) { month in
                Text(CalendarText.shortMonth(month))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(month == today.month && year == today.year ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: labelWidth, height: layout.rowHeight, alignment: .leading)
                    .accessibilityLabel(CalendarText.month(year: year, month: month))
                    .accessibilityAddTraits(.isHeader)
                    .id(Self.rowID(month))
            }
        }
    }

    private func grid(_ layout: CalendarGridLayout.Year) -> some View {
        let cellWidth = layout.cellWidth
        let year = store.year
        let today = Day.today
        let zoomed = CalendarZoom.clamp(zoom)
        let showWeekday = alwaysWeekdays || zoomed <= CalendarZoom.showWeekdays
            || cellWidth >= Self.weekdayCellWidth
        let iconSize = min(max(layout.rowHeight * 0.42, 12), 32)
        let hit: (CGPoint, Bool) -> Day? = { layout.day(at: $0, year: year, clamp: $1) }
        let last = store.canRepeat ? store.selection.max() : nil
        var days = layout
        days.headerHeight = 0
        return VStack(spacing: 0) {
            header(layout, today: today)
            // Builds the days itself, from what they show: a change of the selection, which this
            // grid reads (the fill handle), doesn't build them again.
            CalendarYearDays(store: store, year: year, layout: days, showWeekday: showWeekday, iconSize: iconSize)
                .equatable()
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .onDrop(of: [.ohanaCalendarEvent], delegate: CalendarEventDrop(store: store) { layout.day(at: $0, year: year) })
        #if os(macOS)
        .overlay { CalendarYearPointer(store: store, layout: layout, space: Self.space) }
        #endif
        // iPad: touch gestures, so swipes scroll the zoomed grid (a trackpad click is a tap there).
        .modifier(CalendarSelectionStyle(touch: calendarTouchInput, store: store, space: Self.space, hit: hit,
                                         onBegin: onBegin, onDoubleTap: onDoubleTap))
        .calendarFillHandle(last.map { layout.frame(of: $0) }, store: store, space: Self.space, touch: calendarTouchInput,
                            hit: hit)
        .coordinateSpace(.named(Self.space))
    }

    /// Above the days: their numbers (today's in the accent color), or with the weekdays aligned
    /// the weekdays' letters, a week after another from the locale's first day.
    private func header(_ layout: CalendarGridLayout.Year, today: Day) -> some View {
        let letters = CalendarText.weekdayLetters
        return HStack(spacing: 0) {
            if layout.aligned {
                ForEach(0..<layout.columns, id: \.self) { column in
                    Text(verbatim: letters[column % 7])
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: layout.cellWidth)
                }
            } else {
                ForEach(1...31, id: \.self) { d in
                    let isToday = store.year == today.year && d == today.day
                    Text(verbatim: String(d))
                        .font(.caption2.monospacedDigit().weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: layout.cellWidth)
                }
            }
        }
        .frame(height: layout.headerHeight)
        .accessibilityHidden(true)
    }

    private var viewport: CGFloat { max(0, width - labelWidth) }

    /// After a zoom or a change of the columns: the focused day (else the point in the middle,
    /// as a share of the grid) stays in the middle.
    private func keepCenter(from old: CalendarGridLayout.Year, to new: CalendarGridLayout.Year) {
        let center: CGFloat
        if let focus = store.focus, focus.year == store.year {
            center = new.frame(of: focus).midX
        } else {
            center = (scrolled.offset + viewport / 2) / old.width * new.width
        }
        scrollTo(x: center - viewport / 2, in: new)
    }

    /// Scrolls sideways so the day shows: in the middle, or just enough to see it.
    private func scroll(to reveal: CalendarReveal) {
        guard reveal.day.year == store.year else { return }
        let layout = yearLayout(zoom: zoom, aligned: alignWeekdays)
        let frame = layout.frame(of: reveal.day)
        if reveal.center {
            scrollTo(x: frame.midX - viewport / 2, in: layout)
        } else if frame.minX < scrolled.offset {
            scrollTo(x: frame.minX, in: layout)
        } else if frame.maxX > scrolled.offset + viewport {
            scrollTo(x: frame.maxX - viewport, in: layout)
        }
    }

    private func scrollTo(x: CGFloat, in layout: CalendarGridLayout.Year) {
        let maxX = max(0, layout.width - viewport)
        position.scrollTo(x: min(max(0, x), maxX))
    }
}

/// `CalendarYearGrid`'s horizontal scroll offset, kept without redrawing the grid.
final class CalendarYearScroll {
    var offset: CGFloat = 0
}

/// One month as weeks of seven days; `style` picks the cell (`.month`: the web's month view on
/// phones and in narrow windows, `.detail`: the month in detail), `touch` the selection
/// gestures (inside a scroll view). In the list of months, `list` finds days across all of
/// them, so a range can go over several months.
struct CalendarMonthGrid: View {
    let store: CalendarStore
    let year: Int
    let month: Int
    var style: CalendarDayCell.Style = .month
    /// A fixed row height (the month in detail); nil: cells of 1 : 0.8 like the web's month view.
    var rowHeight: CGFloat?
    var spacing: CGFloat = 0
    var touch = true
    var list: CalendarMonthList?
    var onBegin: () -> Void = {}
    var onDoubleTap: (Day) -> Void = { _ in }
    @Environment(\.calendarGridFocused) private var gridFocused
    @State private var width: CGFloat = 350
    /// How high a month view's row is at least: its day number and note icon, with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var minRow: CGFloat = 30

    /// The coordinate space of a month's grid (its days' events report where they are in it).
    nonisolated static func space(year: Int, month: Int) -> String { "calendar-month-\(year)-\(month)" }

    var body: some View {
        let row = rowHeight ?? CalendarGridLayout.Month.rowHeight(width: width, spacing: spacing, minimum: minRow)
        let layout = CalendarGridLayout.Month(year: year, month: month, firstWeekday: Calendar.current.firstWeekday,
                                              width: width, rowHeight: row, spacing: spacing)
        let own = Self.space(year: year, month: month)
        let space = list?.space ?? own
        let hit: (CGPoint, Bool) -> Day? = list?.hit ?? { layout.day(at: $0, clamp: $1) }
        // Only the month in detail shows events to drag (in its own coordinate space).
        let onEvent: ((CGPoint) -> Bool)? = style == .detail && list == nil && !store.readOnly
            ? { store.isOnEvent($0, day: layout.day(at: $0)) } : nil
        let last = store.canRepeat ? store.selection.max() : nil
        let handle = last.flatMap { $0.year == year && $0.month == month ? layout.frame(of: $0) : nil }
        let context = store.cellContext(gridFocused: gridFocused)
        VStack(spacing: spacing) {
            ForEach(Array(layout.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { col in
                        if let n = week[col] {
                            let day = Day(year: year, month: month, day: n)
                            CalendarDayCell(store: store, day: day, info: store.cell(day, context), style: style)
                                .equatable()
                                .padding(style == .detail ? 2 : 0)
                                .frame(width: layout.cellWidth, height: row)
                                .modifier(CalendarCellMenu(store: store, day: day))
                        } else {
                            Color.clear.frame(width: layout.cellWidth, height: row)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: layout.height, maxHeight: layout.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .onDrop(of: [.ohanaCalendarEvent], delegate: CalendarEventDrop(store: store) { layout.day(at: $0) })
        .modifier(CalendarSelectionStyle(touch: touch, store: store, space: space, hit: hit, onBegin: onBegin,
                                         onDoubleTap: onDoubleTap, onEvent: onEvent))
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

/// The weekdays above a month, in the order of the locale's week: short names like the web's
/// month view ("Mon"), letters where those don't fit.
struct CalendarWeekdayHeader: View {
    var spacing: CGFloat = 0

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(zip(CalendarText.weekdayNames, CalendarText.weekdayLetters).enumerated()), id: \.offset) { _, names in
                ViewThatFits(in: .horizontal) {
                    Text(names.0)
                    Text(names.1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }
}

/// A day's actions on a secondary click (Mac, an iPad's pointer) or a long press held still
/// (iPad). iPhones use the selection bar instead (a long press selects a range there).
struct CalendarCellMenu: ViewModifier {
    let store: CalendarStore
    let day: Day
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .compact {
            content
        } else {
            content.contextMenu { CalendarCellMenuItems(store: store, day: day) }
        }
    }
}

/// The menu's items, a view of their own: what they read of the store (the selection) redraws
/// them, not every day of the grid.
struct CalendarCellMenuItems: View {
    let store: CalendarStore
    let day: Day
    @Environment(CalendarActions.self) private var actions: CalendarActions?

    var body: some View {
        if let actions {
            Button("Details", systemImage: "info.circle") {
                if !store.selection.contains(day) { store.select(day) }
                actions.showDetails()
            }
            if !store.readOnly {
                Button("Icon & note", systemImage: "face.smiling") {
                    if !store.selection.contains(day) { store.select(day) }
                    actions.editNote()
                }
                Button("Add event", systemImage: "calendar.badge.plus") { actions.addEvent(on: day) }
                if store.canRepeat && store.selection.contains(day) {
                    Button("Repeat", systemImage: "repeat") { actions.repeatSelection() }
                }
                Divider()
                Button("Clear", systemImage: "eraser") {
                    if !store.selection.contains(day) { store.select(day) }
                    store.clearSelectedDays()
                }
            }
        }
    }
}

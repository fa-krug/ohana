import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// One day of a grid: tinted by its types, with marks for its note, events and birthdays, the
/// selection and coverage gaps (the web grid's cell).
struct CalendarDayCell: View {
    enum Style { case year, compact, detail }

    let store: CalendarStore
    let day: Day
    let style: Style
    var showWeekday = false

    var body: some View {
        let types = store.types(on: day)
        let note = store.notes[day]
        let events = store.events[day] ?? []
        let birthdays = store.birthdays[day] ?? []
        let selected = store.selection.contains(day)
        let isToday = day == Day.today
        let weekend = CalendarMath.isWeekend(day)
        let gap = store.isGap(day)
        let filled = !types.isEmpty && style != .detail
        let ink: Color = filled ? (CalendarMath.prefersDarkText(on: types[0].color) ? .black : .white) : .primary
        let radius: CGFloat = style == .year ? 4 : 8

        ZStack(alignment: .topLeading) {
            Color.primary.opacity(weekend ? 0.07 : 0.025)
            if !types.isEmpty {
                CalendarFills(types: types).opacity(style == .detail ? 0.28 : 1)
            }
            content(types: types, note: note, events: events, birthdays: birthdays,
                    isToday: isToday, weekend: weekend, ink: ink)
        }
        .clipShape(.rect(cornerRadius: radius))
        .overlay {
            if gap {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.accentColor.opacity(0.22))
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isToday && style == .year {
                RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(types: types, note: note, events: events, birthdays: birthdays, gap: gap))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func content(types: [CalendarEntryType], note: CalendarNote?, events: [CalendarEvent],
                         birthdays: [CalendarBirthday], isToday: Bool, weekend: Bool, ink: Color) -> some View {
        switch style {
        case .year:
            ZStack {
                if showWeekday {
                    Text(CalendarText.weekdayLetters[(CalendarMath.weekday(day) - (Calendar.current.firstWeekday - 1) + 7) % 7])
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(ink.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(2)
                }
                if let note, !note.icon.isEmpty {
                    Text(note.icon).font(.system(size: 12))
                }
                marks(note: note, events: events, birthdays: birthdays, size: 5, ink: ink)
            }
        case .compact:
            VStack(spacing: 2) {
                Text(verbatim: String(day.day))
                    .font(.callout.weight(isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : (weekend && types.isEmpty ? Color.secondary : ink))
                    .frame(width: 26, height: 26)
                    .background { if isToday { Circle().fill(Color.accentColor) } }
                Text(note?.icon ?? " ").font(.system(size: 13)).frame(height: 15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 3)
            .overlay { marks(note: note, events: events, birthdays: birthdays, size: 6, ink: ink) }
        case .detail:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: String(day.day))
                        .font(.callout.weight(isToday ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(isToday ? Color.white : (weekend ? Color.secondary : Color.primary))
                        .frame(minWidth: 24, minHeight: 24)
                        .background { if isToday { Circle().fill(Color.accentColor) } }
                    Spacer(minLength: 0)
                    if let note, !note.icon.isEmpty { Text(note.icon).font(.callout) }
                }
                ForEach(types) { type in
                    Text(type.name)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(CalendarMath.prefersDarkText(on: type.color) ? Color.black : Color.white)
                        .background(Color(calendarHex: type.color), in: .capsule)
                }
                ForEach(events) { event in
                    Label(event.line, systemImage: event.isAppointment ? "stethoscope" : "clock")
                        .font(.caption2)
                        .lineLimit(1)
                }
                ForEach(birthdays, id: \.self) { b in
                    Text(CalendarText.birthday(b)).font(.caption2).lineLimit(1)
                }
                if let note, !note.comment.isEmpty {
                    Text(note.comment).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Small marks in the corners: a comment (top right), events (bottom right), a birthday
    /// (bottom left).
    private func marks(note: CalendarNote?, events: [CalendarEvent], birthdays: [CalendarBirthday],
                       size: CGFloat, ink: Color) -> some View {
        ZStack {
            if let note, !note.comment.isEmpty {
                Triangle()
                    .fill(Color.orange)
                    .frame(width: size + 2, height: size + 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if !events.isEmpty {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 0.5))
                    .frame(width: size, height: size)
                    .padding(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if !birthdays.isEmpty {
                Text(verbatim: "🎂")
                    .font(.system(size: size + 3))
                    .padding(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private func accessibilityText(types: [CalendarEntryType], note: CalendarNote?, events: [CalendarEvent],
                                   birthdays: [CalendarBirthday], gap: Bool) -> String {
        var parts = [CalendarText.longDay(day)]
        parts += types.map(\.name)
        if let note, !note.text.isEmpty { parts.append(note.text) }
        parts += events.map(\.line)
        parts += birthdays.map(CalendarText.birthday)
        if gap { parts.append(String(localized: "Not covered")) }
        return parts.joined(separator: ", ")
    }

    private nonisolated struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}

/// The keyboard modifiers held right now (Mac); touch screens have none.
enum CalendarModifiers {
    static var current: EventModifiers {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var out: EventModifiers = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.option) { out.insert(.option) }
        return out
        #else
        return []
        #endif
    }
}

/// Pointer selection (Mac, iPad, grids outside of a scroll view): click selects a day, Shift
/// extends, ⌘ adds or removes one; dragging selects a range (with ⌘ added to the selection).
struct CalendarPointerSelection: ViewModifier {
    let store: CalendarStore
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}

    @State private var start: Day?
    @State private var base: Set<Day> = []
    @State private var moved = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
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
                        let modifiers = CalendarModifiers.current
                        store.tap(start, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
                    }
            )
    }
}

/// Touch selection inside a scroll view: tap selects, long-press and drag selects a range.
struct CalendarTouchSelection: ViewModifier {
    let store: CalendarStore
    let hit: (CGPoint, Bool) -> Day?

    @State private var start: Day?
    @State private var base: Set<Day> = []
    @State private var pressed = 0

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture { location in
                if let day = hit(location, false) { store.tap(day) }
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
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

/// The year as the web shows it: 12 rows of months × 31 days.
struct CalendarYearGrid: View {
    let store: CalendarStore
    var onBegin: () -> Void = {}
    @AppStorage("ohana.calendar.showWeekdays") private var alwaysWeekdays = false
    @State private var width: CGFloat = 900

    var body: some View {
        let layout = layout(for: width)
        let year = store.year
        let showWeekday = alwaysWeekdays || layout.cellWidth >= 30
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.labelWidth)
                ForEach(1...31, id: \.self) { d in
                    Text(verbatim: String(d))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: layout.cellWidth)
                }
            }
            .frame(height: layout.headerHeight)
            ForEach(1...12, id: \.self) { month in
                HStack(spacing: 0) {
                    Text(CalendarText.shortMonth(month))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(month == Day.today.month && year == Day.today.year ? Color.accentColor : .secondary)
                        .frame(width: layout.labelWidth, alignment: .leading)
                    ForEach(1...31, id: \.self) { d in
                        if CalendarMath.isValid(year: year, month: month, day: d) {
                            CalendarDayCell(store: store, day: Day(year: year, month: month, day: d), style: .year,
                                            showWeekday: showWeekday)
                                .padding(1)
                                .frame(width: layout.cellWidth, height: layout.rowHeight)
                                .modifier(CalendarCellMenu(store: store, day: Day(year: year, month: month, day: d)))
                        } else {
                            Color.clear.frame(width: layout.cellWidth, height: layout.rowHeight)
                        }
                    }
                }
            }
        }
        .frame(height: layout.height)
        .modifier(CalendarPointerSelection(store: store, hit: { layout.day(at: $0, year: year, clamp: $1) }, onBegin: onBegin))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func layout(for width: CGFloat) -> CalendarGridLayout.Year {
        var layout = CalendarGridLayout.Year(width: width)
        layout.rowHeight = min(max(layout.cellWidth * 0.95, 22), 40)
        return layout
    }
}

/// One month as weeks of seven days; `style` picks the cell (compact on phones, detailed in
/// the month view), `touch` the selection gestures (inside a scroll view).
struct CalendarMonthGrid: View {
    let store: CalendarStore
    let year: Int
    let month: Int
    var style: CalendarDayCell.Style = .compact
    var rowHeight: CGFloat = 52
    var touch = true
    var onBegin: () -> Void = {}
    @State private var width: CGFloat = 350

    var body: some View {
        let layout = CalendarGridLayout.Month(year: year, month: month, firstWeekday: Calendar.current.firstWeekday,
                                              width: width, rowHeight: rowHeight)
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
        .modifier(selection(layout))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func selection(_ layout: CalendarGridLayout.Month) -> some ViewModifier {
        CalendarSelectionStyle(touch: touch, store: store, hit: { layout.day(at: $0, clamp: $1) }, onBegin: onBegin)
    }
}

/// Picks the touch or pointer selection gestures.
struct CalendarSelectionStyle: ViewModifier {
    let touch: Bool
    let store: CalendarStore
    let hit: (CGPoint, Bool) -> Day?
    var onBegin: () -> Void = {}

    func body(content: Content) -> some View {
        if touch {
            content.modifier(CalendarTouchSelection(store: store, hit: hit))
        } else {
            content.modifier(CalendarPointerSelection(store: store, hit: hit, onBegin: onBegin))
        }
    }
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

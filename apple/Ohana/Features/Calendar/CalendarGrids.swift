import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(GameController)
import GameController
#endif

extension EnvironmentValues {
    /// The grid has the keyboard focus: the focused day shows its outline (the web's `.focus`).
    @Entry var calendarGridFocused = false
}

/// What the cells of one grid share, from the store once per redraw of the grid.
struct CalendarCellContext {
    let roles: [String: CalendarRole]
    let today: Day
    /// The focused day while the grid has the keyboard focus.
    let focus: Day?
    /// The types every selected day has (the chips that show as on).
    let selectionTypes: Set<String>
}

/// One day of a grid: filled with its types' colors, with marks for its note, events and
/// birthdays, today, the selection and coverage gaps (the web grid's cell). `.month` is the web's
/// month view (phones, narrow windows), `.year` the 12 × 31 grid, `.detail` the month in detail.
/// The grid hands it its values (`CalendarStore.cell`) instead of the cell reading the store:
/// a year has 365 of them, and a cell that read the store would redraw on every change of the
/// selection. Equal values skip the redraw (`.equatable()`).
struct CalendarDayCell: View, Equatable {
    enum Style { case year, month, detail }

    /// What the day shows.
    struct Info: Equatable {
        var types: [CalendarEntryType] = []
        var note: CalendarNote?
        var events: [CalendarEvent] = []
        var birthdays: [CalendarBirthday] = []
        var selected = false
        /// The fill handle would fill it.
        var preview = false
        /// An event dragged over the grid would land on it.
        var dropTarget = false
        var focused = false
        var isToday = false
        var gap = false
        /// The types VoiceOver's actions offer to remove: the selection's when it is selected, else its own.
        var onTypes: Set<String> = []
        /// The year's types, for VoiceOver's actions.
        var allTypes: [CalendarEntryType] = []
        var readOnly = true
    }

    /// For the actions (VoiceOver's, run later); the body doesn't read it.
    let store: CalendarStore
    let day: Day
    let info: Info
    let style: Style
    var showWeekday = false
    /// The year grid's note icon grows with the zoom.
    var iconSize: CGFloat = 12

    @Environment(CalendarActions.self) private var actions: CalendarActions?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption2) private var yearLetter: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var yearMark: CGFloat = 5
    @ScaledMetric(relativeTo: .caption2) private var yearCake: CGFloat = 8

    static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.day == b.day && a.info == b.info && a.style == b.style
            && a.showWeekday == b.showWeekday && a.iconSize == b.iconSize
    }

    var body: some View {
        let types = info.types
        let note = info.note
        let events = info.events
        let birthdays = info.birthdays
        let selected = info.selected
        let preview = info.preview
        let focused = info.focused
        let isToday = info.isToday
        let weekend = CalendarMath.isWeekend(day)
        let gap = info.gap
        let filled = !types.isEmpty && style != .detail
        let ink: Color = filled ? (CalendarMath.prefersDarkText(on: types[0].color) ? .black : .white) : .primary
        let radius: CGFloat = style == .year ? 4 : (style == .month ? 9 : 8)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack(alignment: .topLeading) {
            background(weekend: weekend)
            if !types.isEmpty {
                CalendarFills(types: types).opacity(style == .detail ? 0.28 : 1)
            }
            content(types: types, note: note, events: events, birthdays: birthdays,
                    isToday: isToday, weekend: weekend, ink: ink, filled: filled)
        }
        .clipShape(shape)
        .overlay {
            if gap {
                shape.strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
        }
        .overlay {
            if isToday { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
        }
        .overlay {
            if selected {
                // A tint and a border: a tint alone hardly shows on days filled with a type's color.
                shape.fill(Color.accentColor.opacity(0.3))
                    .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 2))
            } else if preview {
                // The fill handle would fill it.
                shape.fill(Color.accentColor.opacity(0.1))
                    .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
            }
        }
        .overlay {
            if info.dropTarget {
                // Like the fill handle's preview, a little stronger: it shows on selected days too.
                shape.fill(Color.accentColor.opacity(0.15))
                    .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 2])))
            }
        }
        .overlay {
            if focused {
                // Thicker than the selection's border, with a white line inside it.
                shape.strokeBorder(Color.accentColor, lineWidth: 3.5)
                    .overlay(shape.inset(by: 3.5).strokeBorder(Color.white, lineWidth: 1.5))
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(day: day, types: types, note: note, events: events,
                                                   birthdays: birthdays, gap: gap))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .modifier(CalendarDayAccessibilityActions(store: store, actions: actions, day: day, info: info))
        #if os(macOS)
        // The web grid's tooltip: the day, its types, note, events and birthdays.
        .help(Self.tooltip(day: day, types: types, note: note, events: events, birthdays: birthdays))
        #endif
    }

    /// The month view's cells sit on the card color (weekends paler), like the web's.
    @ViewBuilder
    private func background(weekend: Bool) -> some View {
        if style == .month {
            Color.cardBackground.opacity(weekend ? 0.4 : 1)
        } else {
            Color.primary.opacity(weekend ? 0.07 : 0.025)
        }
    }

    @ViewBuilder
    private func content(types: [CalendarEntryType], note: CalendarNote?, events: [CalendarEvent],
                         birthdays: [CalendarBirthday], isToday: Bool, weekend: Bool, ink: Color,
                         filled: Bool) -> some View {
        switch style {
        case .year:
            ZStack {
                if showWeekday {
                    Text(CalendarText.weekdayLetters[(CalendarMath.weekday(day) - (Calendar.current.firstWeekday - 1) + 7) % 7])
                        .font(.system(size: yearLetter, weight: .medium))
                        .foregroundStyle(ink.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(2)
                }
                if let note, !note.icon.isEmpty {
                    Text(note.icon).font(.system(size: iconSize))
                }
                marks(note: note, events: events, birthdays: birthdays, dot: yearMark, cake: .system(size: yearCake),
                      inset: 2, ink: ink, filled: filled)
            }
        case .month:
            monthContent(note: note, events: events, birthdays: birthdays, weekend: weekend, ink: ink, filled: filled)
        case .detail:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: String(day.day))
                        .font(.callout.weight(isToday ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(isToday ? Color.accentColor : (weekend ? Color.secondary : Color.primary))
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(CalendarEventDragSource(store: store, event: event, enabled: !info.readOnly,
                                                          inGrid: true))
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

    /// The web's month view: the day number top left, the note's icon in the middle, the marks
    /// in the corners. At accessibility sizes the icon goes under the number and the cake is
    /// left out (the day's label still has it), so the number never gets clipped.
    private func monthContent(note: CalendarNote?, events: [CalendarEvent], birthdays: [CalendarBirthday],
                              weekend: Bool, ink: Color, filled: Bool) -> some View {
        let large = typeSize.isAccessibilitySize
        let number = Text(verbatim: String(day.day))
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(filled ? ink : (weekend ? Color.secondary : Color.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        let icon = note.map(\.icon).flatMap { $0.isEmpty ? nil : $0 }
        return ZStack(alignment: .topLeading) {
            if large {
                VStack(alignment: .leading, spacing: 0) {
                    number
                    if let icon { Text(icon).font(.title3).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                }
                .padding(.top, 4)
                .padding(.horizontal, 6)
            } else {
                number
                    .padding(.top, 5)
                    .padding(.leading, 7)
                if let icon {
                    Text(icon)
                        .font(.title3)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: 4)
                }
            }
            marks(note: note, events: events, birthdays: large ? [] : birthdays, dot: 8, cake: .caption,
                  inset: 6, ink: ink, filled: filled)
        }
    }

    /// The marks in the corners, where the web has them: a comment (a triangle top right), events
    /// (a dot bottom left), a birthday (a cake bottom right).
    private func marks(note: CalendarNote?, events: [CalendarEvent], birthdays: [CalendarBirthday],
                       dot: CGFloat, cake: Font, inset: CGFloat, ink: Color, filled: Bool) -> some View {
        ZStack {
            if let note, !note.comment.isEmpty {
                Triangle()
                    .fill(filled ? ink.opacity(0.85) : Color.accentColor)
                    .frame(width: dot + 4, height: dot + 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if !events.isEmpty {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(Color.cardBackground, lineWidth: 1.5))
                    .frame(width: dot, height: dot)
                    .padding(.leading, inset)
                    .padding(.bottom, inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            if !birthdays.isEmpty {
                Text(verbatim: "🎂")
                    .font(cake)
                    .padding(.trailing, inset - 1)
                    .padding(.bottom, inset - 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    /// What VoiceOver reads for a day: the date, its types, note, events, birthdays and a gap.
    static func accessibilityText(day: Day, types: [CalendarEntryType], note: CalendarNote?, events: [CalendarEvent],
                                  birthdays: [CalendarBirthday], gap: Bool) -> String {
        var parts = [CalendarText.longDay(day)]
        parts += types.map(\.name)
        if let note, !note.text.isEmpty { parts.append(note.text) }
        parts += events.map(\.line)
        parts += birthdays.map(CalendarText.birthday)
        if gap { parts.append(String(localized: "Not covered")) }
        return parts.joined(separator: ", ")
    }

    /// The Mac's tooltip for a day (the web grid's): the day, its types, note, events and birthdays.
    static func tooltip(day: Day, types: [CalendarEntryType], note: CalendarNote?, events: [CalendarEvent],
                        birthdays: [CalendarBirthday]) -> String {
        var lines = [CalendarText.longDay(day)]
        if !types.isEmpty { lines.append(types.map(\.name).joined(separator: ", ")) }
        if let note, !note.text.isEmpty { lines.append(note.text) }
        lines += events.map { "🕑 " + $0.line }
        lines += birthdays.map(CalendarText.birthday)
        return lines.joined(separator: "\n")
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

/// VoiceOver's way to do what a pointer or touch does on a day: activating it selects it (like
/// a tap), the actions add it, extend the selection to it, toggle each type, edit the note and
/// open its events. After each change VoiceOver hears how many days are selected.
struct CalendarDayAccessibilityActions: ViewModifier {
    let store: CalendarStore
    let actions: CalendarActions?
    let day: Day
    let info: CalendarDayCell.Info

    func body(content: Content) -> some View {
        let selected = info.selected
        content
            .accessibilityAction { change { store.tap(day) } }
            .accessibilityAction(named: selected ? Text("Remove from selection") : Text("Add to selection")) {
                change { store.toggleDay(day) }
            }
            .accessibilityAction(named: Text("Extend selection to here")) {
                change { store.tap(day, extend: true) }
            }
            .accessibilityActions {
                if !info.readOnly {
                    ForEach(info.allTypes) { type in
                        let on = info.onTypes.contains(type.id)
                        Button(on ? String(localized: "Remove \(type.name)") : String(localized: "Add \(type.name)")) {
                            onDay { store.toggleOnSelection(type.id) }
                        }
                    }
                    Button("Edit note") { onDay { actions?.editNote() } }
                    Button("Add event") { actions?.addEvent(on: day) }
                }
                ForEach(info.events) { event in
                    Button(String(localized: "Open event \(event.line)")) {
                        if !store.readOnly { actions?.editEvent(event) } else { onDay { actions?.showDetails() } }
                    }
                }
            }
    }

    /// A change of the selection, then its count read out.
    private func change(_ action: () -> Void) {
        action()
        AccessibilityNotification.Announcement(CalendarText.selectionAnnouncement(store.selection.count)).post()
    }

    /// Acts on the selection when the day is part of it, else on the day alone (selected first).
    private func onDay(_ action: () -> Void) {
        if !store.selection.contains(day) { change { store.select(day) } }
        action()
    }
}

/// The keyboard modifiers held right now: the Mac's from AppKit, an iPad's hardware keyboard's
/// from GameController (touch screens without one have none). Shift extends the selection, ⌘
/// adds or removes a day.
enum CalendarModifiers {
    static var current: EventModifiers {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var out: EventModifiers = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.option) { out.insert(.option) }
        return out
        #elseif canImport(GameController)
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return [] }
        func pressed(_ codes: GCKeyCode...) -> Bool { codes.contains { keys.button(forKeyCode: $0)?.isPressed == true } }
        var out: EventModifiers = []
        if pressed(.leftShift, .rightShift) { out.insert(.shift) }
        if pressed(.leftGUI, .rightGUI) { out.insert(.command) }
        if pressed(.leftAlt, .rightAlt) { out.insert(.option) }
        return out
        #else
        return []
        #endif
    }
}

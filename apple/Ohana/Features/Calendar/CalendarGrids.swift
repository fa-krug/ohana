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

/// One day of a grid: filled with its types' colors, with marks for its note, events and
/// birthdays, today, the selection and coverage gaps (the web grid's cell). `.month` is the web's
/// month view (phones, narrow windows), `.year` the 12 × 31 grid, `.detail` the month in detail.
struct CalendarDayCell: View {
    enum Style { case year, month, detail }

    let store: CalendarStore
    let day: Day
    let style: Style
    var showWeekday = false
    /// The year grid's note icon grows with the zoom.
    var iconSize: CGFloat = 12

    @Environment(CalendarActions.self) private var actions: CalendarActions?
    @Environment(\.calendarGridFocused) private var gridFocused
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption2) private var yearLetter: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var yearMark: CGFloat = 5
    @ScaledMetric(relativeTo: .caption2) private var yearCake: CGFloat = 8

    var body: some View {
        let types = store.types(on: day)
        let note = store.notes[day]
        let events = store.events[day] ?? []
        let birthdays = store.birthdays[day] ?? []
        let selected = store.selection.contains(day)
        let preview = store.fill?.targetSet.contains(day) ?? false
        let focused = gridFocused && store.focus == day
        let isToday = day == Day.today
        let weekend = CalendarMath.isWeekend(day)
        let gap = store.isGap(day)
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
                shape.fill(Color.accentColor.opacity(0.24))
            } else if preview {
                // The fill handle would fill it.
                shape.fill(Color.accentColor.opacity(0.1))
                    .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2])))
            }
        }
        .overlay {
            if focused {
                shape.inset(by: 1).strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(day: day, types: types, note: note, events: events,
                                                   birthdays: birthdays, gap: gap))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .modifier(CalendarDayAccessibilityActions(store: store, actions: actions, day: day, events: events))
        #if os(macOS)
        // The web grid's tooltip: the day, its types, note, events and birthdays.
        .help(tooltip(types: types, note: note, events: events, birthdays: birthdays))
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

    private func tooltip(types: [CalendarEntryType], note: CalendarNote?, events: [CalendarEvent],
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
private struct CalendarDayAccessibilityActions: ViewModifier {
    let store: CalendarStore
    let actions: CalendarActions?
    let day: Day
    let events: [CalendarEvent]

    func body(content: Content) -> some View {
        let selected = store.selection.contains(day)
        content
            .accessibilityAction { change { store.tap(day) } }
            .accessibilityAction(named: selected ? Text("Remove from selection") : Text("Add to selection")) {
                change { store.toggleDay(day) }
            }
            .accessibilityAction(named: Text("Extend selection to here")) {
                change { store.tap(day, extend: true) }
            }
            .accessibilityActions {
                if !store.readOnly {
                    ForEach(store.types) { type in
                        let on = selected ? store.selectionHas(type.id) : store.types(on: day).contains(type)
                        Button(on ? String(localized: "Remove \(type.name)") : String(localized: "Add \(type.name)")) {
                            onDay { store.toggleOnSelection(type.id) }
                        }
                    }
                    Button("Edit note") { onDay { actions?.editNote() } }
                    Button("Add event") { actions?.addEvent(on: day) }
                }
                ForEach(events) { event in
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

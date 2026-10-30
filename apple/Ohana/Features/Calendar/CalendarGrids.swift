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
    /// The year grid's note icon grows with the zoom.
    var iconSize: CGFloat = 12

    var body: some View {
        let types = store.types(on: day)
        let note = store.notes[day]
        let events = store.events[day] ?? []
        let birthdays = store.birthdays[day] ?? []
        let selected = store.selection.contains(day)
        let preview = store.fill?.targetSet.contains(day) ?? false
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
            } else if preview {
                // The fill handle would fill it.
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color.accentColor.opacity(0.12))
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            } else if isToday && style == .year {
                RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(types: types, note: note, events: events, birthdays: birthdays, gap: gap))
        #if os(macOS)
        // The web grid's tooltip: the day, its types, note, events and birthdays.
        .help(tooltip(types: types, note: note, events: events, birthdays: birthdays))
        #endif
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
                    Text(note.icon).font(.system(size: iconSize))
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


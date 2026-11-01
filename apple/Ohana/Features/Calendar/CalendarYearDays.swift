import SwiftUI

/// The days of the year grid, drawn as one view (the year style of `CalendarDayCell`). As 365
/// cell views the year took long to lay out again at every change of its width (the assistant
/// panel sliding in, the window being resized), and as one canvas per month each canvas waited
/// for a new surface of its size. The grid's gestures find the days by position; VoiceOver gets
/// one element per day (`accessibilityChildren`), the Mac the tooltip and menu of the day under
/// the pointer (`CalendarYearPointer`), the iPad a menu per day.
struct CalendarYearDays: View, Equatable {
    let store: CalendarStore
    let year: Int
    /// The days of each month, January first, each month from the 1st.
    let months: [[CalendarDayCell.Info]]
    let cellWidth: CGFloat
    let rowHeight: CGFloat
    let showWeekday: Bool
    let iconSize: CGFloat

    @Environment(CalendarActions.self) private var actions: CalendarActions?
    @ScaledMetric(relativeTo: .caption2) private var letterSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var markSize: CGFloat = 5
    @ScaledMetric(relativeTo: .caption2) private var cakeSize: CGFloat = 8

    static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.year == b.year && a.months == b.months && a.cellWidth == b.cellWidth
            && a.rowHeight == b.rowHeight && a.showWeekday == b.showWeekday && a.iconSize == b.iconSize
    }

    private func day(_ month: Int, _ index: Int) -> Day { Day(year: year, month: month + 1, day: index + 1) }

    var body: some View {
        Canvas { context, _ in
            var cache = DrawCache(size: CGSize(width: cellWidth - 2, height: rowHeight - 2))
            for (month, infos) in months.enumerated() {
                for (index, info) in infos.enumerated() {
                    let origin = CGPoint(x: CGFloat(index) * cellWidth + 1, y: CGFloat(month) * rowHeight + 1)
                    draw(day(month, index), info, at: origin, context, cache: &cache)
                }
            }
        }
        .frame(width: cellWidth * 31, height: rowHeight * 12, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(months.indices, id: \.self) { month in
                    HStack(spacing: 0) {
                        ForEach(months[month].indices, id: \.self) { index in
                            let info = months[month][index]
                            let day = day(month, index)
                            Color.clear
                                .frame(width: cellWidth, height: rowHeight)
                                .accessibilityElement()
                                .accessibilityLabel(CalendarDayCell.accessibilityText(
                                    day: day, types: info.types, note: info.note, events: info.events,
                                    birthdays: info.birthdays, gap: info.gap))
                                .accessibilityAddTraits(info.selected ? [.isButton, .isSelected] : .isButton)
                                .modifier(CalendarDayAccessibilityActions(store: store, actions: actions, day: day,
                                                                          info: info))
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            // Touch has no pointer to follow: a menu per day (a long press).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(months.indices, id: \.self) { month in
                    HStack(spacing: 0) {
                        ForEach(months[month].indices, id: \.self) { index in
                            Color.clear
                                .frame(width: cellWidth, height: rowHeight)
                                .contentShape(.rect)
                                .modifier(CalendarCellMenu(store: store, day: day(month, index)))
                        }
                    }
                }
            }
        }
        #endif
    }

    // MARK: Drawing (as `CalendarDayCell` lays out `.year`)

    /// What every day of a drawing shares, made once: the cell's rounded shapes (all days have
    /// the same size), the types' colors and the weekday letters.
    private struct DrawCache {
        let size: CGSize
        let shape: Path
        let border: Path
        let today: Path
        let focus: Path
        let focusInner: Path
        private var colors: [String: (fill: Color, dark: Bool)] = [:]
        private var letters: [String: GraphicsContext.ResolvedText] = [:]

        init(size: CGSize) {
            self.size = size
            func rounded(_ inset: CGFloat) -> Path {
                RoundedRectangle(cornerRadius: max(0, 4 - inset), style: .continuous)
                    .path(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
            }
            shape = rounded(0)
            border = rounded(0.75)
            today = rounded(1)
            focus = rounded(1.5)
            focusInner = rounded(3.5)
        }

        /// A type's color, and whether text on it is dark.
        mutating func color(_ hex: String) -> (fill: Color, dark: Bool) {
            if let color = colors[hex] { return color }
            let color = (fill: Color(calendarHex: hex), dark: CalendarMath.prefersDarkText(on: hex))
            colors[hex] = color
            return color
        }

        mutating func letter(_ letter: String, ink: Color, size: CGFloat, in context: GraphicsContext) -> GraphicsContext.ResolvedText {
            let key = "\(letter)|\(ink)"
            if let text = letters[key] { return text }
            let text = context.resolve(Text(letter).font(.system(size: size, weight: .medium)).foregroundStyle(ink.opacity(0.6)))
            letters[key] = text
            return text
        }
    }

    private func draw(_ day: Day, _ info: CalendarDayCell.Info, at origin: CGPoint, _ context: GraphicsContext,
                      cache: inout DrawCache) {
        let rect = CGRect(origin: origin, size: cache.size)
        let types = info.types
        let filled = !types.isEmpty
        let weekend = CalendarMath.isWeekend(day)
        let ink: Color = filled ? (cache.color(types[0].color).dark ? .black : .white) : .primary
        let shape = cache.shape.offsetBy(dx: origin.x, dy: origin.y)

        var cell = context
        cell.clip(to: shape)
        cell.fill(shape, with: .color(.primary.opacity(weekend ? 0.07 : 0.025)))
        if filled {
            // Stacked bands with a point between them, "needs cover" ones striped.
            let count = CGFloat(types.count)
            let band = (rect.height - (count - 1)) / count
            for (i, type) in types.enumerated() {
                let r = CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * (band + 1), width: rect.width, height: band)
                cell.fill(Path(r), with: .color(cache.color(type.color).fill))
                if type.role == .needsCover {
                    var stripes = cell
                    stripes.clip(to: Path(r))
                    stripes.stroke(CalendarStripes.path(in: r), with: .color(.white.opacity(0.25)), lineWidth: 1.5)
                }
            }
        }
        if showWeekday {
            let letter = CalendarText.weekdayLetters[(CalendarMath.weekday(day) - (Calendar.current.firstWeekday - 1) + 7) % 7]
            cell.draw(cache.letter(letter, ink: ink, size: letterSize, in: context),
                      at: CGPoint(x: rect.minX + 2, y: rect.minY + 2), anchor: .topLeading)
        }
        if let note = info.note, !note.icon.isEmpty {
            cell.draw(Text(note.icon).font(.system(size: iconSize)), at: CGPoint(x: rect.midX, y: rect.midY))
        }
        drawMarks(info, in: rect, ink: ink, filled: filled, cell)

        if info.gap {
            context.stroke(cache.border.offsetBy(dx: origin.x, dy: origin.y), with: .color(.red),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }
        if info.isToday {
            context.stroke(cache.today.offsetBy(dx: origin.x, dy: origin.y), with: .color(.accentColor), lineWidth: 2)
        }
        if info.selected {
            // A tint and a border, like `CalendarDayCell`.
            context.fill(shape, with: .color(Color.accentColor.opacity(0.3)))
            context.stroke(cache.today.offsetBy(dx: origin.x, dy: origin.y), with: .color(.accentColor), lineWidth: 2)
        } else if info.preview {
            context.fill(shape, with: .color(Color.accentColor.opacity(0.1)))
            context.stroke(cache.border.offsetBy(dx: origin.x, dy: origin.y), with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
        }
        if info.dropTarget {
            // An event dragged over the grid would land here (shows on selected days too).
            context.fill(shape, with: .color(Color.accentColor.opacity(0.15)))
            context.stroke(cache.border.offsetBy(dx: origin.x, dy: origin.y), with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
        }
        if info.focused {
            context.stroke(cache.focus.offsetBy(dx: origin.x, dy: origin.y), with: .color(.accentColor), lineWidth: 3)
            context.stroke(cache.focusInner.offsetBy(dx: origin.x, dy: origin.y), with: .color(.white), lineWidth: 1)
        }
    }

    /// A comment (a triangle top right), events (a dot bottom left), a birthday (a cake bottom right).
    private func drawMarks(_ info: CalendarDayCell.Info, in rect: CGRect, ink: Color, filled: Bool,
                           _ context: GraphicsContext) {
        let dot = markSize
        let inset: CGFloat = 2
        if let note = info.note, !note.comment.isEmpty {
            let side = dot + 4
            var triangle = Path()
            triangle.move(to: CGPoint(x: rect.maxX - side, y: rect.minY))
            triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + side))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(filled ? ink.opacity(0.85) : .accentColor))
        }
        if !info.events.isEmpty {
            let circle = CGRect(x: rect.minX + inset, y: rect.maxY - inset - dot, width: dot, height: dot)
            context.fill(Path(ellipseIn: circle), with: .color(.accentColor))
            context.stroke(Path(ellipseIn: circle.insetBy(dx: 0.75, dy: 0.75)), with: .color(.cardBackground),
                           lineWidth: 1.5)
        }
        if !info.birthdays.isEmpty {
            context.draw(Text(verbatim: "🎂").font(.system(size: cakeSize)),
                         at: CGPoint(x: rect.maxX - (inset - 1), y: rect.maxY - (inset - 2)), anchor: .bottomTrailing)
        }
    }
}

#if os(macOS)
/// The Mac's tooltip and menu for the year grid's days, which are drawn rows: one view follows
/// the pointer to the day under it. It lies over the grid, in its coordinate space `space`; the
/// grid's own gestures (selection, double click) still get the clicks.
struct CalendarYearPointer: View {
    let store: CalendarStore
    let layout: CalendarGridLayout.Year
    let space: String
    @State private var day: Day?

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onContinuousHover(coordinateSpace: .named(space)) { phase in
                switch phase {
                case let .active(point): day = layout.day(at: point, year: store.year)
                case .ended: day = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let day {
                    let frame = layout.frame(of: day)
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .help(tooltip(day))
                        .offset(x: frame.minX, y: frame.minY)
                        .id(day)
                }
            }
            .contextMenu {
                if let day { CalendarCellMenuItems(store: store, day: day) }
            }
    }

    private func tooltip(_ day: Day) -> String {
        CalendarDayCell.tooltip(day: day, types: store.types(on: day), note: store.notes[day],
                                events: store.events[day] ?? [], birthdays: store.birthdays[day] ?? [])
    }
}
#endif

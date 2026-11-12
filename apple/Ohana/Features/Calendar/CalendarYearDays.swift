import SwiftUI

/// The days of the year grid, drawn as one view (the year style of `CalendarDayCell`). As 365
/// cell views the year took long to lay out again at every change of its width (the assistant
/// panel sliding in, the window being resized), and as one canvas per month each canvas waited
/// for a new surface of its size. The grid's gestures find the days by position; VoiceOver (and
/// Switch Control) gets one element per day (`accessibilityChildren`, only built while one of them
/// is on), the Mac the tooltip and menu of the day under the pointer (`CalendarYearPointer`), the
/// iPad a menu per day.
/// The days themselves don't read the selection: what follows it (the selection, the fill
/// handle's preview, a drop and the focus) is drawn over them by `CalendarYearMarks`, so a drag
/// across the days redraws only those marks, not the year.
struct CalendarYearDays: View, Equatable {
    let store: CalendarStore
    let year: Int
    /// Where the days sit: the grid's layout without its labels and header (the days' own
    /// coordinates), plain or with the weekdays aligned.
    let layout: CalendarGridLayout.Year
    /// Plain: the weekday letter in each cell (with the weekdays aligned, the day's number instead).
    let showWeekday: Bool
    let iconSize: CGFloat

    @Environment(\.colorScheme) private var scheme
    /// Any assistive technology (VoiceOver, Switch Control, Voice Control…): only then are the
    /// days' accessibility elements built.
    @Environment(\.accessibilityEnabled) private var assistiveTechnology
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.year == b.year && a.layout == b.layout && a.showWeekday == b.showWeekday
            && a.iconSize == b.iconSize
    }

    /// The days of each month, January first, each month from the 1st, without the selection's marks.
    private var months: [[CalendarDayCell.Info]] {
        let context = store.contentContext()
        return (1...12).map { month in
            (1...CalendarMath.daysInMonth(year: year, month: month)).map {
                store.contentCell(Day(year: year, month: month, day: $0), context)
            }
        }
    }

    var body: some View {
        let months = months
        // Today read with the days (their `isToday` comes from the same redraw).
        CalendarYearCanvas(year: year, months: months, layout: layout,
                           showWeekday: showWeekday, iconSize: iconSize, scheme: scheme, today: .today)
            .equatable()
            .overlay(alignment: .topLeading) {
                CalendarYearMarks(store: store, year: year, layout: layout)
            }
            .frame(width: layout.cellWidth * CGFloat(layout.columns), height: layout.rowHeight * 12, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .modifier(CalendarYearAccessibility(enabled: assistiveTechnology || voiceOver || switchControl, store: store, year: year,
                                                layout: layout, months: months))
            #if os(iOS)
            .overlay(alignment: .topLeading) {
                // Touch has no pointer to follow: a menu per day (a long press).
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(months.indices, id: \.self) { month in
                        HStack(spacing: 0) {
                            CalendarYearLead(layout: layout, year: year, month: month)  // blank: no menu there
                            ForEach(months[month].indices, id: \.self) { index in
                                Color.clear
                                    .frame(width: layout.cellWidth, height: layout.rowHeight)
                                    .contentShape(.rect)
                                    .modifier(CalendarCellMenu(store: store,
                                                               day: Day(year: year, month: month + 1, day: index + 1)))
                            }
                        }
                    }
                }
            }
            #endif
    }
}

/// The blank columns before a month's 1st (aligned weekdays), as space.
private struct CalendarYearLead: View {
    let layout: CalendarGridLayout.Year
    let year: Int
    /// 0 = January.
    let month: Int

    var body: some View {
        Color.clear
            .frame(width: CGFloat(layout.offset(year: year, month: month + 1)) * layout.cellWidth,
                   height: layout.rowHeight)
            .accessibilityHidden(true)
    }
}

/// VoiceOver's (and Switch Control's) elements for the drawn days: one per day, with its label,
/// whether it is selected and its actions. Only while one of them is on (`enabled`): the 365
/// elements and their labels are built again at every change of the selection.
private struct CalendarYearAccessibility: ViewModifier {
    let enabled: Bool
    let store: CalendarStore
    let year: Int
    let layout: CalendarGridLayout.Year
    let months: [[CalendarDayCell.Info]]

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityChildren {
                CalendarYearAccessibilityDays(store: store, year: year, layout: layout, months: months)
            }
        } else {
            content
        }
    }
}

/// The elements of `CalendarYearAccessibility`; reads the selection itself.
private struct CalendarYearAccessibilityDays: View {
    let store: CalendarStore
    let year: Int
    let layout: CalendarGridLayout.Year
    let months: [[CalendarDayCell.Info]]
    @Environment(CalendarActions.self) private var actions: CalendarActions?

    var body: some View {
        let selection = store.selection
        let selectionTypes = selection.isEmpty ? [] : store.selectionTypes
        VStack(alignment: .leading, spacing: 0) {
            ForEach(months.indices, id: \.self) { month in
                HStack(spacing: 0) {
                    CalendarYearLead(layout: layout, year: year, month: month)
                    ForEach(months[month].indices, id: \.self) { index in
                        let day = Day(year: year, month: month + 1, day: index + 1)
                        let info = withSelection(months[month][index], selected: selection.contains(day),
                                                 selectionTypes: selectionTypes)
                        Color.clear
                            .frame(width: layout.cellWidth, height: layout.rowHeight)
                            .accessibilityElement()
                            .accessibilityLabel(CalendarDayCell.accessibilityText(
                                day: day, types: info.types, note: info.note, events: info.events,
                                holidays: info.holidays, birthdays: info.birthdays, gap: info.gap))
                            .accessibilityAddTraits(info.selected ? [.isButton, .isSelected] : .isButton)
                            .modifier(CalendarDayAccessibilityActions(store: store, actions: actions, day: day,
                                                                      info: info))
                    }
                }
            }
        }
    }

    private func withSelection(_ info: CalendarDayCell.Info, selected: Bool, selectionTypes: Set<String>) -> CalendarDayCell.Info {
        guard selected else { return info }
        var info = info
        info.selected = true
        info.onTypes = selectionTypes
        return info
    }
}

/// What follows the selection on the year grid's days, drawn over them: the selection's tint and
/// border, the fill handle's preview, an event dragged over a day and the focused day's outline.
/// It alone reads them, so a change of the selection redraws only these marks.
private struct CalendarYearMarks: View {
    let store: CalendarStore
    let year: Int
    let layout: CalendarGridLayout.Year
    @Environment(\.calendarGridFocused) private var gridFocused

    var body: some View {
        let marks = CalendarYearMarksCanvas.Marks(
            selection: store.selection, preview: store.fill?.targetSet ?? [], drop: store.dropTarget,
            focus: gridFocused || store.dragging ? store.focus : nil)
        CalendarYearMarksCanvas(year: year, layout: layout, marks: marks)
            .equatable()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CalendarYearMarksCanvas: View, Equatable {
    struct Marks: Equatable {
        var selection: Set<Day>
        var preview: Set<Day>
        var drop: Day?
        var focus: Day?
    }

    let year: Int
    let layout: CalendarGridLayout.Year
    let marks: Marks

    /// Where a day's shapes start, nil for a day of another year.
    private func origin(_ day: Day?) -> CGPoint? {
        guard let day, day.year == year else { return nil }
        let frame = layout.frame(of: day)
        return CGPoint(x: frame.minX + 1, y: frame.minY + 1)
    }

    var body: some View {
        let selected = marks.selection.compactMap(origin)
        let preview = marks.preview.subtracting(marks.selection).compactMap(origin)
        let drop = origin(marks.drop), focus = origin(marks.focus)
        let size = CGSize(width: layout.cellWidth - 2, height: layout.rowHeight - 2)
        Canvas { context, _ in
            let shapes = CalendarYearShapes(size: size)
            for o in selected {
                // A tint and a border, like `CalendarDayCell`.
                context.fill(shapes.shape.offsetBy(dx: o.x, dy: o.y), with: .color(Color.accentColor.opacity(0.3)))
                context.stroke(shapes.today.offsetBy(dx: o.x, dy: o.y), with: .color(.accentColor), lineWidth: 2)
            }
            for o in preview {
                context.fill(shapes.shape.offsetBy(dx: o.x, dy: o.y), with: .color(Color.accentColor.opacity(0.1)))
                context.stroke(shapes.border.offsetBy(dx: o.x, dy: o.y), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
            }
            if let o = drop {
                // An event dragged over the grid would land here (shows on selected days too).
                context.fill(shapes.shape.offsetBy(dx: o.x, dy: o.y), with: .color(Color.accentColor.opacity(0.15)))
                context.stroke(shapes.border.offsetBy(dx: o.x, dy: o.y), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
            }
            if let o = focus {
                context.stroke(shapes.focus.offsetBy(dx: o.x, dy: o.y), with: .color(.accentColor), lineWidth: 3)
                context.stroke(shapes.focusInner.offsetBy(dx: o.x, dy: o.y), with: .color(.white), lineWidth: 1)
            }
        }
    }
}

/// The rounded shapes of a year grid's day (all days have the same size), at its origin.
private struct CalendarYearShapes {
    let shape: Path
    let border: Path
    let today: Path
    let focus: Path
    let focusInner: Path

    init(size: CGSize) {
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
}

/// The drawing of `CalendarYearDays`: one canvas, drawn again when the days, the size, the color
/// scheme (dark mode draws grays darker) or today (past days are faded) change.
private struct CalendarYearCanvas: View, Equatable {
    let year: Int
    let months: [[CalendarDayCell.Info]]
    let layout: CalendarGridLayout.Year
    let showWeekday: Bool
    let iconSize: CGFloat
    let scheme: ColorScheme
    let today: Day

    private var cellWidth: CGFloat { layout.cellWidth }
    private var rowHeight: CGFloat { layout.rowHeight }

    @ScaledMetric(relativeTo: .caption2) private var letterSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var markSize: CGFloat = 5
    @ScaledMetric(relativeTo: .caption2) private var eventSize: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var countSize: CGFloat = 7
    @ScaledMetric(relativeTo: .caption2) private var cakeSize: CGFloat = 8

    static func == (a: Self, b: Self) -> Bool {
        a.year == b.year && a.months == b.months && a.layout == b.layout
            && a.showWeekday == b.showWeekday && a.iconSize == b.iconSize && a.scheme == b.scheme
            && a.today == b.today
    }

    private func day(_ month: Int, _ index: Int) -> Day { Day(year: year, month: month + 1, day: index + 1) }

    var body: some View {
        Canvas { context, _ in
            var cache = DrawCache(size: CGSize(width: cellWidth - 2, height: rowHeight - 2), scheme: scheme)
            for (month, infos) in months.enumerated() {
                // The month's first column (aligned weekdays: its 1st's weekday; blanks stay empty).
                let offset = layout.offset(year: year, month: month + 1)
                for (index, info) in infos.enumerated() {
                    let origin = CGPoint(x: CGFloat(offset + index) * cellWidth + 1, y: CGFloat(month) * rowHeight + 1)
                    draw(day(month, index), info, at: origin, context, cache: &cache)
                }
            }
        }
    }

    // MARK: Drawing (as `CalendarDayCell` lays out `.year`)

    /// What every day of a drawing shares, made once: the cell's rounded shapes (all days have
    /// the same size), the types' colors, the weekday letters and the events' counts.
    private struct DrawCache {
        let size: CGSize
        let scheme: ColorScheme
        let shape: Path
        let border: Path
        let today: Path
        private var colors: [String: CalendarTypeColor] = [:]
        private var letters: [String: GraphicsContext.ResolvedText] = [:]
        private var counts: [Int: (text: GraphicsContext.ResolvedText, size: CGSize)] = [:]

        init(size: CGSize, scheme: ColorScheme) {
            self.size = size
            self.scheme = scheme
            let shapes = CalendarYearShapes(size: size)
            shape = shapes.shape
            border = shapes.border
            today = shapes.today
        }

        /// A type's color as drawn in the scheme, and its ink.
        mutating func color(_ hex: String) -> CalendarTypeColor {
            if let color = colors[hex] { return color }
            let color = CalendarTypeColor(hex, scheme: scheme)
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

        /// The events' count for their mark, white, and its size.
        mutating func count(_ n: Int, size: CGFloat, in context: GraphicsContext) -> (text: GraphicsContext.ResolvedText, size: CGSize) {
            let key = min(n, 10)  // one size per drawing
            if let count = counts[key] { return count }
            let text = context.resolve(Text(verbatim: CalendarDayLook.eventCount(n))
                .font(.system(size: size, weight: .bold).monospacedDigit())
                .foregroundStyle(.white))
            let count = (text: text, size: text.measure(in: CGSize(width: 100, height: 100)))
            counts[key] = count
            return count
        }
    }

    private func draw(_ day: Day, _ info: CalendarDayCell.Info, at origin: CGPoint, _ context: GraphicsContext,
                      cache: inout DrawCache) {
        let rect = CGRect(origin: origin, size: cache.size)
        let types = info.types
        let filled = !types.isEmpty
        let weekend = CalendarMath.isWeekend(day)
        let ink: Color = filled ? cache.color(types[0].color).ink : .primary
        let shape = cache.shape.offsetBy(dx: origin.x, dy: origin.y)

        // The day's content; before today and outside the legend's highlight faded (drawn into the
        // same context at a lower opacity: no layer per day). The marks of the selection, focus,
        // today and drops stay as they are.
        var cell = context
        cell.opacity = CalendarDayLook.contentOpacity(past: day < today, dimmed: info.dimmed)
        let faded = cell
        cell.clip(to: shape)
        cell.fill(shape, with: .color(CalendarDayLook.base(weekend: weekend, scheme: cache.scheme)))
        if filled {
            // Stacked bands with a point between them, "needs cover" ones striped in their ink.
            let count = CGFloat(types.count)
            let band = (rect.height - (count - 1)) / count
            for (i, type) in types.enumerated() {
                let r = CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * (band + 1), width: rect.width, height: band)
                let color = cache.color(type.color)
                cell.fill(Path(r), with: .color(color.fill))
                if type.role == .needsCover {
                    var stripes = cell
                    stripes.clip(to: Path(r))
                    stripes.stroke(CalendarStripes.path(in: r), with: .color(color.ink.opacity(CalendarDayLook.stripeOpacity)),
                                   lineWidth: CalendarDayLook.stripeWidth)
                }
            }
            if weekend { cell.fill(Path(rect), with: .color(CalendarDayLook.weekendShade)) }
        }
        if layout.aligned || showWeekday {
            // Aligned, the header has the weekdays: the cell says which day of the month it is.
            let letter = layout.aligned ? String(day.day)
                : CalendarText.weekdayLetters[(CalendarMath.weekday(day) - (Calendar.current.firstWeekday - 1) + 7) % 7]
            cell.draw(cache.letter(letter, ink: ink, size: letterSize, in: context),
                      at: CGPoint(x: rect.minX + 2, y: rect.minY + 2), anchor: .topLeading)
        }
        if let note = info.note, let icon = CalendarSymbol.drawable(note.icon) {
            // The theme color; on a type's color the cell's ink, which reads on it.
            cell.draw(Text(Image(systemName: icon)).font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(filled ? ink : Color.accentColor),
                      at: CGPoint(x: rect.midX, y: rect.midY))
        }
        drawMarks(info, in: rect, ink: ink, filled: filled, cell, cache: &cache)

        if info.gap {
            faded.stroke(cache.border.offsetBy(dx: origin.x, dy: origin.y), with: .color(.red),
                         style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
        }
        if info.isToday {
            context.stroke(cache.today.offsetBy(dx: origin.x, dy: origin.y), with: .color(.accentColor), lineWidth: 2)
        }
        // The selection, the fill's preview, drops and the focus: `CalendarYearMarks`, on top.
    }

    /// A comment (a triangle top right), events (a dot bottom left; from two on their count in a
    /// capsule where the cell is wide enough), a birthday (a cake bottom right).
    private func drawMarks(_ info: CalendarDayCell.Info, in rect: CGRect, ink: Color, filled: Bool,
                           _ context: GraphicsContext, cache: inout DrawCache) {
        let inset: CGFloat = 2
        // The events' mark grows a little with the zoom (up to 1.5 ×), so it stays easy to see.
        let zoom = min(1.5, max(1, min(cellWidth, rowHeight) / 30))
        let eventSize = eventSize * zoom
        if let note = info.note, !note.comment.isEmpty {
            let side = markSize + 4
            var triangle = Path()
            triangle.move(to: CGPoint(x: rect.maxX - side, y: rect.minY))
            triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + side))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(filled ? ink.opacity(0.85) : .accentColor))
        }
        if !info.events.isEmpty {
            // The accent color with a hairline of the card's color around it, apart from the bands.
            let n = info.events.count
            if n >= 2, cellWidth >= CalendarDayLook.countMinWidth {
                let count = cache.count(n, size: countSize * zoom, in: context)
                let height = max(eventSize + 1, count.size.height)
                let mark = CGRect(x: rect.minX + inset, y: rect.maxY - inset - height,
                                  width: max(height, count.size.width + 4), height: height)
                let radius = height / 2
                context.fill(Path(roundedRect: mark.insetBy(dx: -1, dy: -1), cornerRadius: radius + 1),
                             with: .color(.cardBackground))
                context.fill(Path(roundedRect: mark, cornerRadius: radius), with: .color(.accentColor))
                context.draw(count.text, at: CGPoint(x: mark.midX, y: mark.midY))
            } else {
                let dot = CGRect(x: rect.minX + inset, y: rect.maxY - inset - eventSize, width: eventSize, height: eventSize)
                context.fill(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(.cardBackground))
                context.fill(Path(ellipseIn: dot), with: .color(.accentColor))
            }
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
        CalendarDayCell.tooltip(day: day, types: store.cellTypes(on: day), note: store.notes[day],
                                events: store.events[day] ?? [], holidays: store.holidays[day] ?? [],
                                birthdays: store.birthdays[day] ?? [])
    }
}
#endif

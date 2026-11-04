import CoreGraphics

/// Where the days sit in the two grids, and which day a point hits (for taps and drags).
enum CalendarGridLayout {
    /// The year grid: 12 rows (months) after a label column and a header. Plain, 31 columns,
    /// the day of the month; with the weekdays aligned (`firstWeekday`, 1 = Sunday), 37 columns
    /// of weekdays (5 weeks + 2): each month starts in the column of its 1st's weekday, so the
    /// weekends line up as stripes. The columns before a month's 1st and after its last day are blank.
    struct Year: Equatable {
        var width: CGFloat
        var labelWidth: CGFloat = 40
        var headerHeight: CGFloat = 22
        var rowHeight: CGFloat = 30
        /// The first day of the week the columns follow; nil: every month starts in column 0.
        var firstWeekday: Int?

        /// 31 days; aligned, up to 6 blanks before a 1st and 31 days.
        static func columns(aligned: Bool) -> Int { aligned ? 37 : 31 }

        var aligned: Bool { firstWeekday != nil }
        var columns: Int { Self.columns(aligned: aligned) }
        var cellWidth: CGFloat { max(1, (width - labelWidth) / CGFloat(columns)) }
        var height: CGFloat { headerHeight + rowHeight * 12 }

        /// The column of a month's 1st.
        func offset(year: Int, month: Int) -> Int {
            firstWeekday.map { CalendarMath.leadingBlanks(year: year, month: month, firstWeekday: $0) } ?? 0
        }

        func column(of day: Day) -> Int { offset(year: day.year, month: day.month) + day.day - 1 }

        /// The day under the point; `clamp` (while dragging) gives the nearest day of the grid
        /// for points outside of it, and of the row's month on its blank columns.
        func day(at p: CGPoint, year: Int, clamp: Bool = false) -> Day? {
            var col = Int(((p.x - labelWidth) / cellWidth).rounded(.down))
            var row = Int(((p.y - headerHeight) / rowHeight).rounded(.down))
            if clamp {
                col = min(max(col, 0), columns - 1)
                row = min(max(row, 0), 11)
            } else if !(0..<columns).contains(col) || !(0..<12).contains(row) {
                return nil
            }
            let month = row + 1
            let last = CalendarMath.daysInMonth(year: year, month: month)
            let n = col - offset(year: year, month: month) + 1
            if n < 1 { return clamp ? Day(year: year, month: month, day: 1) : nil }
            if n > last { return clamp ? Day(year: year, month: month, day: last) : nil }
            return Day(year: year, month: month, day: n)
        }

        func frame(of day: Day) -> CGRect {
            CGRect(x: labelWidth + CGFloat(column(of: day)) * cellWidth,
                   y: headerHeight + CGFloat(day.month - 1) * rowHeight,
                   width: cellWidth, height: rowHeight)
        }
    }

    /// A month: weeks of 7 columns starting on `firstWeekday` (1 = Sunday), `spacing` between
    /// the cells (the web's month view has gaps; a point in a gap counts as the cell before it).
    struct Month: Equatable {
        var year: Int
        var month: Int
        var firstWeekday: Int
        var width: CGFloat
        var rowHeight: CGFloat
        var spacing: CGFloat = 0

        var blanks: Int { CalendarMath.leadingBlanks(year: year, month: month, firstWeekday: firstWeekday) }
        var dayCount: Int { CalendarMath.daysInMonth(year: year, month: month) }
        var rows: Int { (blanks + dayCount + 6) / 7 }
        var cellWidth: CGFloat { max(1, (width - spacing * 6) / 7) }
        var height: CGFloat { CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing }

        /// The web's month view: cells of 1 : 0.8, taller only when their text needs more
        /// (`minimum`, which grows with Dynamic Type).
        static func rowHeight(width: CGFloat, spacing: CGFloat, minimum: CGFloat) -> CGFloat {
            max((max(1, (width - spacing * 6) / 7) * 0.8).rounded(), minimum)
        }

        /// The weeks of a month with the day numbers in their columns (nil: a blank).
        var weeks: [[Int?]] {
            (0..<rows).map { row in
                (0..<7).map { col in
                    let n = row * 7 + col - blanks + 1
                    return (1...dayCount).contains(n) ? n : nil
                }
            }
        }

        func day(at p: CGPoint, clamp: Bool = false) -> Day? {
            var col = Int((p.x / (cellWidth + spacing)).rounded(.down))
            var row = Int((p.y / (rowHeight + spacing)).rounded(.down))
            if clamp {
                col = min(max(col, 0), 6)
                row = min(max(row, 0), rows - 1)
            } else if !(0..<7).contains(col) || !(0..<rows).contains(row) {
                return nil
            }
            let n = row * 7 + col - blanks + 1
            if n < 1 { return clamp ? Day(year: year, month: month, day: 1) : nil }
            if n > dayCount { return clamp ? Day(year: year, month: month, day: dayCount) : nil }
            return Day(year: year, month: month, day: n)
        }

        func frame(of day: Day) -> CGRect {
            let i = blanks + day.day - 1
            return CGRect(x: CGFloat(i % 7) * (cellWidth + spacing), y: CGFloat(i / 7) * (rowHeight + spacing),
                          width: cellWidth, height: rowHeight)
        }
    }

    /// The list of months: the day under a point, given where each month's grid sits (`frames`,
    /// by month, in the list's coordinate space; only the ones on screen). The rows' height
    /// follows from a frame's height. With `clamp` (while dragging) a point between or beyond
    /// the grids gives the closest month's nearest day.
    static func day(at p: CGPoint, inMonths frames: [Int: CGRect], year: Int, firstWeekday: Int,
                    spacing: CGFloat = 0, clamp: Bool = false) -> Day? {
        let months = frames.sorted { $0.key < $1.key }
        let inside = months.first { $0.value.minY <= p.y && p.y < $0.value.maxY }
        let picked = inside ?? (clamp ? months.min { distance(p.y, $0.value) < distance(p.y, $1.value) } : nil)
        guard let (month, frame) = picked else { return nil }
        var layout = Month(year: year, month: month, firstWeekday: firstWeekday, width: frame.width, rowHeight: 1,
                           spacing: spacing)
        layout.rowHeight = max(1, (frame.height - CGFloat(layout.rows - 1) * spacing) / CGFloat(layout.rows))
        return layout.day(at: CGPoint(x: p.x - frame.minX, y: p.y - frame.minY), clamp: clamp)
    }

    private static func distance(_ y: CGFloat, _ frame: CGRect) -> CGFloat {
        y < frame.minY ? frame.minY - y : max(0, y - frame.maxY)
    }
}

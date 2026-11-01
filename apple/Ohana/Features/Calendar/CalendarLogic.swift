import Foundation

// Pure calendar logic, ported from server/lib/calendar/core.ts. Days are `Day`s; entries are
// [Day: type ids], notes [Day: note]. Weekdays and day arithmetic are proleptic Gregorian
// (like the server's UTC dates), independent of the device's calendar settings.

typealias CalendarEntries = [Day: [String]]
typealias CalendarNotes = [Day: CalendarNote]
/// Copied days: the type ids of each day in order.
typealias CalendarPattern = [[String]]

/// Per type: all days of the year with it, and the workdays (Mon–Fri that are not a day off).
struct CalendarTypeStats: Equatable {
    var days = 0
    var workdays = 0
}

enum CalendarMath {
    // MARK: Days

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    static func ordinal(_ d: Day) -> Int {
        let y = d.month <= 2 ? d.year - 1 : d.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (d.month + 9) % 12
        let doy = (153 * mp + 2) / 5 + d.day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func day(ordinal z0: Int) -> Day {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return Day(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    static func add(_ d: Day, _ n: Int) -> Day { day(ordinal: ordinal(d) + n) }

    /// 0 = Sunday … 6 = Saturday.
    static func weekday(_ d: Day) -> Int { ((ordinal(d) % 7) + 7 + 4) % 7 }

    static func isWeekend(_ d: Day) -> Bool {
        let w = weekday(d)
        return w == 0 || w == 6
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        (1...12).contains(month) && day >= 1 && day <= daysInMonth(year: year, month: month)
    }

    /// Inclusive range, order-independent.
    static func range(_ a: Day, _ b: Day) -> [Day] {
        let (x, y) = a <= b ? (ordinal(a), ordinal(b)) : (ordinal(b), ordinal(a))
        return (x...y).map { day(ordinal: $0) }
    }

    static func monthDays(year: Int, month: Int) -> [Day] {
        (1...daysInMonth(year: year, month: month)).map { Day(year: year, month: month, day: $0) }
    }

    /// Blank cells before the 1st in a week that starts on `firstWeekday` (1 = Sunday, like
    /// `Calendar.firstWeekday`).
    static func leadingBlanks(year: Int, month: Int, firstWeekday: Int) -> Int {
        let w = weekday(Day(year: year, month: month, day: 1)) // 0 = Sunday
        return (w - (firstWeekday - 1) + 7) % 7
    }

    /// Groups sorted days into runs of consecutive days.
    static func runs(_ sorted: [Day]) -> [[Day]] {
        var out: [[Day]] = []
        for d in sorted {
            if let last = out.last?.last, add(last, 1) == d { out[out.count - 1].append(d) } else { out.append([d]) }
        }
        return out
    }

    // MARK: Coverage and counts

    static func roles(_ types: [CalendarEntryType]) -> [String: CalendarRole] {
        Dictionary(types.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
    }

    /// A weekday that has a "needs cover" entry but no covering entry.
    static func isGap(_ day: Day, _ ids: [String]?, roles: [String: CalendarRole]) -> Bool {
        guard let ids, !ids.isEmpty, !isWeekend(day) else { return false }
        var needs = false
        for id in ids {
            switch roles[id] {
            case .covers, .dayOff: return false
            case .needsCover: needs = true
            default: break
            }
        }
        return needs
    }

    static func gapDays(_ entries: CalendarEntries, types: [CalendarEntryType], year: Int? = nil) -> [Day] {
        let roles = roles(types)
        return entries
            .filter { (year == nil || $0.key.year == year) && isGap($0.key, $0.value, roles: roles) }
            .map(\.key)
            .sorted()
    }

    static func stats(_ entries: CalendarEntries, types: [CalendarEntryType], year: Int? = nil) -> [String: CalendarTypeStats] {
        let roles = roles(types)
        var out = Dictionary(types.map { ($0.id, CalendarTypeStats()) }, uniquingKeysWith: { a, _ in a })
        for (date, ids) in entries {
            if let year, date.year != year { continue }
            let weekend = isWeekend(date)
            let holiday = ids.contains { roles[$0] == .dayOff }
            for id in ids {
                guard var s = out[id] else { continue }
                s.days += 1
                // A vacation day on a public holiday doesn't use up a vacation day.
                if !weekend && (!holiday || roles[id] == .dayOff) { s.workdays += 1 }
                out[id] = s
            }
        }
        return out
    }

    // MARK: Changing entries

    /// Clicking a type on a selection: remove it if every day has it, else add it everywhere.
    static func toggleType(_ entries: CalendarEntries, days: [Day], typeID: String) -> CalendarEntries {
        let allHave = !days.isEmpty && days.allSatisfy { (entries[$0] ?? []).contains(typeID) }
        var next: CalendarEntries = [:]
        for d in days {
            let cur = entries[d] ?? []
            if allHave {
                next[d] = cur.filter { $0 != typeID }
            } else {
                next[d] = cur.contains(typeID) ? cur : cur + [typeID]
            }
        }
        return next
    }

    static func clearDays(_ days: [Day]) -> CalendarEntries {
        Dictionary(days.map { ($0, []) }, uniquingKeysWith: { a, _ in a })
    }

    /// Only keeps days whose value actually changes.
    static func changedOnly(_ entries: CalendarEntries, _ next: CalendarEntries) -> CalendarEntries {
        next.filter { day, ids in
            let cur = entries[day] ?? []
            return !(cur.count == ids.count && cur.allSatisfy(ids.contains))
        }
    }

    /// Day changes as add/remove ops per type (they merge with other people's edits).
    static func ops(_ entries: CalendarEntries, _ next: CalendarEntries) -> [CalendarEntryOp] {
        var add: [String: [Day]] = [:], remove: [String: [Day]] = [:]
        var addOrder: [String] = [], removeOrder: [String] = []
        for (d, ids) in next.sorted(by: { $0.key < $1.key }) {
            let cur = entries[d] ?? []
            for id in ids where !cur.contains(id) {
                if add[id] == nil { addOrder.append(id) }
                add[id, default: []].append(d)
            }
            for id in cur where !ids.contains(id) {
                if remove[id] == nil { removeOrder.append(id) }
                remove[id, default: []].append(d)
            }
        }
        return removeOrder.map { CalendarEntryOp(action: .remove, type: $0, dates: remove[$0]!.sorted()) }
            + addOrder.map { CalendarEntryOp(action: .add, type: $0, dates: add[$0]!.sorted()) }
    }

    static func apply(_ next: CalendarEntries, to entries: inout CalendarEntries) {
        for (d, ids) in next {
            entries[d] = ids.isEmpty ? nil : ids
        }
    }

    // MARK: Notes

    static func noteOrNil(_ note: CalendarNote?) -> CalendarNote? {
        guard let note, !(note.icon.isEmpty && note.comment.isEmpty) else { return nil }
        return note
    }

    static func sameNote(_ a: CalendarNote?, _ b: CalendarNote?) -> Bool {
        noteOrNil(a) == noteOrNil(b)
    }

    /// Only keeps days whose note actually changes (nil: remove the day's note).
    static func changedNotes(_ notes: CalendarNotes, _ next: [Day: CalendarNote?]) -> [Day: CalendarNote?] {
        var out: [Day: CalendarNote?] = [:]
        for (d, note) in next where !sameNote(notes[d], note) {
            out[d] = .some(noteOrNil(note))
        }
        return out
    }

    /// Note changes as ops: one "clear" for removals, one "set" per distinct note.
    static func noteOps(_ next: [Day: CalendarNote?]) -> [CalendarNoteOp] {
        var clear: [Day] = []
        var sets: [CalendarNote: [Day]] = [:]
        var order: [CalendarNote] = []
        for (d, note) in next.sorted(by: { $0.key < $1.key }) {
            guard let n = noteOrNil(note) else { clear.append(d); continue }
            if sets[n] == nil { order.append(n) }
            sets[n, default: []].append(d)
        }
        var ops: [CalendarNoteOp] = []
        if !clear.isEmpty { ops.append(CalendarNoteOp(action: .clear, dates: clear)) }
        for n in order {
            ops.append(CalendarNoteOp(action: .set, dates: sets[n]!, icon: n.icon, comment: n.comment))
        }
        return ops
    }

    static func apply(_ next: [Day: CalendarNote?], to notes: inout CalendarNotes) {
        for (d, note) in next {
            notes[d] = noteOrNil(note)
        }
    }

    // MARK: Ops not sent yet

    /// Entry ops as the server applies them (vacation.ts `applyEntryOps`), on the days of `year`.
    static func apply(_ ops: [CalendarEntryOp], to entries: inout CalendarEntries, year: Int) {
        for op in ops {
            for d in op.dates where d.year == year {
                var ids = entries[d] ?? []
                switch op.action {
                case .add: if !ids.contains(op.type) { ids.append(op.type) }
                case .remove: ids.removeAll { $0 == op.type }
                }
                entries[d] = ids.isEmpty ? nil : ids
            }
        }
    }

    /// Note ops as the server applies them (`applyNoteOps`), on the days of `year`.
    static func apply(_ ops: [CalendarNoteOp], to notes: inout CalendarNotes, year: Int) {
        for op in ops {
            let note = op.action == .set ? noteOrNil(CalendarNote(icon: op.icon ?? "", comment: op.comment ?? "")) : nil
            for d in op.dates where d.year == year { notes[d] = note }
        }
    }

    // MARK: Copy and paste

    static func pattern(_ entries: CalendarEntries, days: [Day]) -> CalendarPattern {
        days.map { entries[$0] ?? [] }
    }

    /// Repeats `pattern` over `days` (cyclically).
    static func fill(_ days: [Day], with pattern: CalendarPattern) -> CalendarEntries {
        guard !pattern.isEmpty else { return [:] }
        var next: CalendarEntries = [:]
        for (i, d) in days.enumerated() { next[d] = pattern[i % pattern.count] }
        return next
    }

    /// Days a paste onto `selection` writes: one selected day receives the whole pattern (up to
    /// `last`), a larger selection is filled.
    static func pasteTargets(_ selection: [Day], patternLength: Int, last: Day, skipWeekends: Bool) -> [Day] {
        guard selection.count == 1 else { return selection }
        var out: [Day] = []
        var d = selection[0]
        while out.count < patternLength && d <= last {
            if !(skipWeekends && isWeekend(d)) { out.append(d) }
            d = add(d, 1)
        }
        return out
    }

    // MARK: Fill handle

    /// Whether sorted days follow each other without a gap (the fill handle needs that).
    static func isContiguous(_ sorted: [Day]) -> Bool {
        guard let first = sorted.first, let last = sorted.last else { return false }
        return ordinal(last) - ordinal(first) + 1 == sorted.count
    }

    /// The fill handle dragged to `hover` (the web grid's `fillTargets`): the days after the
    /// source up to it, or before the source back to it (`backwards`); none inside the source.
    static func fillTargets(source: [Day], hover: Day) -> (days: [Day], backwards: Bool) {
        guard let start = source.first, let end = source.last else { return ([], false) }
        if hover > end { return (range(add(end, 1), hover), false) }
        if hover < start { return (range(hover, add(start, -1)), true) }
        return ([], false)
    }

    /// The pattern to repeat over `count` days: backwards it is turned so that it ends right
    /// before the source.
    static func alignedPattern(_ pattern: CalendarPattern, count: Int, backwards: Bool) -> CalendarPattern {
        let n = pattern.count
        guard backwards, n > 1 else { return pattern }
        let shift = (n - count % n) % n
        return Array(pattern[shift...] + pattern[..<shift])
    }

    /// What dragging the fill handle writes: the source's pattern repeated over the targets.
    static func fillChanges(_ entries: CalendarEntries, source: [Day], targets: [Day], backwards: Bool) -> CalendarEntries {
        let pattern = alignedPattern(self.pattern(entries, days: source), count: targets.count, backwards: backwards)
        return fill(targets, with: pattern)
    }

    /// Clipboard text: one line per day, "YYYY-MM-DD<TAB>Type A, Type B".
    static func clipboardText(days: [Day], pattern: CalendarPattern, types: [CalendarEntryType]) -> String {
        let names = Dictionary(types.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return zip(days, pattern)
            .map { "\($0.0.description)\t\($0.1.map { names[$0] ?? $0 }.joined(separator: ", "))" }
            .joined(separator: "\n")
    }

    /// Our own clipboard text, or a plain column of type names (e.g. from a spreadsheet).
    static func parseClipboard(_ text: String, types: [CalendarEntryType]) -> (pattern: CalendarPattern, unknown: [String]) {
        var byName: [String: String] = [:]
        for t in types where byName[t.name.lowercased()] == nil { byName[t.name.lowercased()] = t.id }
        let ids = Set(types.map(\.id))
        var unknown: [String] = []
        var lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let pattern = lines.map { line -> [String] in
            var cells = line.components(separatedBy: "\t")
            if cells.count > 1, Day(cells[0].trimmingCharacters(in: .whitespaces)) != nil,
               cells[0].trimmingCharacters(in: .whitespaces).count == 10 {
                cells.removeFirst()
            }
            return cells.joined(separator: ",")
                .split(whereSeparator: { ",;+".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .compactMap { name in
                    if let id = byName[name.lowercased()] ?? (ids.contains(name) ? name : nil) { return id }
                    if !unknown.contains(name) { unknown.append(name) }
                    return nil
                }
        }
        return (pattern, unknown)
    }

    // MARK: Colors

    static let palette = ["#3b82f6", "#ec4899", "#8b5cf6", "#14b8a6", "#f97316",
                          "#84cc16", "#06b6d4", "#a855f7", "#eab308", "#64748b"]

    static func nextColor(_ types: [CalendarEntryType]) -> String {
        let used = Set(types.map { $0.color.lowercased() })
        return palette.first { !used.contains($0) } ?? palette[types.count % palette.count]
    }

    /// "#rrggbb" → its components 0…1, nil for anything else.
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let s = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard s.count == 6, let n = Int(s, radix: 16) else { return nil }
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
    }

    static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }

    /// Whether dark text reads better than white on the color (core.ts `contrastText`).
    static func prefersDarkText(on hex: String) -> Bool {
        guard let (r, g, b) = rgb(hex) else { return true }
        return (r * 255 * 299 + g * 255 * 587 + b * 255 * 114) / 1000 > 150
    }
}

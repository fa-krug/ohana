import Foundation
import Observation

/// One open family calendar: the types, entries, notes, events and birthdays of one year, the
/// queue that saves local edits, undo / redo and the day selection (the web app's
/// components/calendar/planner-store.ts).
@Observable
final class CalendarStore {
    enum Phase: Equatable {
        case loading, loaded, notFound
        case failed(String)
    }

    enum Sync: Equatable {
        case idle, saving, retrying
    }

    /// An undoable change: the days' values before and after.
    enum Step {
        case entries(before: CalendarEntries, after: CalendarEntries)
        case notes(before: [Day: CalendarNote?], after: [Day: CalendarNote?])
    }

    private enum Batch {
        case entries([CalendarEntryOp])
        case notes([CalendarNoteOp])

        var days: Int {
            switch self {
            case let .entries(ops): ops.reduce(0) { $0 + $1.dates.count }
            case let .notes(ops): ops.reduce(0) { $0 + $1.dates.count }
            }
        }
    }

    /// The year the calendar showed last, so Settings → Calendar opens on it.
    static var lastYear: Int?

    static let maxDaysPerRequest = 4000
    private static let skipWeekendsKey = "ohana.calendar.skipWeekends"

    let api: FamilyAPI
    private(set) var year: Int
    private(set) var phase: Phase = .loading
    private(set) var family: CalendarFamilyInfo?
    /// The types of `year` (every year has its own), in order.
    private(set) var types: [CalendarEntryType] = []
    /// The years that have types; nil until loaded.
    private(set) var typeYears: [Int]?
    private(set) var entries: CalendarEntries = [:]
    private(set) var notes: CalendarNotes = [:]
    private(set) var events: [Day: [CalendarEvent]] = [:]
    private(set) var birthdays: [Day: [CalendarBirthday]] = [:]
    private(set) var readOnly: Bool

    private(set) var selection: Set<Day> = []
    private(set) var anchor: Day?
    private(set) var focus: Day?
    /// Touch: the next tap selects the range from the anchor to it.
    var rangeMode = false
    /// Touch: taps add days to the selection or remove them.
    var multiSelect = false

    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    private(set) var sync: Sync = .idle
    /// A short message (copied, nothing to undo…), shown for a moment.
    private(set) var toast: String?

    var skipWeekends: Bool {
        didSet { UserDefaults.standard.set(skipWeekends, forKey: Self.skipWeekendsKey) }
    }

    /// Tells the other screens what changed (FamilyContext.didChange).
    var notify: ((DataArea) -> Void)?

    /// The window's undo manager (Edit → Undo, ⌘Z, shake): every step is registered with it too.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet {
            if oldValue !== undoManager { oldValue?.removeAllActions(withTarget: self) }
        }
    }

    /// The fill handle being dragged (or the repeat sheet open): the selection it repeats and
    /// the days it would fill.
    private(set) var fill: CalendarFill?

    private var clipboard: (pattern: CalendarPattern, text: String, year: Int)?
    private var version = 0
    private var queue: [Batch] = []
    private var flushing = false
    private var retryDelay: Double = 2
    private var reloadAfterSave = false
    private var toastTask: Task<Void, Never>?

    init(api: FamilyAPI, year: Int? = nil, readOnly: Bool) {
        self.api = api
        self.year = year ?? Self.lastYear ?? Day.today.year
        self.readOnly = readOnly
        skipWeekends = UserDefaults.standard.bool(forKey: Self.skipWeekendsKey)
    }

    var isLoaded: Bool { phase == .loaded }
    var pending: Bool { !queue.isEmpty || flushing }
    var canUndo: Bool { !readOnly && !undoStack.isEmpty }
    var canRedo: Bool { !readOnly && !redoStack.isEmpty }

    func type(_ id: String) -> CalendarEntryType? { types.first { $0.id == id } }

    /// A day's entry types, in the order of the types.
    func types(on day: Day) -> [CalendarEntryType] {
        let ids = entries[day] ?? []
        return types.filter { ids.contains($0.id) }
    }

    func isGap(_ day: Day) -> Bool {
        CalendarMath.isGap(day, entries[day], roles: CalendarMath.roles(types))
    }

    var stats: [String: CalendarTypeStats] { CalendarMath.stats(entries, types: types, year: year) }
    var gapDays: [Day] { CalendarMath.gapDays(entries, types: types, year: year) }
    var needsCoverTypes: [CalendarEntryType] { types.filter { $0.role == .needsCover } }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Loading and saving

    func apply(_ state: CalendarState) {
        family = state.family
        readOnly = readOnly || state.family.readOnly
        types = state.types
            .filter { $0.year == nil || $0.year == year }
            .enumerated()
            .sorted { ($0.element.position ?? $0.offset, $0.offset) < ($1.element.position ?? $1.offset, $1.offset) }
            .map(\.element)
        typeYears = state.typeYears
        entries = Self.byDay(state.entries)
        notes = Self.byDay(state.notes ?? [:])
        events = Self.byDay(state.events ?? [:])
        birthdays = Self.byDay(state.birthdays ?? [:])
        phase = .loaded
    }

    static func byDay<V>(_ map: [String: V]) -> [Day: V] {
        var out: [Day: V] = [:]
        for (key, value) in map { if let day = Day(key) { out[day] = value } }
        return out
    }

    /// Fetches the year. A quiet load (polling, another screen's change) shows no errors.
    func load(quiet: Bool = false) async {
        let (version, year) = (self.version, self.year)
        do {
            let state: CalendarState = try await api.get("", query: ["year": String(year)])
            // Ignore it if something changed meanwhile or the year switched.
            guard version == self.version, year == self.year, !pending else {
                reloadAfterSave = true
                return
            }
            reloadAfterSave = false
            apply(state)
        } catch is CancellationError {
        } catch let error as APIError where error.status == 404 {
            phase = .notFound
        } catch {
            if phase != .loaded {
                phase = .failed(error.localizedDescription)
            } else if !quiet {
                ErrorBanner.shared.show(error)
            }
        }
    }

    /// Reloads every 15 seconds while nothing is being saved (other people's changes).
    func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }
            if isLoaded && !pending { await load(quiet: true) }
        }
    }

    private func enqueue(_ batch: Batch) {
        if batch.days == 0 { return }
        queue.append(batch)
        Task { await flush() }
    }

    private func flush() async {
        guard !flushing else { return }
        flushing = true
        var saved = false, resync = false
        while let first = queue.first {
            sync = .saving
            // Send consecutive batches of one kind as one request: ops apply in order.
            var n = 0, days = 0
            var entryOps: [CalendarEntryOp] = [], noteOps: [CalendarNoteOp] = []
            for batch in queue {
                guard Self.sameKind(first, batch) else { break }
                if n > 0 && days + batch.days > Self.maxDaysPerRequest { break }
                switch batch {
                case let .entries(ops): entryOps += ops
                case let .notes(ops): noteOps += ops
                }
                n += 1
                days += batch.days
            }
            do {
                if case .entries = first {
                    try await api.perform(.post, "/entries", body: CalendarOpsBody(ops: entryOps))
                } else {
                    try await api.perform(.post, "/notes", body: CalendarOpsBody(ops: noteOps))
                }
                queue.removeFirst(min(n, queue.count))
                retryDelay = 2
                saved = true
            } catch let error as APIError where Self.isRejection(error) {
                // The server refused (e.g. a type was deleted elsewhere): drop it and resync.
                queue.removeFirst(min(n, queue.count))
                ErrorBanner.shared.show(String(localized: "Couldn’t save: \(error.localizedDescription)"))
                resync = true
            } catch {
                sync = .retrying
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(retryDelay * 2, 30)
            }
        }
        flushing = false
        sync = .idle
        if saved { notify?(.calendar) }
        if resync || reloadAfterSave { await load(quiet: !resync) }
    }

    private static func sameKind(_ a: Batch, _ b: Batch) -> Bool {
        switch (a, b) {
        case (.entries, .entries), (.notes, .notes): true
        default: false
        }
    }

    /// A refusal that won't change by trying again (unlike 429, 5xx and network errors).
    private static func isRejection(_ error: APIError) -> Bool {
        guard let status = error.status else { return false }
        return status < 500 && status != 429
    }

    // MARK: Editing

    /// Applies day changes, records undo and saves them.
    func commit(_ next: CalendarEntries, record: Bool = true) {
        guard !readOnly else { return }
        let changes = CalendarMath.changedOnly(entries, next)
        guard !changes.isEmpty else { return }
        var before: CalendarEntries = [:]
        for day in changes.keys { before[day] = entries[day] ?? [] }
        let ops = CalendarMath.ops(entries, changes)
        CalendarMath.apply(changes, to: &entries)
        version += 1
        if record { recordStep(.entries(before: before, after: changes)) }
        enqueue(.entries(ops))
    }

    /// Like commit, for notes (nil: remove the day's note).
    func commitNotes(_ next: [Day: CalendarNote?], record: Bool = true) {
        guard !readOnly else { return }
        let changes = CalendarMath.changedNotes(notes, next)
        guard !changes.isEmpty else { return }
        var before: [Day: CalendarNote?] = [:]
        for day in changes.keys { before[day] = .some(notes[day]) }
        let ops = CalendarMath.noteOps(changes)
        CalendarMath.apply(changes, to: &notes)
        version += 1
        if record { recordStep(.notes(before: before, after: changes)) }
        enqueue(.notes(ops))
    }

    private func recordStep(_ step: Step) {
        undoStack.append(step)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        registerWithUndoManager(redo: false)
    }

    /// Mirrors a step in the undo manager: undoing it there calls `undo()`, which registers
    /// the redo (an undo manager records what's registered while undoing as the redo).
    private func registerWithUndoManager(redo: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                if redo { store.redo() } else { store.undo() }
            }
        }
        undoManager.setActionName(String(localized: "Calendar change"))
    }

    private func clearUndo() {
        undoStack = []
        redoStack = []
        undoManager?.removeAllActions(withTarget: self)
    }

    /// The toolbar's and the keyboard's undo: through the undo manager when it has the step, so
    /// both stay in step.
    func performUndo() {
        if let undoManager, undoManager.canUndo, !undoStack.isEmpty { undoManager.undo() } else { undo() }
    }

    func performRedo() {
        if let undoManager, undoManager.canRedo, !redoStack.isEmpty { undoManager.redo() } else { redo() }
    }

    private func applyStep(_ step: Step, before: Bool) {
        switch step {
        case let .entries(b, a): commit(before ? b : a, record: false)
        case let .notes(b, a): commitNotes(before ? b : a, record: false)
        }
    }

    func undo() {
        guard !readOnly else { return }
        guard let step = undoStack.popLast() else { return showToast(String(localized: "Nothing to undo")) }
        applyStep(step, before: true)
        redoStack.append(step)
        if undoManager?.isUndoing == true { registerWithUndoManager(redo: true) }
    }

    func redo() {
        guard !readOnly else { return }
        guard let step = redoStack.popLast() else { return showToast(String(localized: "Nothing to redo")) }
        applyStep(step, before: false)
        undoStack.append(step)
        if undoManager?.isRedoing == true { registerWithUndoManager(redo: false) }
    }

    var selectedDays: [Day] { selection.sorted() }

    /// The selected days, without weekends when "Skip weekends" is on and it's a range.
    func targetDays(_ days: [Day]? = nil) -> [Day] {
        let days = days ?? selectedDays
        return skipWeekends && days.count > 1 ? days.filter { !CalendarMath.isWeekend($0) } : days
    }

    /// Whether every selected day has the type (its chip shows as on).
    func selectionHas(_ typeID: String) -> Bool {
        !selection.isEmpty && selection.allSatisfy { (entries[$0] ?? []).contains(typeID) }
    }

    func toggleOnSelection(_ typeID: String) {
        guard !readOnly else { return }
        let days = targetDays()
        guard !days.isEmpty else { return showToast(String(localized: "Select some days first")) }
        commit(CalendarMath.toggleType(entries, days: days, typeID: typeID))
    }

    func clearSelectedDays() {
        let days = selectedDays
        if !days.isEmpty { commit(CalendarMath.clearDays(days)) }
    }

    /// Icon and comment for the days (nil or empty: removes their notes).
    func setNote(_ note: CalendarNote?, on days: [Day]) {
        var next: [Day: CalendarNote?] = [:]
        for d in days { next[d] = .some(note) }
        commitNotes(next)
    }

    /// Copies the selected span (gaps between selected days included); returns the text.
    @discardableResult
    func copySelection() -> String? {
        let days = selectedDays
        guard let first = days.first, let last = days.last else { return nil }
        let span = CalendarMath.range(first, last)
        let pattern = CalendarMath.pattern(entries, days: span)
        let text = CalendarMath.clipboardText(days: span, pattern: pattern, types: types)
        clipboard = (pattern, text, year)
        showToast(String(localized: "Copied \(CalendarText.days(span.count))"))
        return text
    }

    var canPaste: Bool { clipboard != nil }

    func paste(_ pattern: CalendarPattern) {
        guard !readOnly else { return }
        let days = selectedDays
        guard !days.isEmpty else { return showToast(String(localized: "Select where to paste first")) }
        guard !pattern.isEmpty else { return }
        let targets = days.count == 1
            ? CalendarMath.pasteTargets(days, patternLength: pattern.count, last: Day(year: year, month: 12, day: 31),
                                        skipWeekends: skipWeekends)
            : targetDays(days)
        commit(CalendarMath.fill(targets, with: pattern))
        if days.count == 1, let first = targets.first, let last = targets.last { select(first, last) }
    }

    /// Pastes text: our own copy if it is one, else type names per line.
    func paste(text: String?) {
        guard !readOnly else { return }
        var text = text ?? ""
        if let clipboard, text == clipboard.text || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Our own copy keeps type ids, but ids belong to their year: elsewhere match names.
            if clipboard.year == year { return paste(clipboard.pattern) }
            text = clipboard.text
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let (pattern, unknown) = CalendarMath.parseClipboard(text, types: types)
        if !unknown.isEmpty {
            showToast(unknown.count == 1
                      ? String(localized: "Unknown type: \(unknown[0])")
                      : String(localized: "Unknown types: \(unknown.joined(separator: ", "))"))
        }
        paste(pattern)
    }

    // MARK: Fill handle

    /// The selection can be repeated: days that follow each other, and the right to change them.
    var canRepeat: Bool { !readOnly && CalendarMath.isContiguous(selectedDays) }

    /// Starts dragging the fill handle; false when the selection can't be repeated.
    @discardableResult
    func beginFill() -> Bool {
        guard canRepeat else { return false }
        fill = CalendarFill(source: selectedDays)
        return true
    }

    /// The handle is over `hover`: the days after (or before) the selection up to it, without
    /// weekends when "Skip weekends" is on.
    func dragFill(to hover: Day) {
        guard var f = fill else { return }
        let (days, backwards) = CalendarMath.fillTargets(source: f.source, hover: hover)
        f.targets = targetDays(days)
        f.backwards = backwards
        fill = f
    }

    /// Esc while dragging; returns whether a fill was going on.
    @discardableResult
    func cancelFill() -> Bool {
        guard fill != nil else { return false }
        fill = nil
        return true
    }

    /// Lets go of the handle: repeats the selection over the targets and selects all of it.
    func endFill() {
        guard let f = fill else { return }
        fill = nil
        guard !f.targets.isEmpty else { return }
        commit(CalendarMath.fillChanges(entries, source: targetDays(f.source), targets: f.targets, backwards: f.backwards))
        let all = (f.source + f.targets).sorted()
        if let first = all.first, let last = all.last {
            select(f.backwards ? last : first, f.backwards ? first : last)
        }
    }

    /// The repeat sheet (touch screens' fill handle): repeats the selection up to `day`.
    func repeatSelection(to day: Day) {
        guard beginFill() else { return }
        dragFill(to: day)
        endFill()
    }

    // MARK: Selection

    /// A route to the day: its year, the day selected.
    func show(_ day: Day) {
        if day.year != year { setYear(day.year) }
        select(day)
    }

    func select(_ a: Day, _ b: Day? = nil, add: Bool = false) {
        if !add { selection.removeAll() }
        for d in CalendarMath.range(a, b ?? a) where d.year == year { selection.insert(d) }
        anchor = a
        focus = b ?? a
    }

    func setSelection(_ days: Set<Day>, anchor: Day?, focus: Day?) {
        selection = days.filter { $0.year == year }
        self.anchor = anchor
        self.focus = focus
    }

    /// Adds a day to the selection, or removes it if it is selected.
    func toggleDay(_ day: Day) {
        if selection.contains(day) {
            selection.remove(day)
            anchor = day
            focus = day
        } else {
            select(day, add: true)
        }
    }

    /// A tap or click on a day: `extend` (Shift, or range mode) selects from the anchor,
    /// `toggle` (⌘, or multi-select) adds or removes the day, else the day alone is selected
    /// (or unselected when it was the only one).
    func tap(_ day: Day, extend: Bool = false, toggle: Bool = false) {
        if (extend || rangeMode), let anchor {
            select(anchor, day, add: multiSelect)
            rangeMode = false
        } else if toggle || multiSelect {
            toggleDay(day)
        } else if selection == [day] {
            deselect()
        } else {
            select(day)
        }
    }

    func deselect() {
        selection.removeAll()
        multiSelect = false
        rangeMode = false
    }

    func selectAll() {
        select(Day(year: year, month: 1, day: 1), Day(year: year, month: 12, day: 31))
    }

    /// Arrow keys: by days (or weeks), or a month with |delta| ≥ 31. Returns the new focus.
    @discardableResult
    func moveFocus(_ delta: Int, extend: Bool) -> Day? {
        let from = focus ?? (Day.today.year == year ? Day.today : Day(year: year, month: 1, day: 1))
        var next: Day
        if abs(delta) < 31 {
            next = CalendarMath.add(from, delta)
        } else {
            let month = from.month + (delta > 0 ? 1 : -1)
            guard (1...12).contains(month) else { return nil }
            next = Day(year: from.year, month: month, day: min(from.day, CalendarMath.daysInMonth(year: from.year, month: month)))
        }
        guard next.year == year else { return nil }
        if extend { select(anchor ?? from, next) } else { select(next) }
        focus = next
        return next
    }

    /// Selects the next day that needs cover; nil when there is none.
    @discardableResult
    func nextGap() -> Day? {
        let gaps = gapDays
        guard let first = gaps.first else {
            showToast(String(localized: "No uncovered days in \(String(year))"))
            return nil
        }
        let next = gaps.first { $0 > (focus ?? Day(year: year - 1, month: 12, day: 31)) } ?? first
        select(next)
        return next
    }

    // MARK: Years

    func setYear(_ y: Int) {
        guard (1900...2200).contains(y), y != year else { return }
        year = y
        Self.lastYear = y
        selection.removeAll()
        anchor = nil
        focus = nil
        // Undo steps hold type ids of their year.
        clearUndo()
        fill = nil
        version += 1
        types = []
        typeYears = nil
        entries = [:]
        notes = [:]
        events = [:]
        birthdays = [:]
        Task { await load() }
    }

    /// The year to copy types from when this one has none: the closest earlier, else later.
    var copySource: Int? {
        let years = (typeYears ?? []).filter { $0 != year }
        return years.last { $0 < year } ?? years.first
    }

    // MARK: Types

    func daysWith(_ typeID: String) -> Int {
        entries.values.filter { $0.contains(typeID) }.count
    }

    private var yearQuery: [String: String?] { ["year": String(year)] }

    private func addTypeYear(_ y: Int) {
        typeYears = Array(Set((typeYears ?? []) + [y])).sorted()
    }

    @discardableResult
    func addType(name: String? = nil) async throws -> CalendarEntryType {
        let patch = CalendarTypePatch(
            name: name ?? String(localized: "New type \(types.count + 1)"),
            color: CalendarMath.nextColor(types), role: CalendarRole.none
        )
        let created: CalendarEntryType = try await api.send(.post, "/types", query: yearQuery, body: patch)
        types.append(created)
        addTypeYear(year)
        version += 1
        notify?(.calendar)
        return created
    }

    func updateType(_ id: String, _ patch: CalendarTypePatch) async throws {
        if let i = types.firstIndex(where: { $0.id == id }) {
            if let name = patch.name { types[i].name = name }
            if let color = patch.color { types[i].color = color }
            if let role = patch.role { types[i].role = role }
            if let away = patch.away { types[i].away = away }
            if let position = patch.position { types[i].position = position }
        }
        version += 1
        do {
            let _: CalendarEntryType = try await api.send(.patch, "/types/\(id)", query: yearQuery, body: patch)
            notify?(.calendar)
        } catch {
            await load(quiet: true)
            throw error
        }
    }

    /// Reorders the types (List's onMove) and saves the positions that changed.
    func moveTypes(from source: IndexSet, to destination: Int) async throws {
        var list = types
        list.move(fromOffsets: source, toOffset: destination)
        var changed: [(String, Int)] = []
        for (i, t) in list.enumerated() where t.position != i {
            list[i].position = i
            changed.append((t.id, i))
        }
        types = list
        version += 1
        do {
            for (id, position) in changed {
                let _: CalendarEntryType = try await api.send(.patch, "/types/\(id)", query: yearQuery,
                                                                body: CalendarTypePatch(position: position))
            }
            notify?(.calendar)
        } catch {
            await load(quiet: true)
            throw error
        }
    }

    func deleteType(_ id: String) async throws {
        try await api.perform(.delete, "/types/\(id)?year=\(year)")
        types.removeAll { $0.id == id }
        for (day, ids) in entries {
            let rest = ids.filter { $0 != id }
            entries[day] = rest.isEmpty ? nil : rest
        }
        if types.isEmpty { typeYears = typeYears?.filter { $0 != year } }
        clearUndo()
        version += 1
        notify?(.calendar)
    }

    /// Copies the types of `from` into the shown year (the ones it doesn't have yet).
    func copyTypes(from: Int) async throws {
        let y = year
        let copied: [CalendarEntryType] = try await api.send(.post, "/types/copy", body: CalendarCopyTypesBody(from: from, to: y))
        guard y == year else { return }
        types = copied.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        addTypeYear(y)
        version += 1
        notify?(.calendar)
    }

    // MARK: Feed links

    /// "feed": a new feed address (the old one stops working); "legacy": removes the old link.
    func rotateLink(_ link: String) async throws {
        let state: CalendarState = try await api.send(.post, "/links", query: yearQuery, body: CalendarLinkBody(link: link))
        family = state.family
    }

    // MARK: Events

    func saveEvent(_ input: CalendarEventInput, id: String?) async throws {
        if let id {
            let _: CalendarEvent = try await api.send(.patch, "/events/\(id)", body: input)
        } else {
            let _: CalendarEvent = try await api.send(.post, "/events", body: input)
        }
        notify?(.events)
        await load(quiet: true)
    }

    func deleteEvent(_ event: CalendarEvent) async throws {
        try await api.perform(.delete, "/events/\(event.id)")
        events[event.date]?.removeAll { $0.id == event.id }
        notify?(.events)
        await load(quiet: true)
    }
}

/// The fill handle's drag: the selection it repeats and the days it would fill.
struct CalendarFill: Equatable {
    var source: [Day]
    var targets: [Day] = [] {
        didSet { targetSet = Set(targets) }
    }
    var backwards = false
    /// The targets as a set, for the cells' preview.
    private(set) var targetSet: Set<Day> = []

    init(source: [Day]) { self.source = source }
}

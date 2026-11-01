import CoreGraphics
import Foundation
import Observation

/// One open family calendar: the types, entries, notes, events and birthdays of one year, the
/// queue that saves local edits, undo / redo and the day selection (the web app's
/// components/calendar/planner-store.ts). Edits work offline: the queue is kept on the device
/// (`queueFile`) until the server took it, and shows on top of what's loaded meanwhile. The
/// server wins: what it refuses is dropped, and the calendar loads its state again.
@Observable
final class CalendarStore {
    enum Phase: Equatable {
        case loading, loaded, notFound
        case failed(String)
    }

    enum Sync: Equatable {
        case idle, saving, retrying
    }

    /// The year shows the copy kept on the device (`ResponseCache`), from `date`, until the server
    /// answers: `updating` while it's asked, false once it couldn't be reached.
    struct SavedCopy: Equatable {
        var date: Date
        var updating: Bool
    }

    /// An undoable change: the days' values before and after, a deleted event or one moved to
    /// another day.
    enum Step {
        case entries(before: CalendarEntries, after: CalendarEntries)
        case notes(before: [Day: CalendarNote?], after: [Day: CalendarNote?])
        case deletedEvent(CalendarDeletedEvent)
        case movedEvent(id: String, from: Day, to: Day)
    }

    private enum Batch: Codable {
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
    /// Nothing can be changed: a viewer. On the copy on the device changes are queued like any
    /// other and sent once the server can be reached.
    private(set) var readOnly: Bool
    /// A viewer of the family (by the app's role or the server's answer): it stays read-only.
    private(set) var isViewer: Bool
    /// What's shown is the copy on the device, not the server's latest; nil once it answered.
    private(set) var savedCopy: SavedCopy?

    private(set) var selection: Set<Day> = []
    private(set) var anchor: Day?
    private(set) var focus: Day?
    /// Touch: the next tap selects the range from the anchor to it.
    var rangeMode = false
    /// Touch: taps add days to the selection or remove them.
    var multiSelect = false
    /// Touch: a long-press drag is selecting days; the day under the finger shows its outline.
    var dragging = false

    private(set) var undoStack: [Step] = []
    private(set) var redoStack: [Step] = []
    private(set) var sync: Sync = .idle
    /// A short message (copied, nothing to undo…), shown for a moment.
    private(set) var toast: String?
    /// The toast follows a change that can be undone: it offers Undo.
    private(set) var toastOffersUndo = false

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
    /// The day under an event being dragged over a grid (iPad, Mac): where it would land.
    private(set) var dropTarget: Day?
    /// Where the month in detail shows its events (by "id@day"), in the grid's coordinate space
    /// (`CalendarMonthGrid.space`): a press there drags the event instead of selecting days.
    /// Only the grid's gestures read it, so it isn't observed.
    @ObservationIgnored var eventLabels: [String: (day: Day, frame: CGRect)] = [:]

    private var clipboard: (pattern: CalendarPattern, text: String, year: Int)?
    private var version = 0
    private var queue: [Batch] = []
    /// Where the queue is kept while it holds changes; nil: only in memory (the demo, tests,
    /// Settings → Calendar, which changes no days).
    private let queueFile: URL?
    /// Counts the batches the server took or refused: a load asked before one of them may not
    /// have it yet.
    private var sent = 0
    private var flushing = false
    private var retryDelay: Double = 2
    /// The wait before trying again; cancelled when the connection comes back.
    private var retryWait: Task<Void, Never>?
    private var reloadAfterSave = false
    private var toastTask: Task<Void, Never>?
    /// The role the screen opened the calendar with (`FamilyContext.canEdit`).
    private let ownReadOnly: Bool
    /// The year whose state (the server's or the saved copy) is shown; nil before the first.
    private var shownYear: Int?

    /// `queueFile` keeps the queue on the device (`CalendarStore.queueFile(for:)`): changes not
    /// sent before the app quit are read back and sent again.
    init(api: FamilyAPI, year: Int? = nil, readOnly: Bool, queueFile: URL? = nil) {
        self.api = api
        self.year = year ?? Self.lastYear ?? Day.today.year
        self.readOnly = readOnly
        self.isViewer = readOnly
        ownReadOnly = readOnly
        self.queueFile = queueFile
        skipWeekends = UserDefaults.standard.bool(forKey: Self.skipWeekendsKey)
        if let queueFile, let data = try? Data(contentsOf: queueFile),
           let saved = try? JSONDecoder().decode([Batch].self, from: data), !saved.isEmpty {
            queue = saved
            Task { await flush() }
        }
        Connectivity.shared.whenReconnected { [weak self] in self?.retryNow() }
    }

    /// Where a family's queue is kept: Application Support, `Ohana/Calendar/<server>_<family>/
    /// queue.json`; nil in the demo.
    static func queueFile(for api: FamilyAPI) -> URL? {
        guard !api.client.isDemo else { return nil }
        return queueBase.appending(path: safe(serverPrefix(api.client.baseURL) + api.familyID), directoryHint: .isDirectory)
            .appending(path: "queue.json")
    }

    /// Signing out: the queues of every family on `server` are removed.
    static func removeQueues(server: URL) {
        let prefix = safe(serverPrefix(server))
        let folders = (try? FileManager.default.contentsOfDirectory(at: queueBase, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static var queueBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Ohana/Calendar", directoryHint: .isDirectory)
    }

    private static func serverPrefix(_ server: URL) -> String {
        "\(server.host() ?? "server")\(server.port.map { "-\($0)" } ?? "")_"
    }

    /// A file name of letters, digits, dots, dashes and underscores.
    private static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    var isLoaded: Bool { phase == .loaded }
    var pending: Bool { !queue.isEmpty || flushing }
    /// Types and feed links are changed on the server at once, not queued: not while the copy
    /// on the device shows.
    var typesReadOnly: Bool { readOnly || savedCopy != nil }
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

    /// What a grid needs for all of its days, worked out once per redraw of the grid.
    func cellContext(gridFocused: Bool) -> CalendarCellContext {
        var common: Set<String>?
        for day in selection {
            let ids = Set(entries[day] ?? [])
            common = common.map { $0.intersection(ids) } ?? ids
            if common?.isEmpty == true { break }
        }
        return CalendarCellContext(roles: CalendarMath.roles(types), today: .today,
                                   focus: gridFocused || dragging ? focus : nil, selectionTypes: common ?? [])
    }

    /// A day's cell as values: the cells don't read the store themselves, so a change redraws
    /// only the days it touches, not the whole year.
    func cell(_ day: Day, _ context: CalendarCellContext) -> CalendarDayCell.Info {
        let dayTypes = types(on: day)
        let selected = selection.contains(day)
        return CalendarDayCell.Info(
            types: dayTypes, note: notes[day], events: events[day] ?? [], birthdays: birthdays[day] ?? [],
            selected: selected, preview: fill?.targetSet.contains(day) ?? false, dropTarget: dropTarget == day,
            focused: context.focus == day,
            isToday: day == context.today, gap: CalendarMath.isGap(day, entries[day], roles: context.roles),
            onTypes: selected ? context.selectionTypes : Set(dayTypes.map(\.id)),
            allTypes: types, readOnly: readOnly
        )
    }

    var stats: [String: CalendarTypeStats] { CalendarMath.stats(entries, types: types, year: year) }
    var gapDays: [Day] { CalendarMath.gapDays(entries, types: types, year: year) }
    var needsCoverTypes: [CalendarEntryType] { types.filter { $0.role == .needsCover } }

    func showToast(_ text: String, undo: Bool = false) {
        toast = text
        toastOffersUndo = undo
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(undo ? 5 : 2.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Loading and saving

    /// Takes a loaded state, the server's or (with its date) the copy on the device, with the
    /// queued changes on top until they're sent. Only what changed is assigned: polling brings
    /// the same state every 15 seconds, and an equal value would still redraw everything that
    /// reads it.
    func apply(_ state: CalendarState, savedAt date: Date? = nil) {
        shownYear = year
        update(\.savedCopy, date.map { SavedCopy(date: $0, updating: true) })
        update(\.family, state.family)
        update(\.isViewer, ownReadOnly || state.family.readOnly)
        updateReadOnly()
        update(\.types, state.types
            .filter { $0.year == nil || $0.year == year }
            .enumerated()
            .sorted { ($0.element.position ?? $0.offset, $0.offset) < ($1.element.position ?? $1.offset, $1.offset) }
            .map(\.element))
        update(\.typeYears, state.typeYears)
        var entries = Self.byDay(state.entries), notes = Self.byDay(state.notes ?? [:])
        for batch in queue {
            switch batch {
            case let .entries(ops): CalendarMath.apply(ops, to: &entries, year: year)
            case let .notes(ops): CalendarMath.apply(ops, to: &notes, year: year)
            }
        }
        update(\.entries, entries)
        update(\.notes, notes)
        update(\.events, Self.byDay(state.events ?? [:]))
        update(\.birthdays, Self.byDay(state.birthdays ?? [:]))
        update(\.phase, .loaded)
    }

    private func updateReadOnly() {
        update(\.readOnly, isViewer)
    }

    private func update<V: Equatable>(_ path: ReferenceWritableKeyPath<CalendarStore, V>, _ value: V) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    static func byDay<V>(_ map: [String: V]) -> [Day: V] {
        var out: [Day: V] = [:]
        for (key, value) in map { if let day = Day(key) { out[day] = value } }
        return out
    }

    /// Fetches the year. A quiet load (polling, another screen's change) shows no errors. With
    /// nothing of the year shown yet, its copy on the device shows meanwhile, and stays while the
    /// server can't be reached.
    func load(quiet: Bool = false) async {
        let (version, sent, year) = (self.version, self.sent, self.year)
        let get = api.cached("", query: ["year": String(year)], as: CalendarState.self)
        if shownYear != year, let copy = get.saved() {
            apply(copy.value, savedAt: copy.date)
        } else if !quiet, savedCopy != nil {
            savedCopy?.updating = true
        }
        do {
            let state = try await get.fetch()
            // The year switched: its own load is under way.
            guard year == self.year else { return }
            // Something changed or was sent meanwhile, which the answer may miss: ask again, now
            // or once the queue is sent.
            guard version == self.version, sent == self.sent else {
                if pending { reloadAfterSave = true } else { await load(quiet: quiet) }
                return
            }
            // What's still queued shows on top of it; once it's sent, the server's state alone.
            reloadAfterSave = pending
            apply(state)
        } catch let error as APIError where error.status == 404 {
            phase = .notFound
            dropSavedCopy()
        } catch {
            guard year == self.year else { return }
            if let copy = savedCopy {
                // The copy stays while the failure may pass (offline, the server down).
                if APIError.isTemporary(error) {
                    update(\.savedCopy, SavedCopy(date: copy.date, updating: false))
                } else {
                    phase = .failed(error.localizedDescription)
                    dropSavedCopy()
                }
            } else if error is CancellationError {
            } else if phase != .loaded {
                phase = .failed(error.localizedDescription)
            } else if !quiet {
                ErrorBanner.shared.show(error)
            }
        }
    }

    private func dropSavedCopy() {
        savedCopy = nil
        shownYear = nil
        updateReadOnly()
    }

    /// Reloads every 15 seconds while nothing is being saved (other people's changes, or the
    /// server's state in place of the copy on the device once it can be reached again).
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
        saveQueue()
        Task { await flush() }
    }

    /// Keeps the queue on the device while it holds changes.
    private func saveQueue() {
        guard let queueFile else { return }
        do {
            if queue.isEmpty {
                try? FileManager.default.removeItem(at: queueFile)
            } else {
                try FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(queue).write(to: queueFile, options: .atomic)
            }
        } catch {
            // The queue in memory is still sent; only quitting before that would lose it.
        }
    }

    /// Takes the batches the server took or refused off the queue.
    private func dequeue(_ n: Int) {
        queue.removeFirst(min(n, queue.count))
        sent += 1
        saveQueue()
    }

    /// The connection is back: what waits is sent now, not after the backoff.
    func retryNow() {
        retryDelay = 2
        retryWait?.cancel()
        if !flushing && !queue.isEmpty { Task { await flush() } }
    }

    private func flush() async {
        guard !flushing else { return }
        flushing = true
        var saved = false, resync = false
        while let first = queue.first {
            // While retrying the badge stays: each try would flash "Saving…".
            if sync != .retrying { sync = .saving }
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
                dequeue(n)
                retryDelay = 2
                sync = .saving
                saved = true
            } catch let error as APIError where Self.isRejection(error) {
                // The server refused (e.g. a type was deleted elsewhere): it wins, drop it and resync.
                dequeue(n)
                ErrorBanner.shared.show(String(localized: "Couldn’t save: \(error.localizedDescription)"))
                resync = true
            } catch {
                // Offline or the server down: try again after a while, or once the connection is back.
                sync = .retrying
                let delay = retryDelay
                retryDelay = min(retryDelay * 2, 30)
                let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
                retryWait = wait
                await wait.value
                retryWait = nil
            }
        }
        flushing = false
        sync = .idle
        if saved { notify?(.calendar) }
        // The copy on the device shows: the server's state now has the changes.
        if resync || reloadAfterSave || (saved && savedCopy != nil) { await load(quiet: !resync) }
    }

    private static func sameKind(_ a: Batch, _ b: Batch) -> Bool {
        switch (a, b) {
        case (.entries, .entries), (.notes, .notes): true
        default: false
        }
    }

    /// A refusal that won't change by trying again (unlike 408, 429, 5xx and network errors).
    private static func isRejection(_ error: APIError) -> Bool {
        guard let status = error.status else { return false }
        return !APIError.isTemporary(error) && status < 500
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
        case let .deletedEvent(deleted):
            perform { [self] in
                if before { try await restoreEvent(deleted) } else { try await removeEvent(deleted.event) }
            }
        case let .movedEvent(id, from, to):
            shiftEvent(id, from: before ? to : from, to: before ? from : to)
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
        update(\.fill, f)
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
        var next = add ? selection : []
        for d in CalendarMath.range(a, b ?? a) where d.year == year { next.insert(d) }
        setSelection(next, anchor: a, focus: b ?? a)
    }

    /// A drag sets the same selection many times a second: only a different one is assigned.
    func setSelection(_ days: Set<Day>, anchor: Day?, focus: Day?) {
        update(\.selection, days.filter { $0.year == year })
        update(\.anchor, anchor)
        update(\.focus, focus)
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
        update(\.selection, [])
        update(\.multiSelect, false)
        update(\.rangeMode, false)
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
        update(\.focus, next)
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
        // The new year shows its own copy on the device, if it has one, or nothing until loaded.
        savedCopy = nil
        updateReadOnly()
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

    /// Deletes an event; undo (⌘Z, the toast) adds it again.
    func deleteEvent(_ event: CalendarEvent) async throws {
        try await removeEvent(event)
        guard event.date.year == year else { return }
        recordStep(.deletedEvent(CalendarDeletedEvent(event)))
        showToast(String(localized: "Deleted “\(event.title)”"), undo: true)
    }

    private func removeEvent(_ event: CalendarEvent) async throws {
        try await api.perform(.delete, "/events/\(event.id)")
        events[event.date]?.removeAll { $0.id == event.id }
        notify?(.events)
        await load(quiet: true)
    }

    /// Moves an event to another day of the year (dropped there): here at once, then saved;
    /// undo (⌘Z, the toast) moves it back. A booked appointment stays one.
    func moveEvent(_ event: CalendarEvent, to day: Day) {
        guard !readOnly, day != event.date, day.year == year, find(event.id, near: event.date) != nil else { return }
        shiftEvent(event.id, from: event.date, to: day)
        recordStep(.movedEvent(id: event.id, from: event.date, to: day))
        showToast(String(localized: "Moved “\(event.title)” to \(CalendarText.day(day))"), undo: true)
    }

    /// An event dropped on `day`: moved there when it is one of this family's events.
    func dropEvent(_ item: CalendarEventDragItem, on day: Day) {
        guard item.familyID == api.familyID, let from = Day(item.date),
              let found = find(item.eventID, near: from), let event = events[found]?.first(where: { $0.id == item.eventID })
        else { return }
        moveEvent(event, to: day)
    }

    /// The payload of an event's drag.
    func dragItem(_ event: CalendarEvent) -> CalendarEventDragItem {
        CalendarEventDragItem(familyID: api.familyID, eventID: event.id, date: event.date.description)
    }

    /// While an event is dragged over a grid: the day it would land on (nil: none).
    func setDropTarget(_ day: Day?) {
        update(\.dropTarget, readOnly ? nil : day)
    }

    /// Whether `point` (in the coordinate space of the month in detail) is on one of `day`'s
    /// events. The day comes from the grid's layout: labels that overflow their cell don't count.
    func isOnEvent(_ point: CGPoint, day: Day?) -> Bool {
        guard let day else { return false }
        return eventLabels.values.contains { $0.day == day && $0.frame.contains(point) }
    }

    /// The day an event is on: `near` when it is there, else wherever it is.
    private func find(_ id: String, near day: Day) -> Day? {
        if events[day]?.contains(where: { $0.id == id }) == true { return day }
        return events.first { $0.value.contains { $0.id == id } }?.key
    }

    /// Puts an event on `to` here and saves its new date (PATCH {date}); a failure puts it
    /// back and shows why.
    private func shiftEvent(_ id: String, from: Day, to: Day) {
        relocate(id, from: from, to: to)
        Task {
            do {
                try await api.perform(.patch, "/events/\(id)", body: CalendarEventDateBody(date: to))
                notify?(.events)
            } catch {
                relocate(id, from: to, to: from)
                if !(error is CancellationError) { ErrorBanner.shared.show(error) }
            }
            await load(quiet: true)
        }
    }

    /// Moves an event between days of `events`, in the server's order (by start time).
    private func relocate(_ id: String, from: Day, to: Day) {
        guard let day = find(id, near: from), var list = events[day],
              let index = list.firstIndex(where: { $0.id == id }) else { return }
        let event = list.remove(at: index)
        events[day] = list.isEmpty ? nil : list
        if to.year == year {
            var target = events[to] ?? []
            let moved = event.on(to)
            let at = target.firstIndex { ($0.start ?? "") > (moved.start ?? "") } ?? target.endIndex
            target.insert(moved, at: at)
            events[to] = target
        }
        // A load that started before this would bring the old day back.
        version += 1
    }

    /// Undoing a deletion: the event again with what it had (POST /events). It gets a new id,
    /// which a redo deletes; an appointment's booking comes back as an event of its own.
    private func restoreEvent(_ deleted: CalendarDeletedEvent) async throws {
        let restored: CalendarEvent = try await api.send(.post, "/events", body: CalendarEventInput(deleted.event))
        deleted.event = restored
        notify?(.events)
        await load(quiet: true)
    }
}

/// A deleted event in the undo history: the event as it was, then as undo made it again.
final class CalendarDeletedEvent {
    var event: CalendarEvent
    init(_ event: CalendarEvent) { self.event = event }
}

extension CalendarEventInput {
    /// What the event has, to save it again.
    init(_ event: CalendarEvent) {
        self.init(date: event.date, start: event.start, end: event.end, title: event.title,
                  location: event.location, person: event.person, note: event.note, url: event.url)
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

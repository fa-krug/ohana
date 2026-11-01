import Foundation

// What a sync between a family's calendar and one Apple Calendar calendar does (`AppleCalendarSync`
// runs it with EventKit): pure, so the tests run it without EventKit.
//
// Events go both ways: an Ohana event gets a copy in the Apple calendar, an Apple event is imported
// into Ohana (POST /events with `externalId`), and either side's later edits and deletions reach the
// other. When both changed since the last sync, Ohana's wins. A repeating event is synced as one
// series (its rule and its first occurrence), and within the window the occurrences changed or
// deleted on their own, day by day. Multi-day events keep their days. The day entries (vacation,
// holidays, …) go to Apple only, as all-day events over each run of days: Apple-side changes to them
// are put back. Copies Ohana writes carry its link (`AppleSyncMark`) and imported events keep their
// Apple id on the server, so a second device syncing the same (iCloud) calendar links them instead
// of copying them again. A viewer only sends Ohana's events to Apple.

/// What the sync reads and writes of an Apple event (a single one, a series' first occurrence or
/// one occurrence), in Ohana's terms: the first and last day, the wall-clock times (nil: all day;
/// `end` on the last day, nil when none), the text, and a series' rule (`RepeatRule.string`).
struct AppleSyncFields: Codable, Equatable {
    var day: Day
    var lastDay: Day
    var start: String?
    var end: String?
    var title: String
    var location: String
    var notes: String
    var rrule: String?
}

/// What the sync compares of an Ohana event (a single one, a series or one occurrence): all it sends
/// to Apple.
struct OhanaSyncFields: Codable, Equatable {
    var date: Day
    var endDate: Day
    var start: String?
    var end: String?
    var title: String
    var location: String
    var person: String
    var note: String
    var url: String
    var rrule: String?

    init(date: Day, endDate: Day, start: String?, end: String?, title: String, location: String = "",
         person: String = "", note: String = "", url: String = "", rrule: String? = nil) {
        self.date = date
        self.endDate = max(endDate, date)
        self.start = start
        self.end = start == nil ? nil : end
        self.title = title
        self.location = location
        self.person = person
        self.note = note
        self.url = url
        self.rrule = RepeatRule.canonical(rrule)
    }

    /// A single event or a series, with its rule.
    init(_ s: CalendarEventSeries) {
        self.init(date: s.date, endDate: s.endDate, start: s.start, end: s.end, title: s.title, location: s.location,
                  person: s.person, note: s.note, url: s.url, rrule: s.rrule)
    }

    /// One occurrence as it is (no rule).
    init(occurrence e: CalendarEvent) {
        self.init(date: e.date, endDate: e.endDate, start: e.start, end: e.end, title: e.title, location: e.location,
                  person: e.person, note: e.note, url: e.url)
    }

    var input: CalendarEventInput {
        CalendarEventInput(date: date, endDate: endDate, start: start, end: end, title: title, location: location,
                           person: person, note: note, url: url, rrule: rrule)
    }
}

/// An Ohana event as the sync sees it: a single event or a series, with a series' occurrences
/// around the window by their original day.
struct OhanaSyncItem: Equatable {
    var id: String
    var externalId: String?
    var fields: OhanaSyncFields
    /// It has an occurrence in the window (or, a single event, is in it).
    var inWindow: Bool
    /// A series' occurrences: as the rule makes them, changed on their own, or taken out.
    var occurrences: [Day: OhanaOccurrence] = [:]
    /// What each occurrence listed is now.
    var occurrenceFields: [Day: OhanaSyncFields] = [:]
}

/// An Apple event as the sync sees it (an `EKEvent` without EventKit): a single event or a series.
struct AppleSyncEvent: Equatable {
    /// The event's `calendarItemIdentifier` on this device.
    var localID: String
    /// The same event on every device of the account (the iCalendar UID where the calendar has one):
    /// the `externalId` an import gets on the server.
    var key: String
    var url: URL?
    /// The event, or a series' first occurrence with its rule.
    var fields: AppleSyncFields
    var inWindow = true
    /// A series' occurrences around the window by their original day; nil when not known (found
    /// outside the window).
    var occurrences: [Day: AppleOccurrence]?
}

enum OhanaOccurrence: Codable, Equatable {
    case normal, deleted
    case changed(OhanaSyncFields)
}

enum AppleOccurrence: Codable, Equatable {
    case normal, deleted
    case changed(AppleSyncFields)
}

/// One occurrence of a linked series that isn't as the rule makes it on one side or both, as the
/// last sync left it.
struct AppleSyncException: Codable, Equatable {
    var ohana: OhanaOccurrence = .normal
    var apple: AppleOccurrence = .normal
}

/// An Ohana event and its Apple event, as they were after the last sync: the next one sees which
/// side changed.
struct AppleSyncLink: Codable, Equatable {
    var ohanaID: String
    var appleID: String
    /// The Apple event's `key`: finds it again when its `appleID` changed.
    var appleKey: String
    var ohana: OhanaSyncFields
    var apple: AppleSyncFields
    /// A series' occurrences that aren't as the rule makes them, by their original day.
    var exceptions: [Day: AppleSyncException] = [:]
}

/// A run of days with one entry type, as one all-day Apple event.
struct AppleSyncSpan: Equatable {
    var typeID: String
    var title: String
    var first: Day
    var last: Day
}

/// The Ohana link on an event Ohana wrote into the Apple calendar. It opens the day in the app
/// (`AppRoute.parse`: `ohana://f/{family}/calendar/{day}`), and names the event or entry type.
enum AppleSyncMark: Equatable {
    case event(String)
    case entry(String)

    static func url(family: String, day: Day, _ mark: AppleSyncMark) -> URL {
        var c = URLComponents()
        c.scheme = DevicePairing.callbackScheme
        c.host = "f"
        c.path = "/\(family)/calendar/\(day)"
        switch mark {
        case let .event(id): c.queryItems = [URLQueryItem(name: "event", value: id)]
        case let .entry(type): c.queryItems = [URLQueryItem(name: "entry", value: type)]
        }
        return c.url!
    }

    /// The mark of `url` when it is one of `family`'s.
    init?(_ url: URL?, family: String) {
        guard let url, url.scheme == DevicePairing.callbackScheme, url.host() == "f",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = c.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == family, parts[1] == "calendar" else { return nil }
        let items = c.queryItems ?? []
        if let id = items.first(where: { $0.name == "event" })?.value, !id.isEmpty {
            self = .event(id)
        } else if let type = items.first(where: { $0.name == "entry" })?.value, !type.isEmpty {
            self = .entry(type)
        } else {
            return nil
        }
    }
}

/// Converting between the two sides.
enum AppleSyncMapping {
    /// The Apple event's title: the person in brackets (like the calendar's `line`).
    static func title(_ o: OhanaSyncFields) -> String {
        o.person.isEmpty ? o.title : "\(o.title) (\(o.person))"
    }

    /// The Apple event's notes: the note, then the link (the Apple event's own URL is Ohana's mark).
    static func notes(_ o: OhanaSyncFields) -> String {
        [o.note, o.url].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The Apple event as Ohana writes it.
    static func apple(_ o: OhanaSyncFields) -> AppleSyncFields {
        AppleSyncFields(day: o.date, lastDay: o.endDate, start: o.start, end: o.end, title: title(o),
                        location: o.location, notes: notes(o), rrule: o.rrule)
    }

    /// The Ohana event an Apple event becomes: `current` (the linked event, if any) keeps its person
    /// and link, which the title and notes carry; a new one takes the Apple event's web link. Texts
    /// are cut to what the server takes; an end the server wouldn't take is left out.
    static func ohana(_ a: AppleSyncFields, url appleURL: URL? = nil, current: OhanaSyncFields?) -> OhanaSyncFields {
        let person = current?.person ?? ""
        let url = current?.url ?? appleURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0.absoluteString : nil } ?? ""
        var title = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !person.isEmpty, title.hasSuffix(" (\(person))") { title = String(title.dropLast(person.count + 3)) }
        var note = a.notes
        if !url.isEmpty, note.hasSuffix(url) {
            note = String(note.dropLast(url.count))
            while note.hasSuffix("\n") { note.removeLast() }
        }
        title = cut(title.trimmingCharacters(in: .whitespacesAndNewlines), 200)
        var end = a.start == nil ? nil : a.end
        if let start = a.start, let e = end, a.lastDay <= a.day, e < start { end = nil }
        return OhanaSyncFields(
            date: a.day, endDate: a.lastDay, start: a.start, end: end,
            title: title.isEmpty ? String(localized: "Event") : title,
            location: cut(a.location.trimmingCharacters(in: .whitespacesAndNewlines), 300), person: person,
            note: cut(note.trimmingCharacters(in: .whitespacesAndNewlines), 1000), url: url.count <= 2000 ? url : "",
            rrule: a.rrule
        )
    }

    private static func cut(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max))
    }

    /// The runs of days with the same type, in `window` (types are per year: a run ends with it).
    static func spans(entries: [Day: [String]], types: [Int: [CalendarEntryType]], window: ClosedRange<Day>) -> [AppleSyncSpan] {
        var days: [String: [Day]] = [:]
        for (day, ids) in entries where window.contains(day) {
            for id in ids { days["\(day.year)/\(id)", default: []].append(day) }
        }
        var out: [AppleSyncSpan] = []
        for (key, list) in days {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard let year = Int(parts[0]), let type = types[year]?.first(where: { $0.id == String(parts[1]) }) else { continue }
            for run in CalendarMath.runs(list.sorted()) {
                guard let first = run.first, let last = run.last else { continue }
                out.append(AppleSyncSpan(typeID: type.id, title: type.name, first: first, last: last))
            }
        }
        return out.sorted { ($0.first, $0.typeID) < ($1.first, $1.typeID) }
    }

    /// An entry run as its Apple event.
    static func apple(_ span: AppleSyncSpan) -> AppleSyncFields {
        AppleSyncFields(day: span.first, lastDay: span.last, start: nil, end: nil, title: span.title, location: "", notes: "")
    }
}

/// One thing a sync does.
enum AppleSyncStep: Equatable {
    /// A copy of the Ohana event (a series with its rule) in Apple, linked afterwards.
    case createApple(OhanaSyncItem)
    /// The Apple event (by `localID`; a series as a whole) made like the Ohana event: Ohana's edit,
    /// an Apple edit put back (a viewer), or linking events that differ.
    case updateApple(OhanaSyncItem, appleID: String)
    /// The Ohana event and the Apple event are the same: only linked, with the occurrences as they
    /// stand after this sync.
    case link(OhanaSyncItem, AppleSyncEvent, exceptions: [Day: AppleSyncException])
    /// The Apple event (a series with its rule) imported into Ohana.
    case createOhana(AppleSyncEvent)
    /// The Ohana event (a series as a whole) made like the Apple event (its edit).
    case updateOhana(id: String, OhanaSyncFields, AppleSyncEvent)
    case deleteApple(appleID: String)
    case deleteOhana(id: String)
    /// One occurrence of a linked series, on one side, made like the other's.
    case updateAppleOccurrence(appleID: String, day: Day, OhanaSyncFields, ohanaID: String)
    case deleteAppleOccurrence(appleID: String, day: Day, ohanaID: String)
    case updateOhanaOccurrence(id: String, day: Day, OhanaSyncFields)
    case deleteOhanaOccurrence(id: String, day: Day)
    case createEntry(AppleSyncSpan)
    case deleteEntry(appleID: String)

    /// A change to a whole series: its occurrences are looked at again in another pass.
    var changesSeries: Bool {
        switch self {
        case let .createApple(o), let .updateApple(o, _): o.fields.rrule != nil
        case let .createOhana(a): a.fields.rrule != nil
        case let .updateOhana(_, fields, a): fields.rrule != nil || a.fields.rrule != nil
        default: false
        }
    }
}

struct AppleSyncPlan: Equatable {
    /// Links that stay (their occurrences as they stand after this sync).
    var keep: [AppleSyncLink] = []
    var steps: [AppleSyncStep] = []
    /// The Apple events of entry runs that stay.
    var keepEntries: [String] = []
    /// Ohana events left alone because so many of their Apple events were missing at once that the
    /// calendar more likely didn't load than that they were all deleted.
    var heldBack = 0

    /// A series was made or changed as a whole: another pass syncs its occurrences.
    var needsAnotherPass: Bool { steps.contains { $0.changesSeries } }
}

/// A linked Apple event outside the window.
enum AppleSyncLookup: Equatable {
    case found(AppleSyncEvent)
    case gone
}

enum AppleSyncPlanner {
    /// Deleting more Ohana events than this at once, and more than half the links, is held back.
    static let deletionLimit = 10

    /// What a sync does.
    /// - Parameters:
    ///   - ohana: all of the family's events, series with their occurrences around the window.
    ///   - apple: the Apple calendar's events around the window.
    ///   - lookup: a linked Apple event outside the window (or moved out of the calendar).
    ///   - spans: the entry runs in the window as they should be in Apple; nil: entries are not synced.
    ///   - entryIDs: the Apple events of entry runs the last sync made.
    static func plan(
        family: String, ohana: [OhanaSyncItem], apple: [AppleSyncEvent], window: ClosedRange<Day>,
        links: [AppleSyncLink], canEdit: Bool, spans: [AppleSyncSpan]?, entryIDs: Set<String>,
        lookup: (AppleSyncLink) -> AppleSyncLookup
    ) -> AppleSyncPlan {
        var plan = AppleSyncPlan()
        let ohanaByID = Dictionary(ohana.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let appleByID = Dictionary(apple.map { ($0.localID, $0) }, uniquingKeysWith: { a, _ in a })
        let appleByKey = Dictionary(apple.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var usedOhana = Set<String>()
        var usedApple = Set<String>()
        var deletions: [AppleSyncStep] = []
        var occurrenceSteps: [AppleSyncStep] = []

        // 1. Linked events: whichever side changed (or went) since the last sync.
        for link in links {
            let o = ohanaByID[link.ohanaID]
            let found = appleByID[link.appleID] ?? appleByKey[link.appleKey]
            // Both in the past: no longer synced (the links don't pile up).
            if let o, !o.inWindow, found?.inWindow != true, o.fields.date < window.lowerBound {
                usedOhana.insert(o.id)
                if let found { usedApple.insert(found.localID) }
                continue
            }
            let a: AppleSyncEvent?
            switch found.map({ .found($0) }) ?? lookup(link) {
            case let .found(event): a = event
            case .gone: a = nil
            }
            if let o { usedOhana.insert(o.id) }
            if let a { usedApple.insert(a.localID) }
            switch (o, a) {
            case (nil, nil):
                break
            case let (nil, a?):
                plan.steps.append(.deleteApple(appleID: a.localID))
            case let (o?, nil):
                // Deleted in Apple: in Ohana too (a viewer gets the copy again).
                if canEdit { deletions.append(.deleteOhana(id: o.id)) } else { plan.steps.append(.createApple(o)) }
            case let (o?, a?):
                let ohanaChanged = o.fields != link.ohana
                let appleChanged = a.fields != link.apple
                if ohanaChanged || (appleChanged && !canEdit) {
                    plan.steps.append(.updateApple(o, appleID: a.localID))
                } else if appleChanged {
                    let next = AppleSyncMapping.ohana(a.fields, current: link.ohana)
                    if next == o.fields {
                        let exceptions = occurrences(o, a, previous: link.exceptions, window: window, canEdit: canEdit,
                                                     steps: &occurrenceSteps)
                        plan.steps.append(.link(o, a, exceptions: exceptions))
                    } else {
                        plan.steps.append(.updateOhana(id: o.id, next, a))
                    }
                } else {
                    var kept = link
                    kept.exceptions = occurrences(o, a, previous: link.exceptions, window: window, canEdit: canEdit,
                                                  steps: &occurrenceSteps)
                    plan.keep.append(kept)
                }
            }
        }

        // Deleting many Ohana events at once is likelier a calendar that didn't load.
        if deletions.count > deletionLimit, deletions.count * 2 > links.count {
            plan.heldBack = deletions.count
            plan.keep += links.filter { link in deletions.contains(.deleteOhana(id: link.ohanaID)) }
        } else {
            plan.steps += deletions
        }

        // The rest of the Apple calendar: Ohana's copies (this device's or another's), entry runs,
        // and its own events.
        var copies: [String: [AppleSyncEvent]] = [:]
        var entries: [AppleSyncEvent] = []
        var natives: [AppleSyncEvent] = []
        for a in apple where !usedApple.contains(a.localID) {
            switch AppleSyncMark(a.url, family: family) {
            case let .event(id)?: copies[id, default: []].append(a)
            case .entry?: entries.append(a)
            case nil:
                if entryIDs.contains(a.localID) { entries.append(a) } else if !isOtherFamilys(a.url) { natives.append(a) }
            }
        }

        // 2. Apple's own events: linked to the event another device imported, or imported.
        var byExternal: [String: OhanaSyncItem] = [:]
        for o in ohana where !usedOhana.contains(o.id) {
            if let key = o.externalId { byExternal[key] = byExternal[key] ?? o }
        }
        for a in natives {
            if let o = byExternal[a.key], !usedOhana.contains(o.id) {
                usedOhana.insert(o.id)
                plan.steps.append(adopt(o, a, window: window, canEdit: canEdit, steps: &occurrenceSteps))
            } else if canEdit, a.inWindow {
                plan.steps.append(.createOhana(a))
            }
        }

        // 3. Ohana's events: linked to a copy another device made, or copied.
        for o in ohana where !usedOhana.contains(o.id) {
            if let copy = copies[o.id]?.first {
                usedOhana.insert(o.id)
                copies[o.id]?.removeFirst()
                plan.steps.append(adopt(o, copy, window: window, canEdit: canEdit, steps: &occurrenceSteps))
            } else if o.inWindow {
                plan.steps.append(.createApple(o))
            }
        }
        // Copies of events Ohana no longer has, or second copies.
        for a in copies.values.flatMap({ $0 }) {
            plan.steps.append(.deleteApple(appleID: a.localID))
        }
        plan.steps += occurrenceSteps

        // 4. Entry runs: the ones as they should be stay, the others go, the missing ones are made.
        var wanted = spans ?? []
        for a in entries {
            // A calendar that drops the link (some do) keeps the run by its day and title.
            let mark = AppleSyncMark(a.url, family: family)
            if let i = wanted.firstIndex(where: { (mark == nil || mark == .entry($0.typeID)) && AppleSyncMapping.apple($0) == a.fields }) {
                wanted.remove(at: i)
                plan.keepEntries.append(a.localID)
            } else {
                plan.steps.append(.deleteEntry(appleID: a.localID))
            }
        }
        plan.steps += wanted.map { .createEntry($0) }
        return plan
    }

    /// Linking two events found apart: as they are when they say the same, else Ohana's wins.
    private static func adopt(_ o: OhanaSyncItem, _ a: AppleSyncEvent, window: ClosedRange<Day>, canEdit: Bool,
                              steps: inout [AppleSyncStep]) -> AppleSyncStep {
        guard AppleSyncMapping.ohana(a.fields, current: o.fields) == o.fields else { return .updateApple(o, appleID: a.localID) }
        return .link(o, a, exceptions: occurrences(o, a, previous: [:], window: window, canEdit: canEdit, steps: &steps))
    }

    /// The occurrences of a linked series in the window, day by day: whichever side changed or
    /// deleted one since the last sync (Ohana's wins), as the steps that make the other side alike.
    /// Answers what they stand at afterwards (only the days that aren't as the rule makes them). An
    /// occurrence deleted in Apple can't come back there: then the two stay apart.
    static func occurrences(_ o: OhanaSyncItem, _ a: AppleSyncEvent, previous: [Day: AppleSyncException],
                            window: ClosedRange<Day>, canEdit: Bool, steps: inout [AppleSyncStep]) -> [Day: AppleSyncException] {
        guard o.fields.rrule != nil, a.fields.rrule != nil, let apple = a.occurrences else {
            return previous.filter { $0.key >= window.lowerBound }
        }
        var next: [Day: AppleSyncException] = [:]
        for day in Set(o.occurrences.keys).union(previous.keys).sorted() where window.contains(day) {
            // Not a day of the rule (anymore): forgotten.
            guard let ohanaNow = o.occurrences[day] else { continue }
            let last = previous[day] ?? AppleSyncException()
            let appleNow = apple[day] ?? .deleted
            var now = AppleSyncException(ohana: ohanaNow, apple: appleNow)
            let ohanaChanged = ohanaNow != last.ohana
            let appleChanged = appleNow != last.apple
            if ohanaChanged || (appleChanged && !canEdit) {
                switch ohanaNow {
                case .deleted:
                    if appleNow != .deleted {
                        steps.append(.deleteAppleOccurrence(appleID: a.localID, day: day, ohanaID: o.id))
                        now.apple = .deleted
                    }
                case let .changed(fields):
                    if appleNow != .deleted {
                        steps.append(.updateAppleOccurrence(appleID: a.localID, day: day, fields, ohanaID: o.id))
                        now.apple = .changed(AppleSyncMapping.apple(fields))
                    }
                case .normal:
                    if case .changed = appleNow, let fields = o.occurrenceFields[day] {
                        steps.append(.updateAppleOccurrence(appleID: a.localID, day: day, fields, ohanaID: o.id))
                        now.apple = .changed(AppleSyncMapping.apple(fields))
                    }
                }
            } else if appleChanged {
                switch appleNow {
                case .deleted:
                    if ohanaNow != .deleted {
                        steps.append(.deleteOhanaOccurrence(id: o.id, day: day))
                        now.ohana = .deleted
                    }
                case let .changed(fields):
                    if let current = o.occurrenceFields[day] {
                        let wanted = AppleSyncMapping.ohana(fields, current: current)
                        if wanted != current {
                            steps.append(.updateOhanaOccurrence(id: o.id, day: day, wanted))
                            now.ohana = .changed(wanted)
                        }
                    }
                case .normal:
                    break
                }
            }
            if now != AppleSyncException() { next[day] = now }
        }
        return next
    }

    /// Another family's copy (two families synced into one calendar): neither imported nor deleted.
    private static func isOtherFamilys(_ url: URL?) -> Bool {
        guard let url, url.scheme == DevicePairing.callbackScheme, url.host() == "f" else { return false }
        return url.path.contains("/calendar/")
    }
}

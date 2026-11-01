import CryptoKit
import Foundation

/// What the sync of the family's chores does to the chosen Reminders list, worked out from the
/// server's chores (GET /chores), the list's reminders (the open ones and those completed lately)
/// and what this device linked before (`links`). Pure: `ChoreReminders` reads the inputs and
/// applies the plan through `RemindersStore` and the server.
///
/// Written one way, server → Reminders; only a single chore's done state goes both ways. Each
/// reminder is titled like the chore (with " · {name}" when the list has everyone's), has its note
/// and carries the marker (`ChoreReminderMarker`) as its url, whose `v` is the fingerprint of what
/// was written. None of them repeats.
///
/// A single chore has one reminder, due on its day (with the time):
/// - it's the one this device linked, else one with the chore's marker (written on another
///   device sharing the list);
/// - an open reminder whose `v` isn't the chore's fingerprint anymore is written again;
/// - an open chore without a reminder gets one, unless this device linked one and the chore didn't
///   change since: the user deleted it, and it stays deleted;
/// - its done: what changed since the link's last `done` wins, the server when both did (they
///   agree then anyway); ticked in Reminders it's reported (`markDone`), done on the server the
///   reminder is completed (or opened again).
///
/// A repeating chore has a plain reminder per occurrence, made `appearance` (3 hours) before the
/// occurrence is due (its day at the time, or the day's start for one without a time: the
/// evening before at 21:00), from the server's `occurrences` around today:
/// - the current occurrence (the latest one that appeared) gets its reminder, unless it has one
///   (linked, or with the chore's marker for that day from another device) or this device linked
///   one before (deleted: it stays deleted);
/// - ticked off in Reminders, nothing goes to the server; missed ones (open, of days before today)
///   are left as they are;
/// - when the chore changed, the open ones this device linked of today and later are written
///   again, and removed when their day isn't an occurrence anymore.
///
/// An open reminder this device linked whose chore is gone, or out of the scope now, is removed;
/// other devices' reminders on a shared list are never removed. Links of occurrences more than
/// `keepDays` ago are forgotten.
struct ChoreReminderPlan: Equatable {
    /// What a reminder is given.
    struct Content: Equatable {
        var title: String
        var notes: String?
        var due: ReminderDue?
        var url: URL
    }

    struct Create: Equatable {
        /// The link's key (`ChoreReminderLink.key`).
        var key: String
        var choreID: String
        /// A repeating chore's occurrence; nil for a single chore.
        var occurrence: Day?
        var content: Content
        /// The fingerprint to link it with.
        var fingerprint: String
    }

    struct Update: Equatable {
        /// The reminder's id.
        var id: String
        var choreID: String
        var content: Content
    }

    /// A reminder to tick off (`done`) or open again.
    struct Completion: Equatable {
        var id: String
        var done: Bool
    }

    /// A single chore to report done (or not) to the server: ticked in Reminders.
    struct MarkDone: Equatable {
        var choreID: String
        var done: Bool
    }

    var creates: [Create] = []
    var updates: [Update] = []
    var completions: [Completion] = []
    /// Reminders to delete, by id.
    var removals: [String] = []
    var markDone: [MarkDone] = []
    /// The links to remember, by `ChoreReminderLink.key`; `creates` get theirs once added.
    var links: [String: ChoreReminderLink] = [:]
    /// When the next occurrence of a repeating chore in scope appears: the sync should run again
    /// then. Nil: none of the known occurrences is still to come.
    var nextAppearance: Date?

    /// How long before an occurrence is due its reminder is made.
    static let appearance: TimeInterval = 3 * 3600
    /// How long the links of past occurrences are kept.
    static let keepDays = 60

    /// Nothing to change in Reminders or on the server (`links` may still change).
    var changesNothing: Bool {
        creates.isEmpty && updates.isEmpty && completions.isEmpty && removals.isEmpty && markDone.isEmpty
    }

    /// `scope`: whose chores the list has (a `ChorePerson.id`); nil: everyone's. `today`: the day
    /// the chores were asked for (their `next`, `occurrences`); `now`: the moment, in `calendar`
    /// (the chores' times are wall-clock times there).
    static func make(familyID: String, chores: [Chore], reminders: [ReminderSnapshot],
                     links: [String: ChoreReminderLink], scope: String?, today: Day, now: Date,
                     calendar: Calendar = Day.calendar) -> ChoreReminderPlan {
        var plan = ChoreReminderPlan()
        let byID = Dictionary(reminders.map { ($0.id, $0) }) { first, _ in first }
        // This family's reminders by their chore and occurrence (nil: a single chore's).
        var markers: [String: ChoreReminderMarker] = [:]
        var byKey: [String: [ReminderSnapshot]] = [:]
        for reminder in reminders {
            guard let marker = ChoreReminderMarker(url: reminder.url), marker.familyID == familyID else { continue }
            markers[reminder.id] = marker
            byKey[ChoreReminderLink.key(choreID: marker.choreID, occurrence: marker.occurrence), default: []].append(reminder)
        }
        // The links by chore.
        var linksByChore: [String: [(key: String, link: ChoreReminderLink)]] = [:]
        for (key, link) in links {
            linksByChore[ChoreReminderLink.choreID(ofKey: key), default: []].append((key, link))
        }
        var used = Set<String>()
        var inScope = Set<String>()
        let forgetBefore = today.adding(days: -keepDays)

        for chore in chores where scope == nil || chore.assignee?.id == scope {
            inScope.insert(chore.id)
            guard chore.isRepeating else {
                single(chore, familyID: familyID, everyone: scope == nil, today: today, byID: byID, markers: markers,
                       marked: byKey[chore.id, default: []], linksByChore[chore.id, default: []],
                       used: &used, plan: &plan)
                continue
            }
            let print = fingerprint(chore, everyone: scope == nil)
            let occurrences = Set(chore.occurrences)
            // The current occurrence: the latest that appeared.
            let current = chore.occurrences.filter { appears($0, time: chore.time, calendar: calendar) <= now }.max()
            for occurrence in chore.occurrences {
                let at = appears(occurrence, time: chore.time, calendar: calendar)
                if at > now, plan.nextAppearance.map({ at < $0 }) ?? true { plan.nextAppearance = at }
            }
            var linked: [Day: ReminderSnapshot] = [:]
            for (key, link) in linksByChore[chore.id, default: []] {
                guard let occurrence = link.occurrence else {
                    // Written while the chore was single, or as the repeating reminder of before:
                    // replaced by the occurrences' own.
                    if let reminder = byID[link.reminderID], !reminder.isCompleted, !used.contains(reminder.id) {
                        used.insert(reminder.id)
                        plan.removals.append(reminder.id)
                    }
                    continue
                }
                let reminder = byID[link.reminderID].flatMap { used.contains($0.id) ? nil : $0 }
                if let reminder { used.insert(reminder.id) }
                if let reminder, !reminder.isCompleted, occurrence >= today {
                    guard occurrences.contains(occurrence) else {
                        // No occurrence anymore (the rule changed).
                        plan.removals.append(reminder.id)
                        continue
                    }
                    var link = link
                    if markers[reminder.id]?.fingerprint != print {
                        plan.updates.append(Update(id: reminder.id, choreID: chore.id,
                                                   content: content(familyID: familyID, chore: chore, occurrence: occurrence,
                                                                    everyone: scope == nil, fingerprint: print)))
                        link.fingerprint = print
                    }
                    plan.links[key] = link
                    linked[occurrence] = reminder
                    continue
                }
                if let reminder { linked[occurrence] = reminder }
                // Kept while it can matter: recent, or an occurrence the server still names.
                if occurrence >= forgetBefore || occurrences.contains(occurrence) { plan.links[key] = link }
            }
            guard let current else { continue }
            // Not one that was over before the chore was made, nor the last of a series that ended
            // before today: neither is to be done anymore.
            if current < today, chore.next == nil
                || Date.server(chore.createdAt).map({ current < Day($0, calendar: calendar) }) == true { continue }
            let key = ChoreReminderLink.key(choreID: chore.id, occurrence: current)
            // Linked already (and maybe deleted since: then it stays so).
            if links[key] != nil || linked[current] != nil { continue }
            let marked = byKey[key, default: []].filter { !used.contains($0.id) }
            if let match = marked.first(where: { !$0.isCompleted }) ?? marked.first {
                // Written on another device sharing the list: this device's now too.
                used.insert(match.id)
                var written = markers[match.id]?.fingerprint ?? ""
                if !match.isCompleted, current >= today, written != print {
                    plan.updates.append(Update(id: match.id, choreID: chore.id,
                                               content: content(familyID: familyID, chore: chore, occurrence: current,
                                                                everyone: scope == nil, fingerprint: print)))
                    written = print
                }
                plan.links[key] = ChoreReminderLink(reminderID: match.id, done: false, fingerprint: written, occurrence: current)
                continue
            }
            plan.creates.append(Create(key: key, choreID: chore.id, occurrence: current,
                                       content: content(familyID: familyID, chore: chore, occurrence: current,
                                                        everyone: scope == nil, fingerprint: print),
                                       fingerprint: print))
        }

        // Ohana's reminders this device linked, still open, whose chore is gone or out of scope.
        for (key, link) in links where !inScope.contains(ChoreReminderLink.choreID(ofKey: key)) {
            guard let reminder = byID[link.reminderID], !reminder.isCompleted, !used.contains(reminder.id) else { continue }
            used.insert(reminder.id)
            plan.removals.append(reminder.id)
        }
        plan.removals.sort()
        plan.creates.sort { $0.key < $1.key }
        plan.updates.sort { $0.id < $1.id }
        return plan
    }

    /// A single chore: its one reminder (see the type's rules).
    private static func single(_ chore: Chore, familyID: String, everyone: Bool, today: Day,
                               byID: [String: ReminderSnapshot],
                               markers: [String: ChoreReminderMarker], marked: [ReminderSnapshot],
                               _ choreLinks: [(key: String, link: ChoreReminderLink)], used: inout Set<String>,
                               plan: inout ChoreReminderPlan) {
        let print = fingerprint(chore, everyone: everyone)
        let content = content(familyID: familyID, chore: chore, occurrence: nil, everyone: everyone, fingerprint: print)
        var link: ChoreReminderLink?
        for (key, other) in choreLinks {
            guard let occurrence = other.occurrence else {
                link = other
                continue
            }
            // An occurrence's, from when the chore repeated: open ones of today and later aren't
            // due anymore, older ones are left (and their links kept a while, like a repeating
            // chore's).
            if let reminder = byID[other.reminderID], !reminder.isCompleted, !used.contains(reminder.id),
               occurrence >= today {
                used.insert(reminder.id)
                plan.removals.append(reminder.id)
            } else if occurrence >= today.adding(days: -keepDays) {
                plan.links[key] = other
            }
        }
        let taken = used
        let linked = link.flatMap { byID[$0.reminderID] }.flatMap { taken.contains($0.id) ? nil : $0 }
        let others = marked.filter { !taken.contains($0.id) }
        let match = linked ?? others.first { !$0.isCompleted } ?? others.first

        guard let match else {
            if let link, link.fingerprint == print || chore.done {
                // Deleted in Reminders (or done: nothing to write now): left so.
                plan.links[chore.id] = link
            } else if !chore.done {
                plan.creates.append(Create(key: chore.id, choreID: chore.id, occurrence: nil, content: content,
                                           fingerprint: print))
            }
            return
        }
        used.insert(match.id)
        var done = link?.done ?? false
        if chore.done != done {
            // Changed on the server (and maybe in Reminders too: then they agree).
            if match.isCompleted != chore.done { plan.completions.append(Completion(id: match.id, done: chore.done)) }
            done = chore.done
        } else if match.isCompleted != done {
            plan.markDone.append(MarkDone(choreID: chore.id, done: match.isCompleted))
            done = match.isCompleted
        }
        let markerFingerprint = markers[match.id]?.fingerprint
        var written = markerFingerprint ?? link?.fingerprint ?? ""
        // Open (after the changes above) and written from another version of the chore.
        if !done, markerFingerprint != print {
            plan.updates.append(Update(id: match.id, choreID: chore.id, content: content))
            written = print
        }
        plan.links[chore.id] = ChoreReminderLink(reminderID: match.id, done: done, fingerprint: written)
    }

    /// When an occurrence's reminder is made: `appearance` before it's due (the day at `time`, or
    /// the day's start).
    static func appears(_ day: Day, time: String?, calendar: Calendar = Day.calendar) -> Date {
        due(day, time: time, calendar: calendar).addingTimeInterval(-appearance)
    }

    /// When an occurrence is due: the day at `time` ("HH:MM"), or the day's start.
    static func due(_ day: Day, time: String?, calendar: Calendar = Day.calendar) -> Date {
        var components = DateComponents(year: day.year, month: day.month, day: day.day)
        if let clock = time.flatMap(Self.time) {
            components.hour = clock.hour
            components.minute = clock.minute
        }
        return calendar.date(from: components) ?? calendar.startOfDay(for: day.date)
    }

    /// The title as written: with " · {name}" when the list has everyone's.
    static func title(_ chore: Chore, everyone: Bool) -> String {
        guard everyone, let assignee = chore.assignee else { return chore.title }
        return "\(chore.title) · \(assignee.name)"
    }

    /// The fingerprint of what a chore's reminders are given.
    static func fingerprint(_ chore: Chore, everyone: Bool) -> String {
        let note = chore.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint(title: title(chore, everyone: everyone), notes: note, day: chore.isRepeating ? nil : chore.day,
                           time: chore.time, rule: chore.rule)
    }

    /// What a chore's reminder is given: a single chore's (`occurrence` nil), due on its day, or an
    /// occurrence's, due that day; at the chore's time.
    static func content(familyID: String, chore: Chore, occurrence: Day?, everyone: Bool,
                        fingerprint print: String? = nil) -> Content {
        let note = chore.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let print = print ?? fingerprint(chore, everyone: everyone)
        let due = ReminderDue(day: occurrence ?? chore.day, time: chore.time.flatMap(Self.time))
        let url = ChoreReminderMarker(familyID: familyID, choreID: chore.id, fingerprint: print, occurrence: occurrence).url
        return Content(title: title(chore, everyone: everyone), notes: note.isEmpty ? nil : note, due: due, url: url)
    }

    /// A short hash of what's written (the first 8 hex digits of its SHA-256): the title as
    /// written, the note, a single chore's day, the time, the rule. A repeating chore's reminders
    /// are each due on their own day, which isn't in it.
    static func fingerprint(title: String, notes: String, day: Day?, time: String?, rule: RepeatRule?) -> String {
        let text = [title, notes, day?.description ?? "", time ?? "", rule?.string ?? ""].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// "HH:MM" as a due time.
    static func time(_ text: String) -> ReminderDue.Time? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return ReminderDue.Time(hour: parts[0], minute: parts[1])
    }
}

/// What this device remembers of a chore's reminder: a single chore's (by the chore id), or one
/// of a repeating chore's occurrences (by "{choreId}@{YYYY-MM-DD}", `key`).
struct ChoreReminderLink: Codable, Hashable {
    /// The reminder (`calendarItemIdentifier`).
    var reminderID: String
    /// A single chore's done as last seen on both sides.
    var done: Bool
    /// The fingerprint it was written with (`ChoreReminderMarker.fingerprint`).
    var fingerprint: String
    /// The occurrence of a repeating chore it's for; nil: a single chore's (or, from before
    /// occurrences had their own, a repeating reminder's).
    var occurrence: Day?

    init(reminderID: String, done: Bool, fingerprint: String, occurrence: Day? = nil) {
        self.reminderID = reminderID
        self.done = done
        self.fingerprint = fingerprint
        self.occurrence = occurrence
    }

    /// The key a link is kept under.
    static func key(choreID: String, occurrence: Day?) -> String {
        occurrence.map { "\(choreID)@\($0)" } ?? choreID
    }

    /// The chore of a link's key.
    static func choreID(ofKey key: String) -> String {
        key.firstIndex(of: "@").map { String(key[..<$0]) } ?? key
    }
}

/// What marks a reminder as a chore's: its url,
/// `ohana://f/{familyId}/chores/{choreId}?v={fingerprint}[&o={YYYY-MM-DD}]`. `v` is a short hash of
/// what was written, so the sync sees when the chore changed since; `o` the occurrence of a
/// repeating chore it's for. Opening the url shows the chore (`AppRoute.parse`).
struct ChoreReminderMarker: Hashable {
    var familyID: String
    var choreID: String
    var fingerprint: String
    /// A repeating chore's occurrence; nil for a single chore.
    var occurrence: Day?

    var url: URL {
        var components = URLComponents()
        components.scheme = "ohana"
        components.host = "f"
        components.path = "/\(familyID)/chores/\(choreID)"
        components.queryItems = [URLQueryItem(name: "v", value: fingerprint)]
            + (occurrence.map { [URLQueryItem(name: "o", value: $0.description)] } ?? [])
        return components.url!
    }

    init(familyID: String, choreID: String, fingerprint: String, occurrence: Day? = nil) {
        self.familyID = familyID
        self.choreID = choreID
        self.fingerprint = fingerprint
        self.occurrence = occurrence
    }

    /// The marker of a reminder's url; nil for any other url.
    init?(url: URL?) {
        guard let url, url.scheme == "ohana", url.host() == "f",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        let items = components.queryItems ?? []
        guard parts.count == 3, parts[1] == "chores", !parts[2].isEmpty,
              let fingerprint = items.first(where: { $0.name == "v" })?.value else { return nil }
        let occurrence = items.first(where: { $0.name == "o" })?.value
        // An `o` that isn't a day: not one of Ohana's.
        if let occurrence, Day(occurrence) == nil || occurrence.count != 10 { return nil }
        self.init(familyID: parts[0], choreID: parts[2], fingerprint: fingerprint, occurrence: occurrence.flatMap(Day.init))
    }
}

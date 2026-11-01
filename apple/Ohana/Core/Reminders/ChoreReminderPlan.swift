import CryptoKit
import Foundation

/// What the sync of the family's chores does to the chosen Reminders list, worked out from the
/// server's chores (GET /chores), the list's reminders (the open ones and those completed lately)
/// and what this device linked before (`links`). Pure: `ChoreReminders` reads the inputs and
/// applies the plan through `RemindersStore` and the server.
///
/// One reminder per chore in scope (everyone's, or one person's), written one way, server →
/// Reminders; only a single chore's done state goes both ways:
/// - the reminder is titled like the chore (with " · {name}" when the list has everyone's), has
///   its note, is due on `next` (with the time), repeats like it, and carries the marker
///   (`ChoreReminderMarker`) as its url, whose `v` is the fingerprint of what was written;
/// - a chore's reminder is the one this device linked, else one with the chore's marker (written
///   on another device sharing the list); for a repeating chore only an open one counts:
///   completing a repeating reminder leaves a completed copy behind and moves the open one on;
/// - an open reminder whose `v` isn't the chore's fingerprint anymore is written again (the
///   chore was changed);
/// - a chore without a reminder gets one (repeating, or single and open), unless this device
///   linked one and the chore didn't change since: the user deleted it, and it stays deleted;
/// - a single chore's done: what changed since the link's last `done` wins, the server when both
///   did (they agree then anyway); ticked in Reminders it's reported (`markDone`), done on the
///   server the reminder is completed (or opened again);
/// - an open reminder this device linked whose chore is gone, or out of the scope now, is removed;
///   other devices' reminders on a shared list are never removed.
struct ChoreReminderPlan: Equatable {
    /// What a reminder is given.
    struct Content: Equatable {
        var title: String
        var notes: String?
        var due: ReminderDue?
        var rule: RepeatRule?
        var url: URL
    }

    struct Create: Equatable {
        var choreID: String
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
    /// The links to remember, by chore id; `creates` get theirs once added.
    var links: [String: ChoreReminderLink] = [:]

    /// Nothing to change in Reminders or on the server (`links` may still change).
    var changesNothing: Bool {
        creates.isEmpty && updates.isEmpty && completions.isEmpty && removals.isEmpty && markDone.isEmpty
    }

    /// `scope`: whose chores the list has (a `ChorePerson.id`); nil: everyone's. `today`: the day
    /// the chores were asked for (their `next`).
    static func make(familyID: String, chores: [Chore], reminders: [ReminderSnapshot],
                     links: [String: ChoreReminderLink], scope: String?, today: Day) -> ChoreReminderPlan {
        var plan = ChoreReminderPlan()
        let byID = Dictionary(reminders.map { ($0.id, $0) }) { first, _ in first }
        // This family's reminders by their chore.
        var markers: [String: ChoreReminderMarker] = [:]
        var byChore: [String: [ReminderSnapshot]] = [:]
        for reminder in reminders {
            guard let marker = ChoreReminderMarker(url: reminder.url), marker.familyID == familyID else { continue }
            markers[reminder.id] = marker
            byChore[marker.choreID, default: []].append(reminder)
        }
        var used = Set<String>()
        var inScope = Set<String>()

        for chore in chores where scope == nil || chore.assignee?.id == scope {
            inScope.insert(chore.id)
            let (content, fingerprint) = Self.content(familyID: familyID, chore: chore, everyone: scope == nil)
            let link = links[chore.id]
            // A repeating chore's completed reminders are the copies of occurrences ticked off.
            let candidate = { (r: ReminderSnapshot) in !used.contains(r.id) && (!chore.isRepeating || !r.isCompleted) }
            let linked = link.flatMap { byID[$0.reminderID] }.flatMap { candidate($0) ? $0 : nil }
            let marked = byChore[chore.id, default: []].filter(candidate)
            let match = linked ?? marked.first { !$0.isCompleted } ?? marked.first
            // Something to write: a repeating chore whose series goes on, an open single one.
            let wanted = chore.isRepeating ? chore.next != nil : !chore.done

            guard let match else {
                if let link, link.fingerprint == fingerprint || !wanted {
                    // Deleted in Reminders (or nothing to write now): left so.
                    plan.links[chore.id] = link
                } else if wanted {
                    plan.creates.append(Create(choreID: chore.id, content: content, fingerprint: fingerprint))
                }
                continue
            }
            used.insert(match.id)
            var done = link?.done ?? false
            if !chore.isRepeating {
                if chore.done != done {
                    // Changed on the server (and maybe in Reminders too: then they agree).
                    if match.isCompleted != chore.done { plan.completions.append(Completion(id: match.id, done: chore.done)) }
                    done = chore.done
                } else if match.isCompleted != done {
                    plan.markDone.append(MarkDone(choreID: chore.id, done: match.isCompleted))
                    done = match.isCompleted
                }
            }
            let markerFingerprint = markers[match.id]?.fingerprint
            var written = markerFingerprint ?? link?.fingerprint ?? ""
            // Open (after the changes above) and written from another version of the chore.
            if wanted, chore.isRepeating || !done, markerFingerprint != fingerprint {
                plan.updates.append(Update(id: match.id, choreID: chore.id, content: content))
                written = fingerprint
            }
            plan.links[chore.id] = ChoreReminderLink(reminderID: match.id, done: done, fingerprint: written)
        }

        // Ohana's reminders this device linked, still open, whose chore is gone or out of scope.
        for (choreID, link) in links where !inScope.contains(choreID) {
            guard let reminder = byID[link.reminderID], !reminder.isCompleted, !used.contains(reminder.id) else { continue }
            plan.removals.append(reminder.id)
        }
        plan.removals.sort()
        return plan
    }

    /// What the chore's reminder is given, and the fingerprint in its marker.
    static func content(familyID: String, chore: Chore, everyone: Bool) -> (Content, String) {
        var title = chore.title
        if everyone, let assignee = chore.assignee { title += " · \(assignee.name)" }
        let note = chore.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Due next: a single chore on its day (done too), a repeating one on its next occurrence.
        let dueDay = chore.isRepeating ? chore.next : chore.day
        let due = dueDay.map { ReminderDue(day: $0, time: chore.time.flatMap(Self.time)) }
        let rule = chore.rule
        let print = fingerprint(title: title, notes: note, day: chore.day, time: chore.time, rule: rule)
        let url = ChoreReminderMarker(familyID: familyID, choreID: chore.id, fingerprint: print).url
        return (Content(title: title, notes: note.isEmpty ? nil : note, due: due, rule: rule, url: url), print)
    }

    /// A short hash of what's written (the first 8 hex digits of its SHA-256): the title as
    /// written, the note, the day and time, the rule. A repeating chore counts by its first day,
    /// not `next`: its reminder moves on by itself in Reminders, and isn't written again only
    /// because an occurrence passed.
    static func fingerprint(title: String, notes: String, day: Day, time: String?, rule: RepeatRule?) -> String {
        let text = [title, notes, day.description, time ?? "", rule?.string ?? ""].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// "HH:MM" as a due time.
    static func time(_ text: String) -> ReminderDue.Time? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return ReminderDue.Time(hour: parts[0], minute: parts[1])
    }
}

/// What this device remembers of a chore's reminder.
struct ChoreReminderLink: Codable, Hashable {
    /// The reminder (`calendarItemIdentifier`).
    var reminderID: String
    /// A single chore's done as last seen on both sides.
    var done: Bool
    /// The fingerprint it was written with (`ChoreReminderMarker.fingerprint`).
    var fingerprint: String
}

/// What marks a reminder as a chore's: its url, `ohana://f/{familyId}/chores/{choreId}?v={fingerprint}`.
/// `v` is a short hash of what was written, so the sync sees when the chore changed since.
/// Opening the url shows the chore (`AppRoute.parse`).
struct ChoreReminderMarker: Hashable {
    var familyID: String
    var choreID: String
    var fingerprint: String

    var url: URL {
        var components = URLComponents()
        components.scheme = "ohana"
        components.host = "f"
        components.path = "/\(familyID)/chores/\(choreID)"
        components.queryItems = [URLQueryItem(name: "v", value: fingerprint)]
        return components.url!
    }

    init(familyID: String, choreID: String, fingerprint: String) {
        self.familyID = familyID
        self.choreID = choreID
        self.fingerprint = fingerprint
    }

    /// The marker of a reminder's url; nil for any other url.
    init?(url: URL?) {
        guard let url, url.scheme == "ohana", url.host() == "f",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard parts.count == 3, parts[1] == "chores", !parts[2].isEmpty,
              let fingerprint = components.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        self.init(familyID: parts[0], choreID: parts[2], fingerprint: fingerprint)
    }
}

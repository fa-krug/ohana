import Foundation

/// What the shopping sync does to the chosen Reminders list, worked out from what the meal plan
/// needs (`ShoppingDay`s from the server), the list's reminders (the open ones and those completed
/// lately) and the items this device wrote before (`written`). Pure: `ShoppingReminders` reads
/// the inputs and applies the plan through `RemindersStore`.
///
/// The sync only goes one way, server → Reminders, and never fights the user:
/// - every item of a shopping day from today on is a reminder, titled "150 g Tomato", due on the
///   day (no time), with the item's marker as its url (`ShoppingReminderMarker`);
/// - an item is matched to a reminder by the marker's path ("{date}/{key}"), else by the due day
///   and the title (written on another device, its url lost);
/// - a matched reminder that's done is left alone; an open one is updated only when the quantity
///   changed and its title is still the one Ohana gave it;
/// - an item without a reminder is added, unless this device wrote it before (`written`): the user
///   deleted it, and it stays deleted;
/// - an open reminder Ohana wrote for this family, due from today on, whose item the plan no longer
///   needs (or that repeats a matched one), is removed while its title is still Ohana's;
/// - `written` forgets the days before today.
struct ShoppingReminderPlan: Equatable {
    struct Create: Equatable {
        var title: String
        var due: Day
        var url: URL
    }

    struct Update: Equatable {
        var id: String
        var title: String
        var url: URL
    }

    var creates: [Create] = []
    var updates: [Update] = []
    /// Reminders to delete, by id.
    var removals: [String] = []
    /// The paths ("{date}/{key}") to remember as written.
    var written: Set<String> = []

    /// Nothing to change in Reminders (`written` may still change).
    var changesNothing: Bool { creates.isEmpty && updates.isEmpty && removals.isEmpty }

    static func make(familyID: String, days: [ShoppingDay], reminders: [ReminderSnapshot], written: Set<String>,
                     today: Day, locale: Locale = .current) -> ShoppingReminderPlan {
        var plan = ShoppingReminderPlan()
        // Ohana's reminders by their item; a list can hold several families' (any family's marker
        // keeps a reminder out of the matching by title).
        var markers: [String: ShoppingReminderMarker] = [:]
        var byPath: [String: [ReminderSnapshot]] = [:]
        for reminder in reminders {
            guard let marker = ShoppingReminderMarker(url: reminder.url) else { continue }
            markers[reminder.id] = marker
            if marker.familyID == familyID { byPath[marker.path, default: []].append(reminder) }
        }
        var used = Set<String>()
        var needed = Set<String>()
        var kept = Set(written.filter { (Day(String($0.prefix(10))) ?? today) >= today })

        for day in days where day.date >= today {
            for item in day.items {
                let path = ShoppingReminderMarker.path(date: day.date, key: item.key)
                guard needed.insert(path).inserted else { continue }
                let label = item.label(locale: locale)
                // A done one first: of two copies (written by two devices at once), the one ticked off.
                let byMarker = byPath[path, default: []].filter { !used.contains($0.id) }
                let match = byMarker.first(where: \.isCompleted) ?? byMarker.first ?? reminders.first { r in
                    !used.contains(r.id) && markers[r.id] == nil && r.due?.day == day.date && r.title == label
                }
                guard let match else {
                    if !kept.contains(path) {
                        let marker = ShoppingReminderMarker(familyID: familyID, date: day.date, key: item.key,
                                                            quantity: item.quantity, title: label)
                        plan.creates.append(Create(title: label, due: day.date, url: marker.url))
                        kept.insert(path)
                    }
                    continue
                }
                used.insert(match.id)
                // Seen in Reminders: should the user delete it, it isn't brought back.
                kept.insert(path)
                guard !match.isCompleted, var marker = markers[match.id], marker.quantity != item.quantity,
                      match.title == marker.title else { continue }
                marker.quantity = item.quantity
                marker.title = label
                plan.updates.append(Update(id: match.id, title: label, url: marker.url))
            }
        }

        for reminder in reminders where !used.contains(reminder.id) && !reminder.isCompleted {
            guard let marker = markers[reminder.id], marker.familyID == familyID,
                  (reminder.due?.day ?? marker.date) >= today, reminder.title == marker.title
            else { continue }
            plan.removals.append(reminder.id)
            // Taken away by Ohana, not the user: may come back when the plan needs it again.
            if !needed.contains(marker.path) { kept.remove(marker.path) }
        }
        plan.written = kept
        return plan
    }
}

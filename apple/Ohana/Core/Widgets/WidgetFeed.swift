import Foundation

// What the Home Screen and Lock Screen widgets (apple/OhanaWidgets) show. Compiled into the app
// and the widget extension. The widgets show the family the app shows: the extension reads the
// server, token and family from the Keychain (`SharedConnection`), loads that family's overview
// and keeps the last one (`WidgetSnapshot`, `WidgetStore`).

/// The family's overview (GET /overview) cut down to what the widgets show: today and tomorrow,
/// tonight's dinner, the shopping list and the appointments the searches found.
struct WidgetSnapshot: Codable, Hashable, Sendable {
    /// One line of a day: a run of a calendar type, an event, a birthday.
    struct Item: Codable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case run, event, birthday }

        var kind: Kind
        var id: String
        var day: Day
        /// The type's name, "Title · Person" of an event, the name of whose birthday it is.
        var title: String
        /// "HH:MM"; nil for all day (always for runs and birthdays), and on the later days of an
        /// event that spans days.
        var start: String? = nil
        /// "HH:MM" on this day; for an event that spans days only on its last.
        var end: String? = nil
        /// The event goes on after this day (it spans days): it isn't over today.
        var continues: Bool? = nil
        /// A calendar type's "#rrggbb".
        var color: String? = nil
        /// An event booked from an appointment search.
        var isAppointment = false
        /// The age a birthday's person turns.
        var age: Int? = nil

        var isTimed: Bool { start != nil }
    }

    /// Today's meal (server/lib/meals/queries/meal-plan.ts `MealsSummary.today`).
    struct Dinner: Codable, Hashable, Sendable {
        var recipeID: String
        var title: String
        var isLeftover: Bool
    }

    struct Shopping: Codable, Hashable, Sendable {
        var listID: String
        var date: Day?
        var open: Int
        var total: Int

        /// The share already bought, 0…1.
        var progress: Double { total > 0 ? Double(total - open) / Double(total) : 0 }
    }

    /// The earliest appointment a search found.
    struct Find: Codable, Hashable, Sendable, Identifiable {
        var searchID: String
        var searchName: String
        var resultID: Int
        var doctorName: String
        var slot: Date
        /// How many doctors the search's latest run found.
        var doctors: Int

        var id: String { searchID }
    }

    var familyID: String
    var loadedAt: Date
    /// The day the overview was loaded for; `items` hold it and the day after.
    var today: Day
    var items: [Item]
    /// Names of today's "away" types (no meal is planned then).
    var awayToday: [String]
    var dinner: Dinner?
    var shopping: Shopping?
    /// Of the enabled searches, by slot (earliest first); slots already past are left out.
    var finds: [Find]
    var mealsEnabled = true
    var appointmentsEnabled = true

    /// Whether the snapshot knows `day` (today or tomorrow of when it was loaded).
    func covers(_ day: Day) -> Bool { day == today || day == today.adding(days: 1) }

    /// The lines of `day` (nil when the snapshot doesn't know it): runs and birthdays, then the
    /// events by time. On the day `now` is in, events already over are left out.
    func items(on day: Day, now: Date = Date()) -> [Item]? {
        guard covers(day) else { return nil }
        let isToday = day == Day(now)
        return items.filter { item in
            guard item.day == day else { return false }
            guard isToday, let end = Self.endDate(of: item) else { return true }
            return end > now
        }
    }

    /// Tonight's dinner when `day` is the day it was loaded for.
    func dinner(on day: Day) -> Dinner? { day == today ? dinner : nil }

    func away(on day: Day) -> [String] { day == today ? awayToday : [] }

    /// Finds whose slot is still to come.
    func finds(after now: Date) -> [Find] { finds.filter { $0.slot > now } }

    /// When a widget's look changes without new data: an event of today ending, midnight.
    func changes(after now: Date) -> [Date] {
        let today = Day(now)
        let ends = items.filter { $0.day == today }.compactMap(Self.endDate(of:)).filter { $0 > now }
        let midnight = Day.calendar.startOfDay(for: today.adding(days: 1).date)
        let slots = finds.map(\.slot).filter { $0 > now }
        return Array(Set(ends + slots + [midnight])).sorted()
    }

    /// The end of a timed event on its day: its `end`, else an hour after its start; nil while it
    /// goes on to another day. The last day of one that spans days ends at its `end`.
    static func endDate(of item: Item) -> Date? {
        guard item.continues != true else { return nil }
        guard let start = item.start, let begin = date(item.day, start) else { return item.end.flatMap { date(item.day, $0) } }
        if let end = item.end, let date = date(item.day, end), date > begin { return date }
        return begin.addingTimeInterval(3600)
    }

    /// A wall-clock "HH:MM" on `day`, in the device's time zone.
    static func date(_ day: Day, _ time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Day.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                      hour: parts[0], minute: parts[1]))
    }
}

extension WidgetSnapshot {
    /// GET /api/v1/families/{id}/overview for `today` (server/lib/families/app-routes.ts).
    static func overviewURL(server: URL, familyID: String, today: Day) -> URL {
        server.appending(path: "api/v1/families/\(familyID)/overview")
            .appending(queryItems: [URLQueryItem(name: "today", value: today.description)])
    }

    /// The snapshot of GET /overview's answer (server/lib/families/dashboard.ts `Dashboard`);
    /// `disabledModules` are the modules the server has off (`ServerInfo`), whose widgets say so.
    init(overview data: Data, familyID: String, disabledModules: [String] = [], loadedAt: Date = Date()) throws {
        let wire = try JSONDecoder().decode(OverviewWire.self, from: data)
        self.init(wire, familyID: familyID, disabledModules: disabledModules, loadedAt: loadedAt)
    }

    private init(_ wire: OverviewWire, familyID: String, disabledModules: [String], loadedAt: Date) {
        let today = wire.today
        let days = [today, today.adding(days: 1)]
        var items: [Item] = []
        for day in days {
            var allDay: [Item] = []
            for case let .entry(from, to, name, color) in wire.upcoming where from <= day && day <= to {
                allDay.append(Item(kind: .run, id: "run|\(name)|\(from)|\(day)", day: day, title: name, color: color))
            }
            for birthday in wire.birthdays where birthday.day == day {
                allDay.append(Item(kind: .birthday, id: "birthday|\(birthday.name)|\(day)", day: day,
                                   title: birthday.name, age: birthday.age))
            }
            // An event that spans days shows on each of them: its start on the first, its end on the last.
            // Tomorrow's come from `tomorrowEvents` (an older server: the ones of today and coming up).
            var seen = Set<String>()
            let candidates = day == today ? wire.todayEvents
                : wire.tomorrowEvents ?? (wire.todayEvents + wire.upcoming.compactMap { if case let .event(event) = $0 { event } else { nil } })
            let events = candidates.filter { $0.date <= day && day <= $0.lastDay && seen.insert($0.uid).inserted }
            let eventItems = events.map { event in
                Item(kind: .event, id: "event|\(event.uid)", day: day,
                     title: event.person.isEmpty ? event.title : "\(event.title) · \(event.person)",
                     start: day == event.date ? event.start : nil,
                     end: day == event.lastDay ? event.end : nil,
                     continues: day < event.lastDay ? true : nil,
                     isAppointment: event.searchId != nil)
            }
            // All-day events with the runs; timed ones by their start.
            items += allDay + eventItems.filter { !$0.isTimed }
            items += eventItems.filter(\.isTimed).sorted { ($0.start ?? "") < ($1.start ?? "") }
        }
        let finds = (wire.searches ?? []).compactMap { search -> Find? in
            guard search.enabled, let first = search.first, let slot = Date.server(first.slot), slot > loadedAt else {
                return nil
            }
            return Find(searchID: search.id, searchName: search.name, resultID: first.resultId,
                        doctorName: first.doctorName, slot: slot, doctors: search.doctors)
        }
        self.init(
            familyID: familyID,
            loadedAt: loadedAt,
            today: today,
            items: items,
            awayToday: wire.awayToday,
            dinner: wire.meals?.today.map { Dinner(recipeID: $0.recipeId, title: $0.recipeTitle, isLeftover: $0.isLeftover) },
            shopping: wire.meals?.shopping.map { Shopping(listID: $0.id, date: $0.shoppingDate, open: $0.open, total: $0.total) },
            finds: finds.sorted { $0.slot < $1.slot },
            mealsEnabled: !disabledModules.contains("meals"),
            appointmentsEnabled: !disabledModules.contains("appointments")
        )
    }
}

/// The parts of GET /overview the widgets use (the app's `OverviewDashboard` has all of it).
private struct OverviewWire: Decodable {
    struct Event: Decodable {
        let id: String
        /// The original day of an occurrence of a repeating event.
        let occurrence: Day?
        let date: Day
        /// The last day of one that spans days.
        let endDate: Day?
        let start: String?
        let end: String?
        let title: String
        let person: String
        let searchId: String?

        var lastDay: Day { max(endDate ?? date, date) }
        var uid: String { occurrence.map { "\(id)@\($0)" } ?? id }
    }

    enum Upcoming: Decodable {
        case entry(from: Day, to: Day, name: String, color: String)
        case event(Event)
        case other

        private enum Keys: String, CodingKey { case kind, date, to, name, color, event }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "entry":
                self = .entry(from: try c.decode(Day.self, forKey: .date), to: try c.decode(Day.self, forKey: .to),
                              name: try c.decode(String.self, forKey: .name),
                              color: try c.decode(String.self, forKey: .color))
            case "event":
                self = .event(try c.decode(Event.self, forKey: .event))
            default:
                self = .other
            }
        }
    }

    struct Meals: Decodable {
        struct Today: Decodable {
            let recipeId: String
            let recipeTitle: String
            let isLeftover: Bool
        }

        struct Shopping: Decodable {
            let id: String
            let shoppingDate: Day?
            let open: Int
            let total: Int
        }

        let today: Today?
        let shopping: Shopping?
    }

    struct Search: Decodable {
        struct First: Decodable {
            let resultId: Int
            let doctorName: String
            let slot: String
        }

        let id: String
        let name: String
        let enabled: Bool
        let first: First?
        let doctors: Int
    }

    struct Birthday: Decodable {
        let day: Day
        let name: String
        let age: Int
    }

    let today: Day
    let awayToday: [String]
    let todayEvents: [Event]
    /// The occurrences on tomorrow, ones that started before it too.
    let tomorrowEvents: [Event]?
    let upcoming: [Upcoming]
    let meals: Meals?
    let searches: [Search]?
    let birthdays: [Birthday]
}

/// What the widgets keep: the modules the server has off (written by the app, in the Keychain
/// like `SharedConnection`, so no App Group is needed) and the last snapshot (the extension's own,
/// in its container's Application Support).
enum WidgetStore {
    /// The widgets' kinds.
    static let todayKind = "de.fa-krug.Ohana.today"
    static let tomorrowKind = "de.fa-krug.Ohana.tomorrow"
    static let dinnerKind = "de.fa-krug.Ohana.dinner"
    static let shoppingKind = "de.fa-krug.Ohana.shopping"
    static let appointmentKind = "de.fa-krug.Ohana.appointment"

    /// The Keychain account (service `de.fa-krug.Ohana`).
    private static let modulesAccount = "widgetDisabledModules"

    static func loadDisabledModules() -> [String] {
        (Keychain.load(modulesAccount) ?? "").split(separator: ",").map(String.init)
    }

    static func saveDisabledModules(_ modules: [String]) {
        guard modules != loadDisabledModules() else { return }
        if modules.isEmpty {
            Keychain.delete(modulesAccount)
        } else {
            Keychain.save(modules.joined(separator: ","), for: modulesAccount)
        }
    }

    private static var snapshotFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Widgets/snapshot.json")
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotFile, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func saveSnapshot(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotFile, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Signed out: nothing of the family stays.
    static func removeSnapshot() {
        guard let url = snapshotFile else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

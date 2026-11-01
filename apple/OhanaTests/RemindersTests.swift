import Foundation
import Testing
@testable import Ohana

/// The plain values of Reminders (`ReminderModels.swift`).
struct ReminderModelTests {
    @Test func readsAndWritesDueDates() throws {
        let day = try #require(ReminderDue("2026-11-07"))
        #expect(day.day == Day("2026-11-07") && day.time == nil)
        #expect(day.description == "2026-11-07")
        let timed = try #require(ReminderDue("2026-11-07T18:30"))
        #expect(timed.time == ReminderDue.Time(hour: 18, minute: 30))
        #expect(timed.description == "2026-11-07T18:30")
        #expect(ReminderDue("2026-11-07T08:05:59")?.description == "2026-11-07T08:05")
        for bad in ["", "tomorrow", "2026-11", "2026-11-07T25:00", "2026-11-07T18", "2026-13-01"] {
            #expect(ReminderDue(bad) == nil, "\(bad)")
        }
        let json = try JSONEncoder().encode([timed, day])
        #expect(String(decoding: json, as: UTF8.self) == #"["2026-11-07T18:30","2026-11-07"]"#)
        #expect(try JSONDecoder().decode([ReminderDue].self, from: json) == [timed, day])
    }

    @Test func dueDatesAsDateComponents() throws {
        let day = ReminderDue(day: Day("2026-11-07")!)
        #expect(day.components.year == 2026 && day.components.month == 11 && day.components.day == 7)
        #expect(day.components.hour == nil)
        #expect(ReminderDue(components: day.components) == day)
        let timed = ReminderDue(day: Day("2026-11-07")!, hour: 9, minute: 15)
        #expect(timed.components.hour == 9 && timed.components.minute == 15)
        #expect(ReminderDue(components: timed.components) == timed)
        #expect(ReminderDue(components: DateComponents(hour: 9)) == nil)
    }

    @Test func sortsNearestDueFirst() {
        let reminders = [
            ReminderSnapshot(id: "none", listID: "l", title: "B"),
            ReminderSnapshot(id: "late", listID: "l", title: "x", due: ReminderDue("2026-11-08")),
            ReminderSnapshot(id: "timed", listID: "l", title: "x", due: ReminderDue("2026-11-07T09:00")),
            ReminderSnapshot(id: "allDay", listID: "l", title: "x", due: ReminderDue("2026-11-07")),
            ReminderSnapshot(id: "none2", listID: "l", title: "A"),
        ]
        #expect(reminders.sorted(by: ReminderSnapshot.nearestDueFirst).map(\.id) == ["allDay", "timed", "late", "none2", "none"])
    }

    @Test func changesOnlyWhatTheyName() {
        let reminder = ReminderSnapshot(id: "r", listID: "a", title: "Milk", notes: "2 l", due: ReminderDue("2026-11-07"),
                                        url: URL(string: "https://x.example"))
        #expect(ReminderChange().isEmpty)
        #expect(ReminderChange().applied(to: reminder) == reminder)
        let moved = ReminderChange(title: "Oat milk", listID: "b").applied(to: reminder)
        #expect(moved.title == "Oat milk" && moved.listID == "b" && moved.notes == "2 l" && moved.due == reminder.due)
        let cleared = ReminderChange(notes: .some(nil), due: .some(nil), url: .some(nil)).applied(to: reminder)
        #expect(cleared.notes == nil && cleared.due == nil && cleared.url == nil && cleared.title == "Milk")
    }
}

/// What the meal plan needs (GET /meals/shopping) and the marker of the reminders Ohana writes.
struct ShoppingItemTests {
    static let json = """
    {"days":[{"date":"2026-11-07","items":[{"key":"12-3","ingredientId":12,"name":"Tomato","category":"PRODUCE","quantity":"150","unit":"g"},{"key":"7-5","ingredientId":7,"name":"Zucchini","category":"PRODUCE","quantity":"2.5","unit":"Stk"}]},{"date":"2026-11-10","items":[{"key":"3-1","ingredientId":3,"name":"Milk","category":"DAIRY","quantity":"1","unit":""}]}]}
    """

    @Test func decodesTheDays() throws {
        let needs = try JSONDecoder().decode(ShoppingNeeds.self, from: Data(Self.json.utf8))
        #expect(needs.days.map(\.date) == [Day("2026-11-07")!, Day("2026-11-10")!])
        let tomato = needs.days[0].items[0]
        #expect(tomato.key == "12-3" && tomato.ingredientId == 12 && tomato.category == "PRODUCE")
        let en = Locale(identifier: "en_US")
        #expect(tomato.label(locale: en) == "150 g Tomato")
        #expect(needs.days[0].items[1].label(locale: en) == "2.5 Stk Zucchini")
        #expect(needs.days[0].items[1].label(locale: Locale(identifier: "de_DE")) == "2,5 Stk Zucchini")
        // No unit: no double space.
        #expect(needs.days[1].items[0].label(locale: en) == "1 Milk")
        #expect(try JSONDecoder().decode(ShoppingNeeds.self, from: Data(#"{"days":[]}"#.utf8)).days.isEmpty)
    }

    @Test func formatsQuantities() {
        let en = Locale(identifier: "en_US")
        #expect(ShoppingQuantity.format("150", locale: en) == "150")
        #expect(ShoppingQuantity.format("0.333", locale: en) == "0.33")
        #expect(ShoppingQuantity.format("1500", locale: en) == "1500")
        #expect(ShoppingQuantity.format("a pinch", locale: en) == "a pinch")
    }

    @Test func theMarkerGoesThroughTheURL() throws {
        let marker = ShoppingReminderMarker(familyID: "fam 1", date: Day("2026-11-07")!, key: "12-3", quantity: "2.5",
                                            title: "2.5 g Salt & Pepper?")
        let url = marker.url
        #expect(url.scheme == "ohana")
        #expect(url.absoluteString.hasPrefix("ohana://f/fam%201/meals/shopping/2026-11-07/12-3?q=2.5&t="))
        #expect(ShoppingReminderMarker(url: url) == marker)
        #expect(marker.path == "2026-11-07/12-3")
        for other in ["https://x.example/f/f1/meals/shopping/2026-11-07/12-3?q=1", "ohana://f/f1/meals/shopping/2026-11-07/12-3",
                      "ohana://f/f1/meals/shopping/2026-11-07/12-3?q=150",
                      "ohana://f/f1/meals/plan", "ohana://f/f1/meals/shopping/soon/12-3?q=1", "ohana://invite/abc?q=1"] {
            #expect(ShoppingReminderMarker(url: URL(string: other)) == nil, "\(other)")
        }
        #expect(ShoppingReminderMarker(url: nil) == nil)
        // The app opens it on the meal plan.
        #expect(AppRoute.parse(webPath: "/" + (url.host() ?? "") + url.path(percentEncoded: false))?.route == .mealPlan)
    }
}

/// The shopping sync's rules (`ShoppingReminderPlan`).
struct ShoppingReminderPlanTests {
    let family = "f1"
    let today = Day("2026-11-05")!
    let en = Locale(identifier: "en_US")

    func item(_ key: String, _ name: String, _ quantity: String, unit: String = "g") -> ShoppingItem {
        ShoppingItem(key: key, ingredientId: Int(key.prefix { $0 != "-" }) ?? 0, name: name, category: "OTHER",
                     quantity: quantity, unit: unit)
    }

    func day(_ date: String, _ items: ShoppingItem...) -> ShoppingDay {
        ShoppingDay(date: Day(date)!, items: items)
    }

    /// A reminder as the sync writes it.
    func ohanas(_ id: String, _ date: String, _ item: ShoppingItem, family: String? = nil, title: String? = nil,
                done: Bool = false, quantity: String? = nil) -> ReminderSnapshot {
        let written = item.with(quantity: quantity ?? item.quantity).label(locale: en)
        let marker = ShoppingReminderMarker(familyID: family ?? self.family, date: Day(date)!, key: item.key,
                                            quantity: quantity ?? item.quantity, title: written)
        return ReminderSnapshot(id: id, listID: "list", title: title ?? written, due: ReminderDue(date),
                                isCompleted: done, url: marker.url)
    }

    func plan(_ days: [ShoppingDay], _ reminders: [ReminderSnapshot] = [], written: Set<String> = []) -> ShoppingReminderPlan {
        ShoppingReminderPlan.make(familyID: family, days: days, reminders: reminders, written: written, today: today, locale: en)
    }

    @Test func writesEveryItemOfTheDaysToCome() throws {
        let tomato = item("12-3", "Tomato", "150"), milk = item("3-1", "Milk", "1", unit: "l")
        let p = plan([day("2026-11-04", item("9-9", "Past", "1")), day("2026-11-05", tomato), day("2026-11-08", milk)])
        #expect(p.creates.map(\.title) == ["150 g Tomato", "1 l Milk"])
        #expect(p.creates.map(\.due) == [today, Day("2026-11-08")!])
        let marker = try #require(ShoppingReminderMarker(url: p.creates[0].url))
        #expect(marker == ShoppingReminderMarker(familyID: "f1", date: today, key: "12-3", quantity: "150", title: "150 g Tomato"))
        #expect(p.updates.isEmpty && p.removals.isEmpty)
        #expect(p.written == ["2026-11-05/12-3", "2026-11-08/3-1"])
    }

    @Test func leavesWhatIsThereAlone() {
        let tomato = item("12-3", "Tomato", "150"), milk = item("3-1", "Milk", "1", unit: "l")
        let p = plan([day("2026-11-06", tomato, milk)], [
            ohanas("a", "2026-11-06", tomato),
            ohanas("b", "2026-11-06", milk, done: true),
        ])
        #expect(p.changesNothing)
        // Seen in Reminders: remembered, so a deleted one doesn't come back.
        #expect(p.written == ["2026-11-06/12-3", "2026-11-06/3-1"])
    }

    @Test func matchesByTitleAndDayWithoutAMarker() {
        let tomato = item("12-3", "Tomato", "150")
        let other = ReminderSnapshot(id: "x", listID: "list", title: "150 g Tomato", due: ReminderDue("2026-11-06"))
        #expect(plan([day("2026-11-06", tomato)], [other]).changesNothing)
        // Another day, or another title: not it.
        let elsewhen = ReminderSnapshot(id: "y", listID: "list", title: "150 g Tomato", due: ReminderDue("2026-11-07"))
        #expect(plan([day("2026-11-06", tomato)], [elsewhen]).creates.count == 1)
        let edited = ReminderSnapshot(id: "z", listID: "list", title: "Tomatoes", due: ReminderDue("2026-11-06"))
        #expect(plan([day("2026-11-06", tomato)], [edited]).creates.count == 1)
        // Another family's reminder of the same title isn't taken for this family's.
        let theirs = ohanas("t", "2026-11-06", tomato, family: "f2")
        #expect(plan([day("2026-11-06", tomato)], [theirs]).creates.count == 1)
    }

    @Test func updatesTheQuantityWhileTheTitleIsOhanas() throws {
        let tomato = item("12-3", "Tomato", "300")
        let p = plan([day("2026-11-06", tomato)], [ohanas("a", "2026-11-06", tomato, quantity: "150")])
        #expect(p.creates.isEmpty && p.removals.isEmpty)
        let update = try #require(p.updates.first)
        #expect(update.id == "a" && update.title == "300 g Tomato")
        let marker = try #require(ShoppingReminderMarker(url: update.url))
        #expect(marker.quantity == "300" && marker.title == "300 g Tomato" && marker.path == "2026-11-06/12-3")

        // The user changed the title: theirs now.
        let edited = ohanas("a", "2026-11-06", tomato, title: "Tomatoes (ripe)", quantity: "150")
        #expect(plan([day("2026-11-06", tomato)], [edited]).changesNothing)
        // Done: left alone.
        let done = ohanas("a", "2026-11-06", tomato, done: true, quantity: "150")
        #expect(plan([day("2026-11-06", tomato)], [done]).changesNothing)
    }

    @Test func aDeletedItemStaysDeleted() {
        let tomato = item("12-3", "Tomato", "150")
        let p = plan([day("2026-11-06", tomato)], written: ["2026-11-06/12-3"])
        #expect(p.changesNothing)
        #expect(p.written == ["2026-11-06/12-3"])
        // Another day of the same item is another item.
        #expect(plan([day("2026-11-09", tomato)], written: ["2026-11-06/12-3"]).creates.count == 1)
    }

    @Test func removesWhatThePlanNoLongerNeeds() {
        let tomato = item("12-3", "Tomato", "150"), gone = item("8-2", "Basil", "20")
        let p = plan([day("2026-11-06", tomato)], [
            ohanas("keep", "2026-11-06", tomato),
            ohanas("gone", "2026-11-06", gone),
            ohanas("edited", "2026-11-06", gone, title: "Basil, a big bunch"),
            ohanas("done", "2026-11-07", gone, done: true),
            ohanas("past", "2026-11-04", gone),
            ohanas("theirs", "2026-11-06", gone, family: "f2"),
            ReminderSnapshot(id: "mine", listID: "list", title: "Coffee", due: ReminderDue("2026-11-06")),
        ], written: ["2026-11-06/12-3", "2026-11-06/8-2"])
        #expect(p.removals == ["gone"])
        #expect(p.creates.isEmpty && p.updates.isEmpty)
        // Ohana took it away, not the user: it may come back.
        #expect(p.written == ["2026-11-06/12-3"])
    }

    @Test func removesACopyOfAnItem() {
        // Two devices wrote it at once; one was ticked off.
        let tomato = item("12-3", "Tomato", "150")
        let p = plan([day("2026-11-06", tomato)], [ohanas("open", "2026-11-06", tomato), ohanas("done", "2026-11-06", tomato, done: true)])
        #expect(p.removals == ["open"])
        #expect(p.creates.isEmpty)
        #expect(p.written == ["2026-11-06/12-3"])
    }

    @Test func forgetsTheDaysBeforeToday() {
        let p = plan([], written: ["2026-11-04/1-1", "2026-11-05/1-1", "2026-12-01/2-2", "odd"])
        #expect(p.written == ["2026-11-05/1-1", "2026-12-01/2-2", "odd"])
        #expect(p.changesNothing)
    }

    @Test func anItemTwiceInADayIsWrittenOnce() {
        let tomato = item("12-3", "Tomato", "150")
        #expect(plan([day("2026-11-06", tomato, tomato)]).creates.count == 1)
    }
}

/// The shopping list's settings per server and family (`ShoppingReminders`).
struct ShoppingRemindersSettingsTests {
    func defaults() -> UserDefaults {
        let name = "ohana.tests.reminders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    let server = URL(string: "https://ohana.example/")!

    func api(_ family: String) -> FamilyAPI {
        FamilyAPI(client: APIClient(baseURL: server, token: nil), familyID: family)
    }

    @Test func keepsThemPerServerAndFamily() {
        let defaults = defaults()
        #expect(ShoppingReminders.key(server: server, familyID: "f1") == "shoppingReminders|https://ohana.example|f1")
        let reminders = ShoppingReminders(defaults: defaults)
        #expect(reminders.settings(for: api("f1")).listID == nil)
        reminders.setList("list-a", for: api("f1"))
        #expect(reminders.settings(for: api("f1")).listID == "list-a")
        #expect(reminders.settings(for: api("f2")).listID == nil)
        // Read back from the defaults.
        let again = ShoppingReminders(defaults: defaults)
        #expect(again.settings(server: server, familyID: "f1").listID == "list-a")
        // Off: nothing kept.
        again.setList(nil, for: api("f1"))
        #expect(defaults.data(forKey: ShoppingReminders.key(server: server, familyID: "f1")) == nil)
    }

    @Test func anotherListStartsFromNothingWritten() throws {
        let defaults = defaults()
        let key = ShoppingReminders.key(server: server, familyID: "f1")
        let stored = ShoppingRemindersSettings(listID: "list-a", written: ["2026-11-06/1-1"], lastSync: Date(),
                                               lastResult: ShoppingSyncResult(added: 1), lastError: nil)
        defaults.set(try JSONEncoder().encode(stored), forKey: key)
        let reminders = ShoppingReminders(defaults: defaults)
        #expect(reminders.settings(for: api("f1")) == stored)
        reminders.setList("list-a", for: api("f1"))
        #expect(reminders.settings(for: api("f1")).written == ["2026-11-06/1-1"])
        reminders.setList("list-b", for: api("f1"))
        #expect(reminders.settings(for: api("f1")) == ShoppingRemindersSettings(listID: "list-b"))
    }

    @Test func signingOutForgetsTheServersFamilies() {
        let defaults = defaults()
        let other = URL(string: "https://other.example")!
        defaults.set(Data("{}".utf8), forKey: ShoppingReminders.key(server: server, familyID: "f1"))
        defaults.set(Data("{}".utf8), forKey: ShoppingReminders.key(server: other, familyID: "f1"))
        ShoppingReminders.forget(server: server, defaults: defaults)
        #expect(defaults.data(forKey: ShoppingReminders.key(server: server, familyID: "f1")) == nil)
        #expect(defaults.data(forKey: ShoppingReminders.key(server: other, familyID: "f1")) != nil)
    }

    @Test func theDemoNeverSyncs() async {
        let defaults = defaults()
        let reminders = ShoppingReminders(defaults: defaults)
        let api = FamilyAPI(client: APIClient(demo: DemoServer()), familyID: DemoServer.familyID)
        let family = FamilyContext(family: FamilySummary(id: DemoServer.familyID, name: "Demo", role: .viewer, memberCount: 1),
                                   api: api)
        reminders.setList("list-a", for: api)
        await reminders.sync(family, reason: .manual)
        #expect(reminders.settings(for: api).lastSync == nil && reminders.settings(for: api).lastError == nil)
    }

    @Test func summarizesASync() {
        #expect(ShoppingRemindersView.summary(ShoppingSyncResult()) == "Nothing to change")
        #expect(ShoppingRemindersView.summary(ShoppingSyncResult(added: 3, updated: 0, removed: 2)) == "3 added, 2 removed")
    }
}

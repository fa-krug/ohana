import Foundation
import SwiftUI
import Testing
@testable import Ohana

struct OverviewTests {
    /// GET /overview as the server answered it (web tests' family with two events and birthdays).
    static let serverSample = """
    {"today":"2026-11-01","calendar":{"nextGap":null,"upcoming":[]},"awayToday":[],"todayEvents":[{"id":"e6cc03b9","date":"2026-11-01","start":"09:30","end":null,"title":"Dentist","location":"","person":"Mia","note":"","url":"","source":"manual","searchId":null}],"upcoming":[{"kind":"event","date":"2026-11-05","event":{"id":"6751a886","date":"2026-11-05","start":null,"end":null,"title":"Trip","location":"","person":"","note":"","url":"","source":"manual","searchId":null}}],"meals":{"today":null},"finance":{"currency":"EUR","month":"2026-11","incomeCents":0,"expenseCents":0,"count":0,"topExpense":null,"balanceCents":null},"searches":[],"birthdays":[{"day":"2026-11-15","name":"Mia","age":8},{"day":"2026-11-20","name":"Anna","age":36}]}
    """

    /// Every optional part filled in (shapes of dashboard.ts, summary.ts, meal-plan.ts).
    static let fullSample = """
    {"today":"2026-11-02","calendar":{"nextGap":"2026-11-04","upcoming":[{"name":"Vacation","color":"#22c55e","from":"2026-10-30","to":"2026-11-03"}]},
     "awayToday":["Vacation"],"todayEvents":[],
     "upcoming":[{"kind":"entry","date":"2026-10-30","to":"2026-11-03","name":"Vacation","color":"#22c55e"},
                 {"kind":"event","date":"2026-11-03","event":{"id":"e1","date":"2026-11-03","start":"08:15","end":"09:00","title":"Pediatrician","location":"Praxis","person":"Mia","note":"","url":"https://x.example","source":"appointment","searchId":"s1"}}],
     "meals":{"today":{"recipeId":"r1","recipeTitle":"Lasagne","isLeftover":true}},
     "finance":{"currency":"EUR","month":"2026-11","incomeCents":250000,"expenseCents":12345,"count":7,"topExpense":{"categoryId":"c1","name":"Groceries","icon":"🛒","color":"#f97316","expenseCents":9000},"balanceCents":-500},
     "searches":[{"id":"s1","name":"Pediatrician","enabled":true,"lastStatus":"ok","first":{"resultId":42,"doctorName":"Dr. Weber","slot":"2026-11-03T08:15:00.000Z"},"doctors":3},
                 {"id":"s2","name":"Dentist","enabled":false,"lastStatus":"paused","first":null,"doctors":0}],
     "birthdays":[]}
    """

    @Test func decodesTheServersDashboard() throws {
        let d = try JSONDecoder().decode(OverviewDashboard.self, from: Data(Self.serverSample.utf8))
        #expect(d.today == Day(year: 2026, month: 11, day: 1))
        #expect(d.calendar.nextGap == nil)
        #expect(d.todayEvents.first?.label == "Dentist · Mia")
        #expect(d.todayEvents.first?.start == "09:30")
        guard case let .event(date, event) = d.upcoming.first else {
            Issue.record("expected an event")
            return
        }
        #expect(date == Day("2026-11-05"))
        #expect(event.label == "Trip")
        #expect(event.start == nil)
        #expect(d.meals.today == nil)
        #expect(d.finance.balanceCents == nil)
        #expect(d.birthdays.map(\.name) == ["Mia", "Anna"])
        #expect(d.birthdays.map(\.age) == [8, 36])
    }

    @Test func decodesEveryPart() throws {
        let d = try JSONDecoder().decode(OverviewDashboard.self, from: Data(Self.fullSample.utf8))
        #expect(d.calendar.nextGap == Day("2026-11-04"))
        #expect(d.calendar.upcoming.first?.from == Day("2026-10-30"))
        #expect(d.awayToday == ["Vacation"])
        guard case let .entry(_, to, name, color) = d.upcoming.first else {
            Issue.record("expected an entry")
            return
        }
        #expect(to == Day("2026-11-03"))
        #expect(name == "Vacation")
        #expect(color == "#22c55e")
        #expect(d.upcoming[1].id == "event|e1")
        #expect(d.meals.today?.isLeftover == true)
        #expect(d.finance.netCents == 250000 - 12345)
        #expect(d.finance.topExpense?.icon == "🛒")
        #expect(d.finance.monthDay == Day("2026-11-01"))
        #expect(d.searches[0].first?.resultId == 42)
        #expect(d.searches[0].first?.date != nil)
        #expect(d.searches[1].first == nil)
    }

    @Test func decodesADashboardWithoutTheModulesAServerTurnedOff() throws {
        let json = """
        {"today":"2026-11-01","calendar":{"nextGap":null,"upcoming":[]},"awayToday":[],"todayEvents":[],"upcoming":[],"finance":null,"birthdays":[]}
        """
        let d = try JSONDecoder().decode(OverviewDashboard.self, from: Data(json.utf8))
        #expect(d.meals.today == nil)
        #expect(d.finance.count == 0)
        #expect(d.searches.isEmpty)
    }

    @Test func roundTripsUpcomingItems() throws {
        let d = try JSONDecoder().decode(OverviewDashboard.self, from: Data(Self.fullSample.utf8))
        let again = try JSONDecoder().decode(OverviewDashboard.self, from: JSONEncoder().encode(d))
        #expect(again == d)
    }

    @Test func formatsMoneyAndRanges() {
        #expect(OverviewFormat.signedMoney(0, currency: "EUR") == OverviewFormat.money(0, currency: "EUR"))
        #expect(OverviewFormat.signedMoney(150, currency: "EUR").hasPrefix("+"))
        #expect(OverviewFormat.signedMoney(-150, currency: "EUR").hasPrefix("−"))
        #expect(OverviewFormat.money(-150, currency: "EUR") != OverviewFormat.money(150, currency: "EUR"))
        let day = Day(year: 2026, month: 11, day: 3)
        #expect(OverviewFormat.range(day, day) == day.formatted())
        #expect(OverviewFormat.range(day, day.adding(days: 2)).contains("–"))
    }

    @Test func greetsByTheTimeOfDay() {
        #expect(OverviewFormat.greeting(hour: 8, name: "Anna").contains("Anna"))
        #expect(OverviewFormat.greeting(hour: 8, name: " ") == OverviewFormat.greeting(hour: 9, name: ""))
        #expect(OverviewFormat.greeting(hour: 8, name: "") != OverviewFormat.greeting(hour: 14, name: ""))
        #expect(OverviewFormat.greeting(hour: 14, name: "") != OverviewFormat.greeting(hour: 22, name: ""))
        #expect(OverviewFormat.greeting(hour: 2, name: "") == OverviewFormat.greeting(hour: 22, name: ""))
    }

    @Test func readsHexColors() {
        #expect(Color(overviewHex: "#ff0000") == Color(red: 1, green: 0, blue: 0))
        #expect(Color(overviewHex: "0f0") == Color(red: 0, green: 1, blue: 0))
        #expect(Color(overviewHex: "nope") == .gray)
    }

    @Test func linksEveryRowToItsPlace() throws {
        let d = try JSONDecoder().decode(OverviewDashboard.self, from: Data(Self.fullSample.utf8))
        #expect(d.upcoming.map(OverviewLinks.route(for:)) == [.calendarDay(Day("2026-10-30")!), .calendarDay(Day("2026-11-03")!)])
        #expect(OverviewLinks.meal(d.meals) == .recipe(id: "r1"))
        #expect(OverviewLinks.topExpense(d.finance) == .financeTransactions(categoryID: "c1"))
        #expect(d.searches.map(OverviewLinks.route(for:)) == [
            .appointmentSlot(searchID: "s1", resultID: "42"), .appointmentSearch(id: "s2"),
        ])

        let empty = try JSONDecoder().decode(OverviewDashboard.self, from: Data(Self.serverSample.utf8))
        #expect(OverviewLinks.meal(empty.meals) == .mealPlan)
        #expect(OverviewLinks.topExpense(empty.finance) == .financeTransactions(categoryID: nil))
        #expect(empty.birthdays.map(OverviewLinks.route(for:)).first == .calendarDay(Day("2026-11-15")!))
        #expect(OverviewLinks.route(for: empty.todayEvents[0]) == .calendarDay(Day("2026-11-01")!))
        // Every route lands in the module it belongs to.
        #expect(OverviewLinks.route(for: d.searches[0]).module == .appointments)
        #expect(OverviewLinks.topExpense(d.finance).module == .finance)
    }

    @Test func countsWithPlurals() {
        #expect(String(OverviewFormat.doctorAndMore("Dr. Weber", more: 1).characters) == "Dr. Weber and 1 more doctor")
        #expect(String(OverviewFormat.doctorAndMore("Dr. Weber", more: 2).characters) == "Dr. Weber and 2 more doctors")
    }

    @Test func asksTheAssistant() {
        #expect(OverviewAsk.question("  What's for dinner?\n") == "What's for dinner?")
        #expect(OverviewAsk.question(" \n") == nil)
        let editor = OverviewAsk.suggestions(canEdit: true)
        #expect(editor.count == 3 && Set(editor).count == 3)
        #expect(editor.contains("Plan next week's meals"))
        // Viewers can't change the plan: no suggestion that would.
        #expect(!OverviewAsk.suggestions(canEdit: false).contains("Plan next week's meals"))
    }
}

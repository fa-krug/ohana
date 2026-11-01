import Foundation
import Testing
@testable import Ohana

struct WidgetTests {

    static func day(_ text: String) -> Day { Day(text)! }

    static func at(_ day: String, _ time: String) -> Date { WidgetSnapshot.date(Self.day(day), time)! }

    static func snapshot(_ json: String, disabledModules: [String] = [], loadedAt: Date) throws -> WidgetSnapshot {
        try WidgetSnapshot(overview: Data(json.utf8), familyID: "f1", disabledModules: disabledModules, loadedAt: loadedAt)
    }

    @Test func takesTodayAndTomorrowFromTheOverview() throws {
        let s = try Self.snapshot(OverviewTests.fullSample, loadedAt: Self.at("2026-11-02", "07:00"))
        #expect(s.familyID == "f1")
        #expect(s.today == Self.day("2026-11-02"))
        let today = try #require(s.items(on: Self.day("2026-11-02"), now: Self.at("2026-11-02", "07:00")))
        #expect(today.map(\.title) == ["Vacation"])
        #expect(today.first?.color == "#22c55e")
        let tomorrow = try #require(s.items(on: Self.day("2026-11-03"), now: Self.at("2026-11-02", "07:00")))
        #expect(tomorrow.map(\.title) == ["Vacation", "Pediatrician · Mia"])
        #expect(tomorrow.last?.start == "08:15")
        #expect(tomorrow.last?.isAppointment == true)
        #expect(s.items(on: Self.day("2026-11-04"), now: Self.at("2026-11-02", "07:00")) == nil)
    }

    @Test func takesDinnerShoppingAndFinds() throws {
        let s = try Self.snapshot(OverviewTests.fullSample, loadedAt: Self.at("2026-11-02", "07:00"))
        let today = Self.day("2026-11-02")
        #expect(s.dinner(on: today) == WidgetSnapshot.Dinner(recipeID: "r1", title: "Lasagne", isLeftover: true))
        #expect(s.dinner(on: today.adding(days: 1)) == nil)
        #expect(s.away(on: today) == ["Vacation"])
        #expect(s.shopping == WidgetSnapshot.Shopping(listID: "l1", date: Self.day("2026-11-03"), open: 3, total: 12))
        #expect(s.shopping?.progress == 0.75)
        // The paused search and its missing find are left out.
        #expect(s.finds.map(\.searchID) == ["s1"])
        #expect(s.finds.first?.resultID == 42)
        #expect(s.finds.first?.doctorName == "Dr. Weber")
        #expect(s.finds(after: Date.server("2026-11-03T09:00:00Z")!).isEmpty)
    }

    @Test func leavesOutEventsAlreadyOver() throws {
        let s = try Self.snapshot(OverviewTests.serverSample, loadedAt: Self.at("2026-11-01", "07:00"))
        let today = Self.day("2026-11-01")
        // 09:30 without an end: over at 10:30.
        #expect(s.items(on: today, now: Self.at("2026-11-01", "10:00"))?.map(\.title) == ["Dentist · Mia"])
        #expect(s.items(on: today, now: Self.at("2026-11-01", "10:31"))?.isEmpty == true)
        // Tomorrow's is never "over" today.
        #expect(s.items(on: today.adding(days: 1), now: Self.at("2026-11-01", "10:31"))?.isEmpty == true)
        let changes = s.changes(after: Self.at("2026-11-01", "08:00"))
        #expect(changes == [Self.at("2026-11-01", "10:30"), Day.calendar.startOfDay(for: Self.day("2026-11-02").date)])
    }

    @Test func ordersADay() throws {
        let json = """
        {"today":"2026-11-01","calendar":{"nextGap":null,"upcoming":[]},"awayToday":[],
         "todayEvents":[
           {"id":"a","date":"2026-11-01","start":"18:00","end":null,"title":"Late","location":"","person":"","note":"","url":"","source":"manual","searchId":null},
           {"id":"b","date":"2026-11-01","start":null,"end":null,"title":"Trip","location":"","person":"","note":"","url":"","source":"manual","searchId":null},
           {"id":"c","date":"2026-11-01","start":"08:00","end":"09:00","title":"Early","location":"","person":"Leo","note":"","url":"","source":"manual","searchId":null}],
         "upcoming":[{"kind":"entry","date":"2026-11-01","to":"2026-11-01","name":"School","color":"#3b82f6"}],
         "meals":{"today":null,"shopping":null},"searches":[],
         "birthdays":[{"day":"2026-11-01","name":"Mia","age":8},{"day":"2026-11-02","name":"Anna","age":36}]}
        """
        let s = try Self.snapshot(json, loadedAt: Self.at("2026-11-01", "07:00"))
        let today = s.items(on: Self.day("2026-11-01"), now: Self.at("2026-11-01", "07:00"))
        #expect(today?.map(\.title) == ["School", "Mia", "Trip", "Early · Leo", "Late"])
        #expect(today?[1].age == 8)
        #expect(s.items(on: Self.day("2026-11-02"), now: Self.at("2026-11-01", "07:00"))?.map(\.kind) == [.birthday])
    }

    @Test func knowsTheModulesThatAreOff() throws {
        let s = try Self.snapshot(OverviewTests.fullSample, disabledModules: ["meals"], loadedAt: Self.at("2026-11-02", "07:00"))
        #expect(!s.mealsEnabled)
        #expect(s.appointmentsEnabled)
        // An older server without the parts of turned-off modules.
        let bare = try Self.snapshot(OverviewTests.serverSample.replacingOccurrences(of: #""meals":{"today":null,"shopping":null},"#, with: ""),
                                     loadedAt: Self.at("2026-11-01", "07:00"))
        #expect(bare.dinner == nil && bare.shopping == nil)
    }

    @Test func survivesBeingSaved() throws {
        let s = try Self.snapshot(OverviewTests.fullSample, loadedAt: Self.at("2026-11-02", "07:00"))
        let again = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(s))
        #expect(again == s)
    }

    @Test func asksTheServersOverview() {
        let url = WidgetSnapshot.overviewURL(server: URL(string: "https://example.org/ohana/")!, familyID: "f1",
                                             today: Self.day("2026-11-01"))
        #expect(url.absoluteString == "https://example.org/ohana/api/v1/families/f1/overview?today=2026-11-01")
    }
}

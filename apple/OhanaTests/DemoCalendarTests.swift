import Foundation
import Testing
@testable import Ohana

/// The demo's calendar: GET /families/demo?year= as the calendar and its settings load it.
struct DemoCalendarTests {
    private let today = Day("2026-10-30")!

    private func state(year: Int?, today: Day? = nil) throws -> CalendarState {
        var server = DemoServer()
        let day = today ?? self.today
        server.today = { day }
        server.now = { day.date }
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo")
        if let year { url.append(queryItems: [URLQueryItem(name: "year", value: String(year))]) }
        let (data, response) = server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200)
        return try APIClient.decoder.decode(CalendarState.self, from: data)
    }

    @Test func theYearHasTypesEntriesNotesEventsAndBirthdays() throws {
        let state = try state(year: 2026)
        #expect(state.family.id == "demo" && state.family.name == "Parker family")
        #expect(state.family.readOnly && state.family.access == "view" && state.family.legacyId == nil)
        #expect(state.types.map(\.name) == ["Vacation", "School holidays", "Grandma visits", "Anna off work"])
        #expect(state.types.allSatisfy { $0.year == 2026 })
        #expect(state.types.first { $0.id == "vacation" }?.isAway == true)
        #expect(state.typeYears == [2025, 2026, 2027])

        // Vacation during the school holidays, {{day:12}}…{{day:19}}; Grandma {{day:24}}…{{day:26}}.
        for offset in 12...19 {
            #expect(state.entries[today.adding(days: offset).description] == ["vacation", "school-holidays"])
        }
        #expect(state.entries[today.adding(days: 11).description] == nil)
        #expect(state.entries[today.adding(days: 25).description] == ["grandma"])
        #expect(state.notes?[today.adding(days: 12).description]?.comment.contains("Lisbon") == true)

        let events = try #require(state.events)
        #expect(events.values.flatMap { $0 }.map(\.id).sorted()
            == ["event-dentist", "event-parents-evening", "event-pediatrician", "event-swim"])
        let pediatrician = try #require(events[today.adding(days: 3).description]?.first)
        #expect(pediatrician.id == "event-pediatrician" && pediatrician.isAppointment)
        #expect(pediatrician.searchId == "search-pediatrician" && pediatrician.person == "Mia")
        #expect(events[today.adding(days: 6).description]?.first?.timeText == "19:00")
        #expect(events[today.description]?.first?.line == "10:00 Dentist (Ben)")

        let birthdays = try #require(state.birthdays)
        #expect(birthdays["2026-03-14"] == [CalendarBirthday(name: "Mia", age: 8)])
        #expect(birthdays["2026-07-02"] == [CalendarBirthday(name: "Leo", age: 5)])
        #expect(birthdays["2026-09-03"] == [CalendarBirthday(name: "Ben Parker", age: 39)])
        #expect(birthdays["2026-05-20"] == [CalendarBirthday(name: "Anna Parker", age: 37)])
        #expect(birthdays[today.adding(days: 10).description] == [CalendarBirthday(name: "Grandma Rose", age: 74)])

        // The store takes it as the screen does.
        let client = APIClient(baseURL: DemoServer.baseURL, token: nil)
        let store = CalendarStore(api: FamilyAPI(client: client, familyID: "demo"), year: 2026, readOnly: true)
        store.apply(state)
        #expect(store.types(on: today.adding(days: 12)).map(\.id) == ["vacation", "school-holidays"])
        #expect(store.readOnly)
    }

    @Test func otherYearsHaveTheSameTypesAndOnlyTheirOwnDays() throws {
        let next = try state(year: 2027)
        #expect(next.types.count == 4 && next.types.allSatisfy { $0.year == 2027 })
        #expect(next.entries.keys.allSatisfy { $0.hasPrefix("2027-") })
        #expect(next.events?.isEmpty == true)
        #expect(next.birthdays?["2027-03-14"] == [CalendarBirthday(name: "Mia", age: 9)])

        let far = try state(year: 2030)
        #expect(far.entries.isEmpty && far.notes?.isEmpty == true)
        #expect(far.typeYears == [2025, 2026, 2027, 2030])
    }

    @Test func spansCrossingNewYearSplitBetweenTheYears() throws {
        let today = Day("2026-12-24")!
        let this = try state(year: 2026, today: today)
        let next = try state(year: 2027, today: today)
        // Vacation {{day:12}}…{{day:19}} is 2027-01-05…01-12.
        #expect(this.entries["2026-12-31"] == nil)
        #expect(next.entries["2027-01-05"] == ["vacation", "school-holidays"])
        #expect(this.entries.keys.allSatisfy { $0.hasPrefix("2026-") })
        #expect(this.events?[today.description]?.first?.id == "event-dentist")
        #expect(next.events?["2026-12-27"] == nil && this.events?["2026-12-27"]?.first?.id == "event-pediatrician")
    }

    @Test func withoutAYearItIsThisYear() throws {
        let state = try state(year: nil)
        #expect(state.types.allSatisfy { $0.year == 2026 })
        #expect(state.entries[today.adding(days: 12).description] != nil)
    }
}

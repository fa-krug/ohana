import Foundation
import Testing
@testable import Ohana

/// The demo's overview and family settings: every GET those screens make answers with JSON the
/// screens decode, and the data agrees with the rest of the demo family.
struct DemoOverviewTests {
    static let today = Day(year: 2026, month: 10, day: 30)
    static let server = DemoServer(today: { today }, now: { Date(timeIntervalSince1970: 1_793_354_400) })

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type) throws -> T {
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo" + path)
        if !query.isEmpty { url.append(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        let (data, response) = Self.server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200, "GET \(path)")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    private func request(_ familyPath: String) -> DemoServer.Request {
        DemoServer.Request(method: .get, path: "/api/v1/families/demo" + familyPath, query: [:],
                           familyPath: familyPath, today: Self.today, now: Date())
    }

    @Test func overviewShowsTheFamilysDay() throws {
        let d = try get("/overview", query: ["today": Self.today.description], as: OverviewDashboard.self)
        #expect(d.today == Self.today)
        #expect(d.todayEvents.map(\.id) == ["event-dentist"])
        #expect(d.todayEvents.first?.label == "Dentist · Ben")
        let events = d.upcoming.compactMap { item -> OverviewEvent? in
            if case let .event(_, event) = item { event } else { nil }
        }
        #expect(events.map(\.id) == ["event-swim", "event-pediatrician", "event-parents-evening", "event-swim",
                                      "event-football", "event-piano", "event-class-trip"])
        #expect(events.map(\.date) == [1, 3, 6, 8, 8, 8, 9].map { Self.today.adding(days: $0) })
        // Occurrences of the weekly lesson tell apart by their day; the trip spans three days.
        #expect(Set(events.map(\.uid)).count == events.count && events[0].rrule != nil)
        #expect(events[6].endDate == Self.today.adding(days: 11) && events[6].time(on: Self.today.adding(days: 9)) == nil)
        #expect(events[1].searchId == "search-pediatrician" && events[1].source == "appointment")
        #expect(events[2].end == nil)
        #expect(d.upcoming.map(\.date) == d.upcoming.map(\.date).sorted())
        #expect(d.calendar.upcoming.first?.name == "Vacation")
        #expect(d.calendar.upcoming.first?.from == Self.today.adding(days: 12))
        #expect(d.awayToday.isEmpty)

        #expect(d.meals.today?.recipeId == "recipe-lasagne")
        #expect(d.meals.today?.recipeTitle == "Vegetable lasagne")

        #expect(d.finance.currency == "EUR")
        #expect(d.finance.month == "2026-10")
        // The month's numbers are the finance page's (the demo's transactions).
        let summary = try get("/finance/summary", query: ["from": "2026-10-01", "to": "2026-10-31"], as: FinanceSummary.self)
        #expect(d.finance.incomeCents == summary.incomeCents)
        #expect(d.finance.expenseCents == summary.expenseCents)
        #expect(d.finance.count == summary.count)
        #expect(d.finance.topExpense?.categoryId == "rent")
        #expect(d.finance.netCents > 0)

        #expect(d.searches.map(\.id) == ["search-pediatrician", "search-dermatologist"])
        #expect(d.searches[0].enabled && !d.searches[1].enabled)
        // The first find is the booked slot of the appointments page.
        #expect(d.searches[0].first?.resultId == 101)
        #expect(d.searches[0].first?.doctorName == "Dr. med. Katharina Weber")
        #expect(d.searches[0].first?.date != nil)
        #expect(d.searches[0].doctors == 3)
        #expect(OverviewLinks.route(for: d.searches[0]) == .appointmentSlot(searchID: "search-pediatrician", resultID: "101"))
    }

    /// The handler works the birthdays out from the household (until it is registered in
    /// `DemoServer.handlers`, the file's empty list answers).
    @Test func overviewHasGrandmasBirthdayComingUp() throws {
        let value = try #require(DemoServer.overview(request("/overview")))
        let d = try APIClient.decoder.decode(OverviewDashboard.self, from: APIClient.encoder.encode(value))
        #expect(d.birthdays.map(\.name) == ["Grandma Rose"])
        #expect(d.birthdays.first?.day == Self.today.adding(days: 10))
        #expect(d.birthdays.first?.age == 2026 - 1952)
        #expect(d.todayEvents.first?.id == "event-dentist")
        #expect(DemoServer.overview(request("/household")) == nil)
    }

    @Test func birthdaysFollowTheServersRules() {
        let people: [(name: String, birthday: Day)] = [
            ("Ben", Day(year: 1987, month: 9, day: 3)), ("Leap", Day(year: 2000, month: 2, day: 29)),
            ("Mia", Day(year: 2018, month: 3, day: 14)),
        ]
        let late = DemoServer.birthdays(people, from: Day(year: 2026, month: 8, day: 20), to: Day(year: 2026, month: 9, day: 18))
        #expect(late.map(\.name) == ["Ben"])
        #expect(late.first?.age == 39)
        let spring = DemoServer.birthdays(people, from: Day(year: 2027, month: 2, day: 20), to: Day(year: 2027, month: 3, day: 21))
        #expect(spring.map(\.name) == ["Leap", "Mia"])
        #expect(spring.first?.day == Day(year: 2027, month: 2, day: 28))
        #expect(spring.map(\.age) == [27, 9])
    }

    @Test func householdAsTheDemoViewerSeesIt() throws {
        let h = try get("/household", as: FamilyHousehold.self)
        #expect(h.name == "Parker family")
        #expect(h.role == .viewer && !h.canEdit)
        #expect(h.selfId == "demo-user")
        #expect(h.members.map(\.userId) == ["demo-anna", "demo-user"])
        #expect(h.members.map(\.role) == [.editor, .viewer])
        #expect(h.members[0].birthday == Day("1989-05-20"))
        #expect(h.members[1].birthday == Day("1987-09-03"))
        #expect(h.members.allSatisfy { Date.server($0.joinedAt) != nil })
        #expect(h.people.map(\.name) == ["Grandma Rose", "Leo", "Mia"])
        #expect(h.people[0].birthday == Day(year: 1952, month: 11, day: 9))
        #expect(h.people[2].birthday == Day("2018-03-14"))
        #expect(h.invites.isEmpty)
        #expect(h.home.address == "Lindenstraße 12, 10115 Berlin")
        #expect(h.home.hasLocation)
        #expect(h.channels.map(\.kind) == [.telegram, .email])
        #expect(h.channels.allSatisfy { $0.hasToken && $0.enabled })
        #expect(h.events.map(\.event) == ["appointment_found", "coverage_gap", "weekly_digest", "assistant_turn_finished"])
        #expect(h.events[1].channelIds == ["channel-telegram"])
        #expect(h.events[0].hasChannels == false)
    }

    @Test func exportIsAFamilyFile() throws {
        let (data, response) = Self.server.respond(to: URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/export")))
        #expect(response.statusCode == 200)
        #expect(FamilyExportFile.isExportFile(data))
        let file = try APIClient.decoder.decode(JSONValue.self, from: data)
        #expect(file["name"]?.stringValue == "Parker family")
        #expect(file["types"]?.arrayValue?.first?["year"]?.doubleValue == 2026)
        #expect(file["entries"]?[Self.today.adding(days: 12).description] == .array([.string("vacation")]))
        #expect(file["finance"]?["accounts"]?.arrayValue?.count == 2)
    }

    @Test func changesAreRefused() {
        var req = URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/household/home"))
        req.httpMethod = "PUT"
        #expect(Self.server.respond(to: req).1.statusCode == 403)
    }
}

import Foundation
import Testing
@testable import Ohana

/// The demo server's appointments answers decode into what the screens decode.
@MainActor
struct DemoAppointmentsTests {
    /// Friday, 30 October 2026, 09:00 on this device.
    private let today = Day(year: 2026, month: 10, day: 30)

    private var server: DemoServer {
        var server = DemoServer()
        let today = today
        server.today = { today }
        server.now = { Day.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))! }
        return server
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type = T.self) throws -> T {
        let url = DemoServer.baseURL.appending(path: "/api/v1/families/demo\(path)")
        let (data, response) = server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200, "\(path): \(String(decoding: data, as: UTF8.self))")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    @Test func listsTheSearchesAndTheBooking() throws {
        let overview: AppointmentsOverview = try get("/appointments")
        #expect(overview.searches.map(\.id) == ["search-pediatrician", "search-dermatologist"])

        let pediatrician = try #require(overview.searches.first)
        #expect(pediatrician.name == "Pediatrician for Mia")
        #expect(pediatrician.enabled)
        #expect(pediatrician.latestRun?.status == "OK")
        #expect(pediatrician.badgeStatus == "OK")
        #expect(pediatrician.doctors.map(\.resultId) == [101, 102, 103])
        #expect(pediatrician.ignored.count == 1)
        // Sorted by slot, all in the next weeks, none on a weekend but the booked one.
        let days = pediatrician.doctors.compactMap(\.day)
        #expect(days == days.sorted())
        #expect(days.allSatisfy { $0 > today && $0 < today.adding(days: 21) })
        #expect(pediatrician.doctors.dropFirst().compactMap(\.day).allSatisfy { ![1, 7].contains($0.weekday) })

        let dermatologist = try #require(overview.searches.last)
        #expect(!dermatologist.enabled)
        #expect(dermatologist.nextRunAt == nil)
        #expect(dermatologist.doctors.first?.source == "jameda")
        #expect(AppointmentLogic.scheduleSummary(dermatologist) == "not scheduled")

        let booking = try #require(overview.booked.first)
        #expect(overview.booked.count == 1)
        #expect(booking.id == "event-pediatrician")
        #expect(booking.date == today.adding(days: 3).description)
        #expect(booking.start == "08:30" && booking.end == "09:00")
        #expect(booking.person == "Mia")
        #expect(booking.searchId == "search-pediatrician")
    }

    @Test func showsBothSearches() throws {
        let pediatrician: AppointmentSearchDetail = try get("/appointments/searches/search-pediatrician")
        #expect(pediatrician.search.id == "search-pediatrician")
        #expect(pediatrician.search.doctors.count == 3)
        #expect(pediatrician.home?.address == "Lindenstraße 12, 10115 Berlin")

        let dermatologist: AppointmentSearchDetail = try get("/appointments/searches/search-dermatologist")
        #expect(!dermatologist.search.enabled)
        #expect(dermatologist.search.latestRun?.startedAt == DemoServer.timestamp(server.now().addingTimeInterval(-12990 * 60)))

        let url = DemoServer.baseURL.appending(path: "/api/v1/families/demo/appointments/searches/search-nope")
        #expect(server.respond(to: URLRequest(url: url)).1.statusCode == 404)
    }

    @Test func listsTheRuns() throws {
        let pediatrician: AppointmentRunsResponse = try get("/appointments/searches/search-pediatrician/runs")
        #expect(pediatrician.runs.map(\.run.status) == ["OK", "OK", "NO_AVAILABILITY", "ERROR"])
        #expect(pediatrician.runs.first?.doctors.count == 3)
        #expect(pediatrician.runs.last?.run.errorMessage.isEmpty == false)
        let started = pediatrician.runs.compactMap { Date.server($0.run.startedAt) }
        #expect(started == started.sorted(by: >))

        let dermatologist: AppointmentRunsResponse = try get("/appointments/searches/search-dermatologist/runs")
        #expect(dermatologist.runs.count == 2)
    }

    @Test func showsTheBookedSlotAtItsEventsTime() throws {
        let slot: AppointmentSlotDetail = try get("/appointments/searches/search-pediatrician/slots/101")
        #expect(slot.slot.practiceName == "Kinderarztpraxis Dr. Weber")
        #expect(slot.searchName == "Pediatrician for Mia")
        #expect(slot.specialityLabel == "Kinderarzt")
        #expect(slot.searchEnabled)
        #expect(slot.people.contains("Mia"))
        #expect(slot.homeLat != nil)
        let booking = try #require(slot.booking)
        #expect(booking.eventId == "event-pediatrician")
        #expect(booking.person == "Mia")
        let parts = AppointmentLogic.localParts(try #require(slot.slot.date), calendar: Day.calendar)
        #expect(parts.date == booking.date && parts.time == booking.start)
        #expect(AppointmentLogic.distance(of: slot.slot, homeLat: slot.homeLat, homeLng: slot.homeLng) != nil)
    }

    @Test func showsOtherSlotsWithoutBooking() throws {
        let open: AppointmentSlotDetail = try get("/appointments/searches/search-pediatrician/slots/102")
        #expect(open.booking == nil)
        // A slot of an older run (the history links to it).
        let older: AppointmentSlotDetail = try get("/appointments/searches/search-pediatrician/slots/93")
        #expect(older.slot.doctorName == "Dr. med. Leyla Aydın")
        let paused: AppointmentSlotDetail = try get("/appointments/searches/search-dermatologist/slots/201")
        #expect(!paused.searchEnabled)
        #expect(paused.slot.sourceName == "jameda")

        let url = DemoServer.baseURL.appending(path: "/api/v1/families/demo/appointments/searches/search-dermatologist/slots/101")
        #expect(server.respond(to: URLRequest(url: url)).1.statusCode == 404)
    }

    @Test func offersTheFormsOptions() throws {
        let options: AppointmentOptions = try get("/appointments/options")
        #expect(options.people == ["Ben Parker", "Anna Parker", "Mia", "Leo", "Grandma Rose"])
        #expect(options.home?.lat == 52.5326)
    }

    @Test func refusesChanges() {
        var request = URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/appointments/searches/search-pediatrician/run"))
        request.httpMethod = "POST"
        #expect(server.respond(to: request).1.statusCode == 403)
    }
}

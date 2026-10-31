import Foundation
import Testing
@testable import Ohana

// Sample answers as server/lib/appointments/app-routes.ts sends them (captured from the routes).
private enum AppointmentSamples {
    static let doctor = """
    {"resultId":1,"doctorName":"Dr A","doctorSubtitle":"","speciality":"","practiceName":"Praxis A","motiveLabel":"Erstuntersuchung","bookingUrl":"https://www.doctolib.de/a","slot":"2026-11-03T12:00:00.000Z","isNextSlot":false,"practiceAddress":"Hauptstr. 1","practiceCity":"München","practiceZipcode":"80331","practiceLatitude":"48.14","practiceLongitude":"11.58","source":"doctolib"}
    """
    static let run = """
    {"id":"7f08ae03","status":"OK","startedAt":"2026-11-01T12:00:00.000Z","finishedAt":"2026-11-01T12:00:00.000Z","errorMessage":"","doctorsFound":2,"doctorsMatched":1,"slotsFound":1,"notified":false,"triggeredBy":"SCHEDULE"}
    """
    static let search = """
    {"id":"6313f745","name":"Derm","sources":"doctolib","specialitySlug":"dermatologe","specialityLabel":"Dermatologe","jamedaSpecialitySlug":"","jamedaSpecialityLabel":"","jamedaSpecialityType":"leistung","jamedaInsuranceType":"","jamedaKidsFriendly":false,"jamedaVideo":"any","locationLabel":"München","latitude":"48.13","longitude":"11.57","insuranceSector":"","dayLimit":14,"maxPages":3,"enabled":true,"scheduleType":"MINUTES","scheduleMinutes":30,"cron":"","notifyOnlyEarlier":false,"lastRunAt":null,"lastStatus":"","nextRunAt":"2026-11-01T12:00:00.000Z","runRequested":false,"channelIds":[],"latestRun":\(run),"doctors":[\(doctor)],"ignored":[{"id":4,"doctorName":"Dr B","motiveLabel":"Kontrolle","providerSlug":"dr-b","motiveId":2}]}
    """
    static let event = """
    {"id":"93e8aff5","date":"2026-11-03","start":"09:30","end":null,"title":"Dr A","location":"Praxis A, Hauptstr. 1, 80331 München","person":"Oma","note":"Erstuntersuchung","url":"https://www.doctolib.de/a","source":"appointment","searchId":"6313f745"}
    """
    static let overview = #"{"searches":[\#(search)],"booked":[\#(event)]}"#
    static let options = """
    {"channels":[{"id":"0790f6d0","name":"Phone","provider":"PUSHBULLET","enabled":true}],"people":["Sascha"],"home":{"address":"Marienplatz 1, München","lat":48.137,"lng":11.575}}
    """
    static let detail = #"{"search":\#(search),"home":null}"#
    static let runs = #"{"runs":[{"run":\#(run),"doctors":[\#(doctor)]}]}"#
    static let slot = """
    {"slot":\(doctor),"searchId":"6313f745","searchName":"Derm","specialityLabel":"Dermatologe","insuranceSector":"","homeLat":48.137,"homeLng":11.575,"booking":{"eventId":"93e8aff5","date":"2026-11-03","start":"09:30","end":null,"person":"Oma"},"searchEnabled":true,"people":["Sascha"]}
    """
    static let book = #"{"eventId":"93e8aff5","event":\#(event)}"#

    static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }
}

struct AppointmentDecodingTests {
    @Test func decodesTheOverview() throws {
        let overview: AppointmentsOverview = try AppointmentSamples.decode(AppointmentSamples.overview)
        let search = try #require(overview.searches.first)
        #expect(search.name == "Derm")
        #expect(search.scheduleMinutes == 30)
        #expect(search.lastRunAt == nil)
        #expect(search.latestRun?.status == "OK")
        #expect(search.badgeStatus == "OK")
        #expect(!search.isBusy)
        #expect(!search.hasError)
        #expect(search.ignored.first?.doctorName == "Dr B")
        let doctor = try #require(search.doctors.first)
        #expect(doctor.address == "Hauptstr. 1, 80331 München")
        #expect(doctor.coordinate?.lat == 48.14)
        #expect(doctor.bookingURL?.absoluteString == "https://www.doctolib.de/a")
        #expect(doctor.date == Date(timeIntervalSince1970: 1_793_707_200))
        let event = try #require(overview.booked.first)
        #expect(event.end == nil)
        #expect(event.searchId == "6313f745")
    }

    @Test func decodesOptionsDetailRunsSlotAndBooking() throws {
        let options: AppointmentOptions = try AppointmentSamples.decode(AppointmentSamples.options)
        #expect(options.channels.map(\.name) == ["Phone"])
        #expect(options.home?.lat == 48.137)
        let detail: AppointmentSearchDetail = try AppointmentSamples.decode(AppointmentSamples.detail)
        #expect(detail.home == nil)
        #expect(detail.search.id == "6313f745")
        let runs: AppointmentRunsResponse = try AppointmentSamples.decode(AppointmentSamples.runs)
        #expect(runs.runs.first?.doctors.count == 1)
        let slot: AppointmentSlotDetail = try AppointmentSamples.decode(AppointmentSamples.slot)
        #expect(slot.booking?.person == "Oma")
        #expect(slot.searchEnabled)
        #expect(slot.people == ["Sascha"])
        let booked: AppointmentBookingResponse = try AppointmentSamples.decode(AppointmentSamples.book)
        #expect(booked.eventId == "93e8aff5")
    }

    @Test func decodesAutocompleteSuggestions() throws {
        let places: [AppointmentLocationSuggestion] = try AppointmentSamples.decode(#"[{"label":"München, 80331","latitude":"48.1","longitude":"11.5"}]"#)
        #expect(places.first?.latitude == "48.1")
        let terms: [AppointmentJamedaTerm] = try AppointmentSamples.decode(#"[{"slug":"hautarzt","label":"Hautarzt","type":"specialization"}]"#)
        #expect(terms.first?.type == "specialization")
        let specialities: [AppointmentSpecialitySuggestion] = try AppointmentSamples.decode(#"[{"slug":"dermatologe","label":"Dermatologe"}]"#)
        #expect(specialities.first?.id == "dermatologe")
    }

    @Test func busyWhileQueuedOrRunning() throws {
        let queued = AppointmentSamples.search.replacingOccurrences(of: #""runRequested":false"#, with: #""runRequested":true"#)
        let search: AppointmentSearch = try AppointmentSamples.decode(queued)
        #expect(search.isBusy)
        #expect(search.badgeStatus == "QUEUED")
        let running = AppointmentSamples.search.replacingOccurrences(of: #""status":"OK""#, with: #""status":"RUNNING""#)
        #expect(try AppointmentSamples.decode(running, as: AppointmentSearch.self).isBusy)
        let failed = AppointmentSamples.search.replacingOccurrences(of: #""status":"OK""#, with: #""status":"ERROR""#)
        #expect(try AppointmentSamples.decode(failed, as: AppointmentSearch.self).hasError)
    }
}

struct AppointmentInputTests {
    @Test func roundTripsAStoredSearch() throws {
        let search: AppointmentSearch = try AppointmentSamples.decode(AppointmentSamples.search)
        let input = AppointmentSearchInput(search)
        #expect(input.specialitySlug == "dermatologe")
        #expect(input.doctolibOn && !input.jamedaOn)
        let data = try APIClient.encoder.encode(input)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["scheduleMinutes"] as? Int == 30)
        #expect(object["name"] as? String == "Derm")
        #expect(object["channelIds"] as? [String] == [])
        #expect(try APIClient.decoder.decode(AppointmentSearchInput.self, from: data) == input)
    }

    @Test func sendsNoIntervalForOtherSchedules() throws {
        var input = AppointmentSearchInput()
        input.scheduleType = "HOURLY"
        let data = try APIClient.encoder.encode(input)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["scheduleMinutes"] is NSNull)
    }

    @Test func derivesSourcesFromTheSwitches() {
        var input = AppointmentSearchInput()
        #expect(input.sources == "doctolib")
        input.jamedaOn = true
        #expect(input.sources == "both")
        input.doctolibOn = false
        #expect(input.sources == "jameda")
        input.jamedaOn = false
        #expect(input.sources == "none")
    }

    @Test func validatesLikeTheServer() {
        var input = AppointmentSearchInput()
        #expect(AppointmentLogic.problems(input).count == 3) // name, location, Doctolib speciality
        input.name = "Hautarzt"
        input.latitude = "48.1"
        input.longitude = "11.5"
        input.specialitySlug = "dermatologe"
        #expect(AppointmentLogic.problems(input).isEmpty)
        input.jamedaOn = true
        #expect(AppointmentLogic.problems(input) == ["Pick a jameda speciality."])
        input.jamedaOn = false
        input.scheduleType = "CRON"
        input.cron = "*/15 * *"
        #expect(AppointmentLogic.problems(input) == ["A cron expression has five fields (m h dom mon dow)."])
        input.cron = "*/15 * * * *"
        input.dayLimit = 0
        input.maxPages = 21
        #expect(AppointmentLogic.problems(input).count == 2)
        input.dayLimit = 14
        input.maxPages = 3
        input.scheduleType = "MINUTES"
        input.scheduleMinutes = 0
        #expect(AppointmentLogic.problems(input).count == 1)
    }

    @Test func pinsEachProblemToItsField() {
        var input = AppointmentSearchInput()
        #expect(AppointmentLogic.issues(input).map(\.field) == [.name, .location, .doctolibSpeciality])
        input.name = "Hautarzt"
        input.latitude = "48.1"
        input.longitude = "11.5"
        input.specialitySlug = "dermatologe"
        input.scheduleType = "CRON"
        input.cron = "* *"
        input.maxPages = 0
        #expect(AppointmentLogic.issues(input).map(\.field) == [.maxPages, .cron])
    }

    @Test func mapsTheScheduleChoicesToWhatIsStored() throws {
        var input = AppointmentSearchInput()
        // A new search runs every 30 minutes.
        #expect(AppointmentLogic.schedule(of: input) == .every30Minutes)

        let stored: [(AppointmentSchedule, String, Int?)] = [
            (.every5Minutes, "MINUTES", 5), (.every15Minutes, "MINUTES", 15), (.every30Minutes, "MINUTES", 30),
            (.hourly, "HOURLY", nil), (.daily, "DAILY", nil),
        ]
        for (choice, type, minutes) in stored {
            AppointmentLogic.apply(choice, to: &input)
            #expect(input.scheduleType == type)
            if let minutes { #expect(input.scheduleMinutes == minutes) }
            #expect(AppointmentLogic.schedule(of: input) == choice)
        }

        // Another interval: from a preset it keeps the minutes, from hourly/daily it starts at an hour.
        AppointmentLogic.apply(.every15Minutes, to: &input)
        AppointmentLogic.apply(.customInterval, to: &input)
        #expect(input.scheduleType == "MINUTES" && input.scheduleMinutes == 15)
        input.scheduleMinutes = 45
        #expect(AppointmentLogic.schedule(of: input) == .customInterval)
        var daily = AppointmentSearchInput()
        daily.scheduleType = "DAILY"
        daily.scheduleMinutes = nil
        AppointmentLogic.apply(.customInterval, to: &daily)
        #expect(daily.scheduleType == "MINUTES" && daily.scheduleMinutes == 60)

        // Cron keeps its expression, and the stored search sends no interval for it.
        input.cron = "*/15 7-20 * * 1-5"
        AppointmentLogic.apply(.cron, to: &input)
        #expect(input.scheduleType == "CRON" && input.cron == "*/15 7-20 * * 1-5")
        #expect(AppointmentLogic.schedule(of: input) == .cron)
        let object = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(input)) as? [String: Any])
        #expect(object["scheduleMinutes"] is NSNull)
        #expect(object["cron"] as? String == "*/15 7-20 * * 1-5")

        // Every choice is either a preset of the picker or cron (under Advanced).
        #expect(Set(AppointmentSchedule.allCases) == Set(AppointmentSchedule.presets + [.cron]))
    }
}

struct AppointmentLogicTests {
    @Test func summarizesCriteriaAndSchedule() throws {
        var search: AppointmentSearch = try AppointmentSamples.decode(AppointmentSamples.search)
        #expect(AppointmentLogic.criteriaSummary(search) == "Dermatologe · München")
        let both = AppointmentSamples.search
            .replacingOccurrences(of: #""sources":"doctolib""#, with: #""sources":"both""#)
            .replacingOccurrences(of: #""jamedaSpecialityLabel":"""#, with: #""jamedaSpecialityLabel":"Hautarzt""#)
            .replacingOccurrences(of: #""insuranceSector":"""#, with: #""insuranceSector":"public""#)
        search = try AppointmentSamples.decode(both)
        #expect(AppointmentLogic.criteriaSummary(search) == "Doctolib: Dermatologe · jameda: Hautarzt · München · Public")
        #expect(AppointmentLogic.scheduleSummary(enabled: true, type: "MINUTES", minutes: 30, cron: "") == "every 30 min")
        #expect(AppointmentLogic.scheduleSummary(enabled: true, type: "CRON", minutes: nil, cron: "0 8 * * *") == "cron: 0 8 * * *")
        #expect(AppointmentLogic.scheduleSummary(enabled: false, type: "DAILY", minutes: nil, cron: "") == "not scheduled")
    }

    @Test func measuresAndFormatsDistances() throws {
        let km = AppointmentLogic.haversineKm(48.137, 11.575, 52.52, 13.405)
        #expect(abs(km - 504) < 2)
        let en = Locale(identifier: "en_US")
        #expect(AppointmentLogic.formatKm(2.345, locale: en) == "2.3 km")
        #expect(AppointmentLogic.formatKm(12.6, locale: en) == "13 km")
        #expect(AppointmentLogic.formatKm(2.345, locale: Locale(identifier: "de_DE")) == "2,3 km")
        let doctor: AppointmentDoctorSlot = try AppointmentSamples.decode(AppointmentSamples.doctor)
        #expect(AppointmentLogic.distance(of: doctor, homeLat: 48.10, homeLng: 11.58, locale: en) == "4.4 km")
        #expect(AppointmentLogic.distance(of: doctor, homeLat: nil, homeLng: nil) == nil)
    }

    @Test func groupsSlotsByDay() throws {
        let a: AppointmentDoctorSlot = try AppointmentSamples.decode(AppointmentSamples.doctor)
        let later = AppointmentSamples.doctor
            .replacingOccurrences(of: #""resultId":1"#, with: #""resultId":2"#)
            .replacingOccurrences(of: "2026-11-03T12:00:00.000Z", with: "2026-11-05T09:00:00.000Z")
        let b: AppointmentDoctorSlot = try AppointmentSamples.decode(later)
        let sameDay = AppointmentSamples.doctor
            .replacingOccurrences(of: #""resultId":1"#, with: #""resultId":3"#)
            .replacingOccurrences(of: "2026-11-03T12:00:00.000Z", with: "2026-11-03T13:00:00.000Z")
        let c: AppointmentDoctorSlot = try AppointmentSamples.decode(sameDay)
        let groups = AppointmentLogic.groupedByDay([b, c, a])
        #expect(groups.map { $0.slots.map(\.resultId) } == [[1, 3], [2]])
    }

    @Test func buildsLinks() {
        #expect(AppointmentLogic.safeURL("javascript:alert(1)") == nil)
        #expect(AppointmentLogic.safeURL("HTTPS://x.example/a") != nil)
        #expect(AppointmentLogic.googleSearchURL(["Dr A", " ", "Hauptstr. 1"]).absoluteString == "https://www.google.com/search?q=Dr%20A%20Hauptstr.%201")
        #expect(AppointmentLogic.citySlug("München, Deutschland") == "muenchen")
        #expect(AppointmentLogic.citySlug("Bad Tölz") == "bad-toelz")

        var input = AppointmentSearchInput()
        #expect(AppointmentLogic.doctolibPreviewURL(input) == nil)
        input.specialitySlug = "dermatologe"
        input.latitude = "48.1"
        input.longitude = "11.5"
        input.insuranceSector = "public"
        let doctolib = AppointmentLogic.doctolibPreviewURL(input)?.absoluteString
        #expect(doctolib == "https://www.doctolib.de/search?around_me=true&keyword=dermatologe&latitude=48.1&longitude=11.5&insuranceSector=public")

        input.locationLabel = "München, Bayern"
        input.jamedaSpecialityType = "specialization"
        input.jamedaSpecialitySlug = "hautarzt"
        #expect(AppointmentLogic.jamedaPreviewURL(input)?.absoluteString == "https://www.jameda.de/hautarzt/muenchen")
        input.jamedaSpecialityType = "leistung"
        input.jamedaSpecialityLabel = "Akne"
        input.jamedaKidsFriendly = true
        let jameda = AppointmentLogic.jamedaPreviewURL(input)
        let items = URLComponents(url: jameda!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.map(\.name) == ["q", "loc", "filters[kids_friendly][]"])
        #expect(items.first?.value == "Akne")
        #expect(items[1].value == "München")
    }

    @Test func prefillsAndFormatsBookings() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let slot = Date(timeIntervalSince1970: 1_793_707_200) // 2026-11-03T12:00Z = 13:00 in Berlin
        let parts = AppointmentLogic.localParts(slot, calendar: calendar)
        #expect(parts.date == "2026-11-03")
        #expect(parts.time == "13:00")
        let back = AppointmentLogic.date(day: "2026-11-03", time: "13:00", calendar: calendar)
        #expect(back == slot)
        #expect(AppointmentLogic.formatBooking(date: "nonsense", start: nil) == "nonsense")
        #expect(AppointmentLogic.formatBooking(date: "2026-11-03", start: "09:30").hasSuffix(", 09:30"))
    }

    @Test func encodesTheBooking() throws {
        let input = AppointmentBookingInput(date: "2026-11-03", start: "09:30", end: nil, person: "Oma", note: "", stopSearch: true)
        let object = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(input)) as? [String: Any])
        #expect(object["date"] as? String == "2026-11-03")
        #expect(object["end"] == nil)
        #expect(object["stopSearch"] as? Bool == true)
    }

    @Test func takesItsAppRoutes() {
        #expect(AppointmentRoute.from(.appointmentSearch(id: "s1")) == .push(.search("s1")))
        #expect(AppointmentRoute.from(.appointmentSlot(searchID: "s1", resultID: "42")) == .push(.slot(searchID: "s1", resultID: 42)))
        // A result id that isn't a number (a broken link) still shows its search.
        #expect(AppointmentRoute.from(.appointmentSlot(searchID: "s1", resultID: "x")) == .push(.search("s1")))
        #expect(AppointmentRoute.from(.newAppointmentSearch) == .newSearch)
        #expect(AppointmentRoute.from(.module(.appointments)) == .list)
        // Web links (and notifications' deep links) reach the same pages.
        let parsed = AppRoute.parse(webPath: "/f/fam/appointments/s1/slots/42")
        #expect(parsed?.route == .appointmentSlot(searchID: "s1", resultID: "42"))
    }

    @Test func linksBookingsToTheirDay() {
        #expect(AppointmentLogic.calendarRoute(date: "2026-11-03") == .calendarDay(Day(year: 2026, month: 11, day: 3)))
        #expect(AppointmentLogic.calendarRoute(date: "nope") == .module(.calendar))
    }

    @Test func refreshesLikeTheWeb() {
        #expect(AppointmentRefresh.interval(busy: true) == .seconds(3))
        #expect(AppointmentRefresh.interval(busy: false) == .seconds(45))
    }

    @Test func countsWithPlurals() {
        #expect(String(AppointmentLogic.moreDoctors(1).characters) == "1 more doctor")
        #expect(String(AppointmentLogic.moreDoctors(4).characters) == "4 more doctors")
        #expect(String(AppointmentLogic.runCounts(found: 3, matched: 2, slots: 1).characters) == "3 found · 2 matching · 1 appointment")
        #expect(String(AppointmentLogic.runCounts(found: 3, matched: 2, slots: 5).characters) == "3 found · 2 matching · 5 appointments")
    }
}

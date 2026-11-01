import Foundation
import Testing
@testable import Ohana

/// The week ahead: the digest's and the overview's JSON, the sentences per kind, the page's
/// groups, the route and the demo.
struct WeekAheadTests {
    private static func decode<T: Decodable>(_ json: String, as: T.Type = T.self) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static let digestJSON = """
    {"from":"2026-11-01","to":"2026-11-14","geocoding":true,
     "people":[{"id":"u1","name":"Anna","account":true,"child":false,"events":3},
               {"id":"p1","name":"Mia","account":false,"child":true,"events":5},
               {"id":"p2","name":"Leo","account":false,"child":true,"events":0}],
     "issues":[
       {"key":"overlap:e1@2026-11-03+e2@2026-11-03","kind":"overlap","severity":"conflict","date":"2026-11-03",
        "people":[{"id":"p1","name":"Mia"}],
        "events":[{"id":"e1","occurrence":null,"title":"Dentist","date":"2026-11-03","endDate":"2026-11-03","start":"16:00","end":"17:00","location":"Praxis"},
                  {"id":"e2","occurrence":"2026-11-03","title":"Swimming","date":"2026-11-03","endDate":"2026-11-03","start":"16:30","end":"17:30","location":""}],
        "data":{"minutes":30},"dismissed":false},
       {"key":"unassigned_overlap:e3+e4","kind":"unassigned_overlap","severity":"info","date":"2026-11-04","people":[],
        "events":[{"id":"e3","title":"Parents' evening","date":"2026-11-04","start":"19:00","end":null,"location":""},
                  {"id":"e4","title":"Choir","date":"2026-11-04","start":"19:30","end":"21:00","location":""}],
        "data":{"minutes":45},"dismissed":false},
       {"key":"meal_clash:x","kind":"meal_clash","severity":"urgent","date":"2026-11-05",
        "people":[{"id":null,"name":"Uncle Tom"}],"events":[{"id":"e5","title":"Lasagne","date":"2026-11-05"}],
        "data":{"whatever":[1,2]},"dismissed":false},
       {"key":"packed_day:u1@2026-11-06","kind":"packed_day","severity":"warning","date":"2026-11-06",
        "people":[{"id":"u1","name":"Anna"},{"id":"p1","name":"Mia"}],"events":[],"data":{"events":4,"hours":9.5},"dismissed":true}
     ],
     "away":[{"from":"2026-11-12","to":"2026-11-14","names":["Vacation"]}],
     "birthdays":[{"day":"2026-11-09","name":"Grandma Rose","age":74}]}
    """

    // MARK: Decoding

    @Test func decodesTheDigestWithUnknownKindsAndSeverities() throws {
        let digest = try Self.decode(Self.digestJSON, as: WeekAheadDigest.self)
        #expect(digest.from == Day("2026-11-01") && digest.to == Day("2026-11-14") && digest.geocoding)
        #expect(digest.people.map(\.name) == ["Anna", "Mia", "Leo"])
        #expect(digest.people[1].child && !digest.people[1].account && digest.people[1].events == 5)
        #expect(digest.issues.map(\.kind) == ["overlap", "unassigned_overlap", "meal_clash", "packed_day"])
        let overlap = digest.issues[0]
        #expect(overlap.severity == .conflict && overlap.date == Day("2026-11-03"))
        #expect(overlap.events[1].occurrence == Day("2026-11-03") && overlap.events[0].occurrence == nil)
        #expect(overlap.events[0].line == "16:00–17:00 Dentist")
        #expect(overlap.data["minutes"]?.doubleValue == 30)
        // A newer server's kind and severity still decode: shown generically, as info.
        let unknown = digest.issues[2]
        #expect(unknown.severity == .info && unknown.people.first?.id == nil)
        #expect(unknown.events[0].location == "" && unknown.events[0].start == nil)
        #expect(unknown.sentence == "Worth a look: Lasagne")
        #expect(digest.issues[1].people.isEmpty && digest.issues[3].dismissed)
        #expect(digest.away.first?.names == ["Vacation"])
        #expect(digest.birthdays == [OverviewBirthday(day: Day("2026-11-09")!, name: "Grandma Rose", age: 74)])
    }

    @Test func decodesAMinimalDigest() throws {
        let digest = try Self.decode(#"{"from":"2026-11-01","to":"2026-11-14"}"#, as: WeekAheadDigest.self)
        #expect(!digest.geocoding && digest.people.isEmpty && digest.issues.isEmpty && digest.away.isEmpty && digest.birthdays.isEmpty)
        let issue = try Self.decode(#"{"key":"k","kind":"overlap","date":"2026-11-02"}"#, as: WeekAheadIssue.self)
        #expect(issue.severity == .info && issue.events.isEmpty && !issue.dismissed && issue.data == .object([:]))
    }

    @Test func overviewHasTheWeekAheadOnlyWhenTheServerSendsIt() throws {
        let base = #""today":"2026-11-01","calendar":{"nextGap":null,"upcoming":[]},"awayToday":[],"todayEvents":[],"upcoming":[],"birthdays":[]"#
        let old = try Self.decode("{\(base)}", as: OverviewDashboard.self)
        #expect(old.weekAhead == nil)
        let new = try Self.decode("""
        {\(base),"weekAhead":{"conflicts":1,"warnings":2,"top":[{"key":"k","kind":"short_night","severity":"warning","date":"2026-11-03",
          "people":[{"id":"u1","name":"Anna"}],"events":[],"data":{"hours":7.5},"dismissed":false}]}}
        """, as: OverviewDashboard.self)
        let summary = try #require(new.weekAhead)
        #expect(summary.conflicts == 1 && summary.warnings == 2 && summary.hasIssues)
        #expect(summary.top.first?.sentence == "Only 7.5 hours of night" && summary.top.first?.names == "Anna")
        let quiet = try Self.decode("{\(base),\"weekAhead\":{\"conflicts\":0,\"warnings\":0,\"top\":[]}}", as: OverviewDashboard.self)
        #expect(quiet.weekAhead?.hasIssues == false)
    }

    // MARK: Sentences

    private func issue(_ kind: String, _ data: [String: JSONValue] = [:], events: [String] = [],
                       people: [String] = []) -> WeekAheadIssue {
        WeekAheadIssue(key: kind, kind: kind, severity: .warning, date: Day("2026-11-03")!,
                       people: people.map { .init(id: $0.lowercased(), name: $0) },
                       events: events.map { .init(id: $0, title: $0, date: Day("2026-11-03")!) },
                       data: .object(data))
    }

    @Test func overlaps() {
        #expect(issue("overlap", ["minutes": .number(30)], events: ["Dentist", "Swimming"]).sentence
            == "Dentist and Swimming overlap by 30 min")
        #expect(issue("overlap", ["minutes": .number(90)], events: ["Dentist", "Swimming"]).sentence
            == "Dentist and Swimming overlap by 1 h 30 min")
        #expect(issue("overlap", [:], events: ["Dentist", "Swimming"]).sentence == "Dentist and Swimming overlap")
        // Missing an event: the generic text.
        #expect(issue("overlap", ["minutes": .number(30)], events: ["Dentist"]).sentence == "Worth a look: Dentist")
        #expect(issue("unassigned_overlap", ["minutes": .number(45)], events: ["Parents' evening", "Choir"]).sentence
            == "Parents' evening and Choir overlap by 45 min: who goes?")
    }

    @Test func tightTransfers() {
        let events = ["School play", "Football"]
        #expect(issue("tight_transfer", ["gapMinutes": .number(10), "travelMinutes": .number(25), "km": .number(14.2)],
                      events: events).sentence
            == "Only 10 min from School play to Football — about 25 min on the road (14 km)")
        #expect(issue("tight_transfer", ["gapMinutes": .number(5), "travelMinutes": .number(24), "km": .number(6.8)],
                      events: events).sentence
            == "Only 5 min from School play to Football — about 25 min on the road (6.8 km)")
        #expect(issue("tight_transfer", ["gapMinutes": .number(10), "travelMinutes": .number(12), "km": .null],
                      events: events).sentence
            == "Only 10 min from School play to Football — about 12 min on the road")
        // Without places looked up: only that they differ.
        #expect(issue("tight_transfer", ["gapMinutes": .number(10), "travelMinutes": .null, "km": .null], events: events).sentence
            == "Only 10 min from School play to Football — somewhere else")
        #expect(issue("tight_transfer", ["gapMinutes": .number(0), "travelMinutes": .number(20)], events: events).sentence
            == "No time between School play and Football — about 20 min on the road")
    }

    @Test func tripsDaysAndTravel() {
        #expect(issue("during_trip", events: ["Class trip", "Piano lesson"]).sentence == "Piano lesson during Class trip")
        #expect(issue("packed_day", ["events": .number(4), "hours": .number(9.5)]).sentence == "4 events, 9.5 hours booked")
        #expect(issue("packed_day", ["events": .number(1)]).sentence == "1 event in one day")
        #expect(issue("long_travel_day", ["km": .number(210), "minutes": .number(180)]).sentence
            == "About 3 h on the road (210 km)")
        #expect(issue("long_travel_day", ["km": .number(252), "minutes": .number(218)]).sentence
            == "About 3 h 40 min on the road (252 km)")
        #expect(issue("long_travel_day", ["km": .number(205)]).sentence == "About 205 km on the road")
        let week = Day("2026-11-09")!.formatted(.dateTime.day().month(.abbreviated))
        #expect(issue("travel_week", ["days": .number(3), "weekStart": .string("2026-11-09")]).sentence
            == "Far from home on 3 days in the week of \(week)")
        #expect(issue("travel_week", ["days": .number(3)]).sentence == "Far from home on 3 days in one week")
        #expect(issue("short_night", ["hours": .number(7.5)], events: ["Concert", "School"]).sentence
            == "Only 7.5 hours between Concert and School")
        #expect(issue("short_night", ["hours": .number(8)]).sentence == "Only 8 hours of night")
    }

    @Test func awayDriversAndBirthdays() {
        let dates: JSONValue = .array([.string("2026-11-12"), .string("2026-11-13"), .string("2026-11-14")])
        #expect(issue("away_clash", ["away": .string("Vacation"), "dates": dates], events: ["Swimming lesson"]).sentence
            == "Away (Vacation) — Swimming lesson on 3 days")
        #expect(issue("away_clash", ["away": .string("Vacation"), "dates": .array([.string("2026-11-12")])],
                      events: ["Swimming lesson"]).sentence == "Away (Vacation) — Swimming lesson")
        #expect(issue("drivers_needed", ["children": .number(2), "adults": .number(1)]).sentence
            == "2 children at once, 1 adult free")
        #expect(issue("drivers_needed", ["children": .number(3), "adults": .number(0)]).sentence
            == "3 children at once, no adult free")
        #expect(issue("birthday_away", ["name": .string("Grandma Rose"), "age": .number(74)]).sentence
            == "Away when Grandma Rose turns 74")
        #expect(issue("birthday_away", ["name": .string("Grandma Rose")]).sentence == "Away on Grandma Rose’s birthday")
    }

    @Test func unknownKindsListTheirEvents() {
        #expect(issue("meal_clash", ["x": .number(1)], events: ["Lasagne", "Late meeting"]).sentence
            == "Worth a look: Lasagne and Late meeting")
        #expect(issue("meal_clash").sentence == "Worth a look")
        #expect(WeekAheadText.title(kind: "meal_clash") == "Worth a look")
        #expect(WeekAheadText.title(kind: "drivers_needed") == "Drivers needed")
    }

    @Test func durations() {
        #expect(WeekAheadText.duration(0) == "0 min")
        #expect(WeekAheadText.duration(60) == "1 h")
        #expect(WeekAheadText.duration(125) == "2 h 5 min")
        #expect(WeekAheadText.about(12) == 12 && WeekAheadText.about(24) == 25 && WeekAheadText.about(218) == 220)
        #expect(WeekAheadText.kilometers(6.84) == "6.8" && WeekAheadText.kilometers(14.4) == "14")
    }

    // MARK: Groups

    @Test func groupsByPersonThenUnassigned() throws {
        let digest = try Self.decode(Self.digestJSON, as: WeekAheadDigest.self)
        let groups = WeekAheadGroups(digest)
        // Mia (overlap), the name the family doesn't know, then the unassigned; Anna's only issue is hidden.
        #expect(groups.groups.map(\.id) == ["p1", "name:Uncle Tom", ""])
        #expect(groups.groups[0].person?.name == "Mia" && groups.groups[0].issues.map(\.kind) == ["overlap"])
        #expect(groups.groups[1].name == "Uncle Tom" && groups.groups[1].person == nil)
        #expect(groups.groups[2].person == nil && groups.groups[2].name == nil
            && groups.groups[2].issues.map(\.kind) == ["unassigned_overlap"])
        #expect(groups.clear.map(\.name) == ["Anna", "Leo"])
        #expect(groups.hidden.map(\.kind) == ["packed_day"])
        #expect(!groups.isClear)
    }

    @Test func anIssueAboutTwoShowsUnderBoth() {
        let digest = WeekAheadDigest(
            from: Day("2026-11-01")!, to: Day("2026-11-14")!, geocoding: true,
            people: [WeekAheadPerson(id: "a", name: "Leo", account: false, child: true, events: 1),
                     WeekAheadPerson(id: "b", name: "Mia", account: false, child: true, events: 1)],
            issues: [WeekAheadIssue(key: "d", kind: "drivers_needed", severity: .warning, date: Day("2026-11-03")!,
                                    people: [.init(id: "a", name: "Leo"), .init(id: nil, name: "mia")])],
            away: [], birthdays: [])
        let groups = WeekAheadGroups(digest)
        #expect(groups.groups.map(\.id) == ["a", "b"] && groups.clear.isEmpty)
        let none = WeekAheadGroups(WeekAheadDigest(from: digest.from, to: digest.to, geocoding: false, people: digest.people,
                                                   issues: [], away: [], birthdays: []))
        #expect(none.isClear && none.clear.count == 2)
    }

    // MARK: Routes and actions

    @Test func routes() {
        #expect(AppRoute.parse(webPath: "/f/fam1/digest")?.route == .weekAhead)
        #expect(AppRoute.parse(webPath: "/f/fam1/digest")?.familyID == "fam1")
        #expect(AppRoute.weekAhead.module == .overview && AppRoute.weekAhead.requiredModule == .overview)
        let pref = FamilyEventPref(event: "weekly_digest", enabled: true, channelIds: nil, hasChannels: true)
        #expect(pref.module == .calendar)
    }

    @Test func restoringEncodesTheKeyAsOneSegment() {
        let base = URL(string: "https://ohana.test/api/v1/families/f1/digest/dismiss")!
        #expect(WeekAheadActions.restoreURL(base, key: "overlap:e1@2026-11-03+e2@2026-11-03").absoluteString
            == "https://ohana.test/api/v1/families/f1/digest/dismiss/overlap:e1@2026-11-03+e2@2026-11-03")
        #expect(WeekAheadActions.restoreURL(base, key: "a/b?c d").absoluteString
            == "https://ohana.test/api/v1/families/f1/digest/dismiss/a%2Fb%3Fc%20d")
    }

    // MARK: Demo

    static let today = Day(year: 2026, month: 10, day: 30)
    static let server = DemoServer(today: { today }, now: { Date(timeIntervalSince1970: 1_793_354_400) })

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type) throws -> T {
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo" + path)
        if !query.isEmpty { url.append(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        let (data, response) = Self.server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200, "GET \(path)")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    @Test func demoDigestMatchesTheDemoFamily() throws {
        let digest = try get("/digest", query: ["today": Self.today.description], as: WeekAheadDigest.self)
        #expect(digest.from == Self.today && digest.to == Self.today.adding(days: 13))
        #expect(digest.people.map(\.name) == ["Anna Parker", "Ben Parker", "Grandma Rose", "Leo", "Mia"])
        #expect(digest.people.filter(\.child).map(\.name) == ["Leo", "Mia"])
        #expect(digest.issues.map(\.date) == digest.issues.map(\.date).sorted())
        #expect(digest.issues.first?.severity == .conflict)
        #expect(digest.issues.first?.sentence
            == "Only 10 min from Football training to Piano lesson — about 25 min on the road (6.8 km)")
        #expect(digest.issues.filter(\.dismissed).count == 1)
        // Grandma Rose's birthday (in ten days) while Mia is on her class trip, with her age.
        #expect(digest.birthdays.map(\.name) == ["Grandma Rose"] && digest.birthdays.first?.day == Self.today.adding(days: 10))
        let birthday = try #require(digest.issues.first { $0.kind == "birthday_away" })
        #expect(birthday.sentence == "Away when Grandma Rose turns 74" && birthday.date == digest.birthdays.first?.day)
        #expect(digest.away.first?.from == Self.today.adding(days: 12) && digest.away.first?.names == ["Vacation"])

        // The issues' events are the calendar's, on their days.
        let calendar = try get("/events", query: ["from": digest.from.description, "to": digest.to.description],
                               as: CalendarEventsResponse.self)
        for issue in digest.issues {
            for event in issue.events {
                #expect(calendar.events.contains { $0.id == event.id && $0.date == event.date }, "\(issue.key) \(event.id)")
            }
            for person in issue.people {
                #expect(digest.people.contains { $0.id == person.id && $0.name == person.name })
            }
        }

        let groups = WeekAheadGroups(digest)
        #expect(groups.groups.map { $0.person?.name } == ["Leo", "Mia"])
        #expect(groups.clear.map(\.name) == ["Anna Parker", "Ben Parker", "Grandma Rose"])
    }

    @Test func demoOverviewSumsUpTheWeekAhead() throws {
        let overview = try get("/overview", query: ["today": Self.today.description], as: OverviewDashboard.self)
        let digest = try get("/digest", query: ["today": Self.today.description], as: WeekAheadDigest.self)
        let summary = try #require(overview.weekAhead)
        let open = digest.issues.filter { !$0.dismissed }
        #expect(summary.conflicts == open.filter { $0.severity == .conflict }.count && summary.conflicts == 1)
        #expect(summary.warnings == open.filter { $0.severity == .warning }.count && summary.warnings == 2)
        #expect(summary.top.map(\.key) == open.prefix(3).map(\.key))
    }

    @Test func demoIsReadOnly() {
        var request = URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/digest/dismiss"))
        request.httpMethod = "POST"
        #expect(Self.server.respond(to: request).1.statusCode == 403)
    }
}

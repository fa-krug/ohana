import Foundation
import Testing
@testable import Ohana

/// The chores' answers as the server sends them (the contract's JSON), their sections and text.
struct ChoreModelTests {
    static let json = """
    {"chores":[
      {"id":"c1","title":"Bins","note":"","assignee":{"id":"u1","name":"Ben","account":true},"day":"2026-10-20","time":"19:00","part":"evening","rrule":"FREQ=WEEKLY","done":false,"doneAt":null,"doneBy":null,"next":"2026-11-03","subscriberIds":["u1","u2"],"subscribed":true,"createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z"},
      {"id":"c2","title":"Car service","note":"Garage","assignee":null,"day":"2026-11-01","time":null,"part":"morning","rrule":null,"done":false,"doneAt":null,"doneBy":null,"next":"2026-11-01","subscriberIds":[],"subscribed":false,"createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-02T10:00:00.000Z"},
      {"id":"c3","title":"Windows","note":"","assignee":{"id":"p1","name":"Mia","account":false},"day":"2026-10-30","time":null,"part":"day","rrule":null,"done":true,"doneAt":"2026-10-31T08:00:00.000Z","doneBy":{"id":"u1","name":"Ben","account":true},"next":null,"subscriberIds":["u1"],"subscribed":true,"createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z"}
    ],"people":[{"id":"u1","name":"Ben","account":true},{"id":"p1","name":"Mia","account":false}],"canEdit":true}
    """

    static let agendaJSON = """
    {"days":[
      {"date":"2026-11-01","items":[
        {"choreId":"c2","day":"2026-11-01","title":"Car service","note":"Garage","assignee":null,"part":"morning","time":null,"repeating":false,"done":false,"doneAt":null,"doneBy":null,"subscribed":false},
        {"choreId":"c4","day":"2026-11-01","title":"Plants","note":"","assignee":null,"part":"morning","time":"07:30","repeating":true,"done":true,"doneAt":"2026-11-01T07:00:00.000Z","doneBy":{"id":"u1","name":"Ben","account":true},"subscribed":true},
        {"choreId":"c1","day":"2026-11-01","title":"Bins","note":"","assignee":{"id":"u1","name":"Ben","account":true},"part":"evening","time":"19:00","repeating":true,"done":false,"doneAt":null,"doneBy":null,"subscribed":true}
      ]},
      {"date":"2026-11-02","items":[]}
    ],"overdue":[
      {"choreId":"c5","day":"2026-10-28","title":"Letter","note":"","assignee":null,"part":"day","time":null,"repeating":false,"done":false,"doneAt":null,"doneBy":null,"subscribed":false}
    ]}
    """

    @Test func decodesThePage() throws {
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        #expect(page.canEdit)
        #expect(page.people.map(\.id) == ["u1", "p1"])
        #expect(page.people[1].account == false)
        let bins = page.chores[0]
        #expect(bins.isRepeating && bins.rule == RepeatRule(.weekly))
        #expect(bins.day == Day("2026-10-20") && bins.next == Day("2026-11-03") && bins.time == "19:00")
        #expect(bins.part == .evening && bins.subscriberIds == ["u1", "u2"] && bins.subscribed)
        #expect(bins.assignee?.name == "Ben")
        let car = page.chores[1]
        #expect(!car.isRepeating && car.assignee == nil && car.note == "Garage" && car.part == .morning && !car.subscribed)
        let windows = page.chores[2]
        #expect(windows.done && windows.next == nil && windows.doneDate != nil && windows.doneBy?.id == "u1")
        let one = try APIClient.decoder.decode(ChoreResponse.self, from: Data(#"{"chore":\#(Self.choreJSON)}"#.utf8))
        #expect(one.chore.id == "c9")
        // Without the new fields (an older server): the part from the time, else the day; nobody notified.
        #expect(one.chore.part == .day && one.chore.subscriberIds.isEmpty && !one.chore.subscribed && one.chore.doneBy == nil)
        let timed = try APIClient.decoder.decode(Chore.self, from: Data(Self.choreJSON.replacingOccurrences(of: #""time":null"#, with: #""time":"18:30""#).utf8))
        #expect(timed.part == .evening)
        // A part the app doesn't know: the day.
        let odd = try APIClient.decoder.decode(Chore.self, from: Data(Self.choreJSON.replacingOccurrences(of: #""rrule":null"#, with: #""rrule":null,"part":"night""#).utf8))
        #expect(odd.part == .day)
    }

    static let choreJSON = #"{"id":"c9","title":"T","note":"","assignee":null,"day":"2026-11-01","time":null,"rrule":null,"done":false,"doneAt":null,"next":"2026-11-01","createdAt":"x","updatedAt":"x"}"#

    @Test func decodesTheAgenda() throws {
        let agenda = try APIClient.decoder.decode(ChoreAgenda.self, from: Data(Self.agendaJSON.utf8))
        #expect(agenda.days.map(\.date) == [Day("2026-11-01")!, Day("2026-11-02")!])
        let items = try #require(agenda.items(on: Day("2026-11-01")!))
        #expect(items.map(\.choreId) == ["c2", "c4", "c1"])
        let plants = items[1]
        #expect(plants.repeating && plants.done && plants.doneBy?.name == "Ben" && plants.subscribed && plants.time == "07:30")
        #expect(plants.id == "c4@2026-11-01")
        #expect(agenda.items(on: Day("2026-11-02")!) == [])
        #expect(agenda.items(on: Day("2026-11-03")!) == nil)
        #expect(agenda.covers(Day("2026-11-02")!) && !agenda.covers(Day("2026-10-31")!))
        #expect(agenda.overdue.map(\.choreId) == ["c5"])
        // An item without a part (an older server): from its time.
        let item = try APIClient.decoder.decode(ChoreItem.self, from: Data(#"{"choreId":"c","day":"2026-11-01","title":"T","assignee":null,"time":"08:00","repeating":false,"done":false}"#.utf8))
        #expect(item.part == .morning && !item.subscribed && item.note.isEmpty)
    }

    @Test func updatesTheItemsOfAChore() throws {
        var agenda = try APIClient.decoder.decode(ChoreAgenda.self, from: Data(Self.agendaJSON.utf8))
        agenda.update(choreID: "c1") { $0.subscribed = false }
        #expect(agenda.items(on: Day("2026-11-01")!)?.first { $0.choreId == "c1" }?.subscribed == false)
        agenda.update(choreID: "c5", day: Day("2026-10-28")) { $0.done = true }
        #expect(agenda.overdue[0].done)
        agenda.update(choreID: "c2", day: Day("2026-11-02")) { $0.done = true }
        #expect(agenda.items(on: Day("2026-11-01")!)?.first?.done == false)
    }

    @Test func groupsByPartOfTheDay() throws {
        let day = Day("2026-11-01")!
        let items = [
            ChoreItem(choreId: "a", day: day, title: "Zebra", part: .evening),
            ChoreItem(choreId: "b", day: day, title: "Bins", assignee: ChorePerson(id: "u1", name: "Ben", account: true), part: .evening, time: "19:00"),
            ChoreItem(choreId: "c", day: day, title: "apples", part: .evening),
            ChoreItem(choreId: "d", day: day, title: "Swim bag", part: .morning, time: "07:30"),
            ChoreItem(choreId: "e", day: day, title: "Cat", part: .morning, time: "06:45"),
        ]
        let parts = ChoreParts.items(items)
        #expect(parts.map(\.part) == [.morning, .evening])
        #expect(parts[0].items.map(\.choreId) == ["e", "d"])
        // No time first, then by time, then title.
        #expect(parts[1].items.map(\.choreId) == ["c", "a", "b"])
        #expect(ChoreParts.items(items, filter: .person("u1")).map(\.part) == [.evening])
        #expect(ChoreParts.items(items, filter: .nobody).flatMap(\.items).count == 4)
        #expect(ChoreParts.items(items, filter: .person("x")).isEmpty)
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        let all = ChoreParts.chores(page.chores)
        #expect(all.map(\.part) == [.morning, .day, .evening])
        #expect(all.map { $0.items.map(\.id) } == [["c2"], ["c3"], ["c1"]])
    }

    @Test func thePartFollowsTheTime() {
        #expect(ChorePart.of(time: "00:00") == .morning)
        #expect(ChorePart.of(time: "11:59") == .morning)
        #expect(ChorePart.of(time: "12:00") == .day)
        #expect(ChorePart.of(time: "16:59") == .day)
        #expect(ChorePart.of(time: "17:00") == .evening)
        #expect(ChorePart.of(time: "23:30") == .evening)
        #expect(ChorePart.of(time: "soon") == nil)
        var draft = ChoreDraft.new(on: Day("2026-11-01")!)
        draft.input.part = .evening
        draft.setTimed(true)
        #expect(draft.input.time == "18:00" && draft.input.effectivePart == .evening)
        draft.setTime("08:15")
        #expect(draft.input.part == .morning && draft.input.effectivePart == .morning)
        // A part chosen while there's a time doesn't count; without the time the part stays.
        draft.input.part = .evening
        #expect(draft.input.effectivePart == .morning)
        draft.setTimed(false)
        draft.input.part = .day
        #expect(draft.input.time == nil && draft.input.effectivePart == .day)
    }

    @Test func encodesTheInputWithNulls() throws {
        let input = ChoreInput(title: "Bins", day: Day("2026-11-03")!)
        let json = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(input)) as? [String: Any])
        #expect(json["title"] as? String == "Bins")
        #expect(json["day"] as? String == "2026-11-03")
        #expect(json["note"] as? String == "")
        #expect(json["part"] as? String == "day")
        #expect(json["subscriberIds"] as? [String] == [])
        // Sent as null, so an edit clears them.
        #expect(json["assigneeId"] is NSNull && json["time"] is NSNull && json["rrule"] is NSNull)
        let full = ChoreInput(title: "T", assigneeId: "u1", day: Day("2026-11-03")!, time: "07:30", part: .evening,
                              rrule: "FREQ=DAILY", subscriberIds: ["u1", "u2"])
        let back = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(full)) as? [String: Any])
        #expect(back["assigneeId"] as? String == "u1" && back["time"] as? String == "07:30" && back["rrule"] as? String == "FREQ=DAILY")
        // The time decides the part.
        #expect(back["part"] as? String == "morning")
        #expect(back["subscriberIds"] as? [String] == ["u1", "u2"])
        // An edit starts from the chore.
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        let edit = ChoreInput(page.chores[0])
        #expect(edit.subscriberIds == ["u1", "u2"] && edit.part == .evening && edit.assigneeId == "u1")
    }

    @Test func encodesDoneAndSubscribe() throws {
        func object(_ value: some Encodable) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(value)) as? [String: Any])
        }
        let day = Day("2026-11-01")!
        // A repeating chore's occurrence names its day.
        let repeating = ChoreItem(choreId: "c1", day: day, title: "Bins", repeating: true)
        let done = try object(ChoreDoneBody(toggling: repeating))
        #expect(done["done"] as? Bool == true && done["day"] as? String == "2026-11-01")
        var ticked = repeating
        ticked.done = true
        #expect(try object(ChoreDoneBody(toggling: ticked))["done"] as? Bool == false)
        // A single chore's has none.
        let single = try object(ChoreDoneBody(toggling: ChoreItem(choreId: "c2", day: day, title: "Car")))
        #expect(single["done"] as? Bool == true && single["day"] == nil)
        let subscribe = try object(ChoreSubscribeBody(subscribed: false))
        #expect(subscribe.count == 1 && subscribe["subscribed"] as? Bool == false)
        // Before the server answers.
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        let off = page.chores[0].subscribing(false, me: "u1")
        #expect(!off.subscribed && off.subscriberIds == ["u2"])
        #expect(off.subscribing(true, me: "u1").subscriberIds == ["u2", "u1"])
    }

    @Test func readsTheSchedule() throws {
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        let today = Day("2026-11-01")!
        let en = Locale(identifier: "en_US")
        #expect(ChoreText.when(today, time: nil, today: today) == "Today")
        #expect(ChoreText.when(today.adding(days: 1), time: "07:30", today: today) == "Tomorrow, 07:30")
        #expect(ChoreText.schedule(page.chores[0], today: today, locale: en).hasPrefix("Weekly, next "))
    }

    @Test func linksOpenTheChoreOnItsDay() {
        #expect(AppRoute.parse(webPath: "/f/fam/chores")?.route == .module(.chores))
        #expect(AppRoute.parse(webPath: "/f/fam/chores/c1")?.route == .chore(id: "c1"))
        #expect(AppRoute.parse(webPath: "/f/fam/chores/c1", day: "2026-11-05")?.route == .chore(id: "c1", day: Day("2026-11-05")))
        #expect(AppRoute.parse(webPath: "/f/fam/chores/c1", day: "soon")?.route == .chore(id: "c1"))
        #expect(AppRoute.parse(webPath: "/f/fam/chores/new")?.route == .newChore)
        #expect(AppRoute.chore(id: "c1").requiredModule == .chores)
    }

    @Test func theAgendaLoadsAboutTwoMonthsAtATime() {
        let today = Day("2026-11-02")!
        let current = ChoreAgenda.window(around: today, today: today)
        #expect(current.from == Day("2026-10-03") && current.to == Day("2026-12-03"))
        // Every day of a window has it; the server answers at most 62 days.
        #expect(CalendarMath.range(current.from, current.to).count == 62)
        for offset in -30...31 {
            #expect(ChoreAgenda.window(around: today.adding(days: offset), today: today) == current, "\(offset)")
        }
        #expect(ChoreAgenda.window(around: Day("2026-12-04")!, today: today) == (Day("2026-12-04")!, Day("2027-02-03")!))
        #expect(ChoreAgenda.window(around: Day("2026-10-02")!, today: today) == (Day("2026-08-02")!, Day("2026-10-02")!))
    }

    @Test func theDraftRepeatsLikeAnEvent() {
        var draft = ChoreDraft.new(on: Day("2026-11-01")!, for: "u1")
        #expect(draft.input.assigneeId == "u1")
        #expect(draft.problem != nil)
        draft.input.title = "  Bins "
        #expect(draft.problem == nil)
        #expect(draft.cleaned.title == "Bins")
        draft.setRepeat(.biweekly)
        #expect(draft.input.rrule == "FREQ=WEEKLY;INTERVAL=2")
        draft.setRepeatEnd(.until(Day("2026-10-01")!))
        #expect(draft.repeatProblem != nil)
        draft.setRepeat(.never)
        #expect(draft.input.rrule == nil && draft.problem == nil)
    }

    @Test func aNewChoreNotifiesItsAuthor() {
        let draft = ChoreDraft.new(on: Day("2026-11-01")!, for: "p1", me: "u1")
        #expect(draft.input.subscriberIds == ["u1"])
        #expect(ChoreDraft.new(on: Day("2026-11-01")!).input.subscriberIds.isEmpty)
        var edit = draft
        edit.setNotified("u2", true)
        edit.setNotified("u1", false)
        edit.setNotified("u2", true)
        #expect(edit.input.subscriberIds == ["u2"])
    }
}

/// The demo has chores for its people.
@MainActor
struct DemoChoresTests {
    private let today = Day(year: 2026, month: 10, day: 30)

    private var server: DemoServer {
        var server = DemoServer()
        let today = today
        server.today = { today }
        server.now = { Day.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))! }
        return server
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) throws -> T {
        var components = URLComponents(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let (data, response) = server.respond(to: URLRequest(url: components.url!))
        #expect(response.statusCode == 200, "\(path): \(String(decoding: data, as: UTF8.self))")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    @Test func listsTheChores() throws {
        let page: ChoresPage = try get("/chores")
        #expect(!page.canEdit)
        #expect(page.people.contains { $0.id == "demo-user" })
        #expect(page.chores.count == 8)
        #expect(page.chores.contains { $0.isRepeating } && page.chores.contains { $0.done })
        // Sorted by next (none last), each due day as the server would say.
        let next = page.chores.compactMap(\.next)
        #expect(next == next.sorted())
        #expect(page.chores.last?.next == nil)
        for chore in page.chores where !chore.isRepeating && !chore.done {
            #expect(chore.next == chore.day)
        }
        // The people are the household's; the account's subscriptions as `subscribed` says.
        let accounts = Set(page.people.filter(\.account).map(\.id))
        for chore in page.chores {
            if let assignee = chore.assignee { #expect(page.people.contains(assignee), "\(assignee.id)") }
            if let time = chore.time { #expect(chore.part == ChorePart.of(time: time), "\(chore.id)") }
            #expect(Set(chore.subscriberIds).isSubset(of: accounts), "\(chore.id)")
            #expect(chore.subscribed == chore.subscriberIds.contains("demo-user"), "\(chore.id)")
        }
        #expect(Set(ChoreParts.chores(page.chores).map(\.part)) == Set(ChorePart.allCases))
    }

    @Test func answersTheAgenda() throws {
        let agenda: ChoreAgenda = try get("/chores/agenda", query: ["from": "2026-10-27", "to": "2026-11-09", "today": "2026-10-30"])
        #expect(agenda.days.count == 14 && agenda.days.first?.date == Day("2026-10-27") && agenda.days.last?.date == Day("2026-11-09"))
        // Today: every part, the daily chores among them; the overdue car service above.
        let items = try #require(agenda.items(on: today))
        #expect(Set(items.map(\.part)) == [.morning, .evening])
        #expect(items.contains { $0.choreId == "chore-dishwasher" && $0.repeating })
        #expect(items.map(\.part) == items.map(\.part).sorted { ChorePart.allCases.firstIndex(of: $0)! < ChorePart.allCases.firstIndex(of: $1)! })
        #expect(agenda.overdue.map(\.choreId) == ["chore-car-service"])
        // A daily chore every day, a single one on its day only.
        #expect(agenda.days.allSatisfy { $0.items.contains { $0.choreId == "chore-tidy" } })
        #expect(agenda.days.filter { $0.items.contains { $0.choreId == "chore-swim-bag" } }.map(\.date) == [today.adding(days: 1)])
        #expect(agenda.items(on: today.adding(days: -3))?.contains { $0.choreId == "chore-windows" && $0.done } == true)
        // What the app asks.
        let request = ChoresStore.agendaRequest(FamilyAPI(client: APIClient(demo: server), familyID: DemoServer.familyID), around: today, today: today)
        #expect(request.query["from"] == "2026-09-30" && request.query["to"] == "2026-11-30")
    }

    @Test func answersOneChore() throws {
        let one: ChoreResponse = try get("/chores/chore-bins")
        #expect(one.chore.title == "Take out the bins" && one.chore.subscribed)
        let (_, response) = server.respond(to: URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/chores/nope")))
        #expect(response.statusCode == 404)
    }
}

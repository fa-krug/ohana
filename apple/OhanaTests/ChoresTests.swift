import Foundation
import Testing
@testable import Ohana

/// The chores' answers as the server sends them (the contract's JSON), their sections and text.
struct ChoreModelTests {
    static let json = """
    {"chores":[
      {"id":"c1","title":"Bins","note":"","assignee":{"id":"u1","name":"Ben","account":true},"day":"2026-10-20","time":"19:00","rrule":"FREQ=WEEKLY","done":false,"doneAt":null,"next":"2026-11-03","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z"},
      {"id":"c2","title":"Car service","note":"Garage","assignee":null,"day":"2026-11-01","time":null,"rrule":null,"done":false,"doneAt":null,"next":"2026-11-01","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-02T10:00:00.000Z"},
      {"id":"c3","title":"Windows","note":"","assignee":{"id":"p1","name":"Mia","account":false},"day":"2026-10-30","time":null,"rrule":null,"done":true,"doneAt":"2026-10-31T08:00:00.000Z","next":null,"createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z"}
    ],"people":[{"id":"u1","name":"Ben","account":true},{"id":"p1","name":"Mia","account":false}],"canEdit":true}
    """

    @Test func decodesThePage() throws {
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        #expect(page.canEdit)
        #expect(page.people.map(\.id) == ["u1", "p1"])
        #expect(page.people[1].account == false)
        let bins = page.chores[0]
        #expect(bins.isRepeating && bins.rule == RepeatRule(.weekly))
        #expect(bins.day == Day("2026-10-20") && bins.next == Day("2026-11-03") && bins.time == "19:00")
        #expect(bins.assignee?.name == "Ben")
        let car = page.chores[1]
        #expect(!car.isRepeating && car.assignee == nil && car.note == "Garage")
        let windows = page.chores[2]
        #expect(windows.done && windows.next == nil && windows.doneDate != nil)
        let one = try APIClient.decoder.decode(ChoreResponse.self, from: Data(#"{"chore":\#(Self.choreJSON)}"#.utf8))
        #expect(one.chore.id == "c9")
    }

    static let choreJSON = #"{"id":"c9","title":"T","note":"","assignee":null,"day":"2026-11-01","time":null,"rrule":null,"done":false,"doneAt":null,"next":"2026-11-01","createdAt":"x","updatedAt":"x"}"#

    @Test func encodesTheInputWithNulls() throws {
        let input = ChoreInput(title: "Bins", day: Day("2026-11-03")!)
        let json = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(input)) as? [String: Any])
        #expect(json["title"] as? String == "Bins")
        #expect(json["day"] as? String == "2026-11-03")
        #expect(json["note"] as? String == "")
        // Sent as null, so an edit clears them.
        #expect(json["assigneeId"] is NSNull && json["time"] is NSNull && json["rrule"] is NSNull)
        let full = ChoreInput(title: "T", assigneeId: "u1", day: Day("2026-11-03")!, time: "07:30", rrule: "FREQ=DAILY")
        let back = try #require(try JSONSerialization.jsonObject(with: APIClient.encoder.encode(full)) as? [String: Any])
        #expect(back["assigneeId"] as? String == "u1" && back["time"] as? String == "07:30" && back["rrule"] as? String == "FREQ=DAILY")
    }

    @Test func sortsIntoSections() throws {
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        let now = try #require(Date.server("2026-11-01T12:00:00.000Z"))
        let today = Day("2026-11-01")!
        let s = ChoreSections.make(page.chores, today: today, now: now)
        #expect(s.today.map(\.id) == ["c2"])
        #expect(s.repeating.map(\.id) == ["c1"])
        #expect(s.done.map(\.id) == ["c3"])
        #expect(s.overdue.isEmpty && s.upcoming.isEmpty)
        // A day later: the car service is overdue.
        let later = ChoreSections.make(page.chores, today: today.adding(days: 1), now: now)
        #expect(later.overdue.map(\.id) == ["c2"])
        // Done long ago: not shown.
        #expect(ChoreSections.make(page.chores, today: today, now: now.addingTimeInterval(30 * 24 * 3600)).done.isEmpty)
        // Filters.
        #expect(ChoreSections.make(page.chores, today: today, filter: .person("u1"), now: now).repeating.map(\.id) == ["c1"])
        #expect(ChoreSections.make(page.chores, today: today, filter: .person("u1"), now: now).today.isEmpty)
        #expect(ChoreSections.make(page.chores, today: today, filter: .nobody, now: now).today.map(\.id) == ["c2"])
        #expect(ChoreSections.make(page.chores, today: today, filter: .person("nobody"), now: now).isEmpty)
    }

    @Test func readsTheSchedule() throws {
        let page = try APIClient.decoder.decode(ChoresPage.self, from: Data(Self.json.utf8))
        let today = Day("2026-11-01")!
        let en = Locale(identifier: "en_US")
        #expect(ChoreText.when(today, time: nil, today: today) == "Today")
        #expect(ChoreText.when(today.adding(days: 1), time: "07:30", today: today) == "Tomorrow, 07:30")
        #expect(ChoreText.schedule(page.chores[0], today: today, locale: en).hasPrefix("Weekly, next "))
    }

    @Test func linksOpenTheChore() {
        #expect(AppRoute.parse(webPath: "/f/fam/chores")?.route == .module(.chores))
        #expect(AppRoute.parse(webPath: "/f/fam/chores/c1")?.route == .chore(id: "c1"))
        #expect(AppRoute.parse(webPath: "/f/fam/chores/new")?.route == .newChore)
        #expect(AppRoute.chore(id: "c1").requiredModule == .chores)
        #expect(SettingsPage.chores.module == .chores)
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
        draft.setTimed(true)
        #expect(draft.input.time == "09:00")
    }
}

/// The rules of the chores sync (`ChoreReminderPlan`).
struct ChoreReminderPlanTests {
    let family = "f1"
    let today = Day("2026-11-05")!
    static let ben = ChorePerson(id: "u1", name: "Ben", account: true)
    static let mia = ChorePerson(id: "p1", name: "Mia", account: false)

    func chore(_ id: String, _ title: String = "Bins", for person: ChorePerson? = nil, day: String = "2026-11-05",
               time: String? = nil, rrule: String? = nil, done: Bool = false, next: String? = "default",
               note: String = "") -> Chore {
        let nextDay: Day? = next == "default" ? (done ? nil : Day(day)) : next.flatMap(Day.init)
        return Chore(id: id, title: title, note: note, assignee: person, day: Day(day)!, time: time, rrule: rrule,
                     done: done, doneAt: done ? "2026-11-05T08:00:00.000Z" : nil, next: nextDay,
                     createdAt: "2026-11-01T08:00:00.000Z", updatedAt: "2026-11-01T08:00:00.000Z")
    }

    /// A reminder as the sync writes it for `chore` (or for an older version of it).
    func written(_ id: String, _ chore: Chore, scope: String? = nil, done: Bool = false,
                 fingerprint: String? = nil) -> ReminderSnapshot {
        let (content, print) = ChoreReminderPlan.content(familyID: family, chore: chore, everyone: scope == nil)
        let url = ChoreReminderMarker(familyID: family, choreID: chore.id, fingerprint: fingerprint ?? print).url
        return ReminderSnapshot(id: id, listID: "list", title: content.title, notes: content.notes, due: content.due,
                                isCompleted: done, url: url)
    }

    func fingerprint(_ chore: Chore, scope: String? = nil) -> String {
        ChoreReminderPlan.content(familyID: family, chore: chore, everyone: scope == nil).1
    }

    func plan(_ chores: [Chore], _ reminders: [ReminderSnapshot] = [], links: [String: ChoreReminderLink] = [:],
              scope: String? = nil) -> ChoreReminderPlan {
        ChoreReminderPlan.make(familyID: family, chores: chores, reminders: reminders, links: links, scope: scope,
                               today: today)
    }

    @Test func theMarkerGoesThroughTheURL() throws {
        let marker = ChoreReminderMarker(familyID: "fam 1", choreID: "c1", fingerprint: "0a1b2c3d")
        #expect(marker.url.absoluteString == "ohana://f/fam%201/chores/c1?v=0a1b2c3d")
        #expect(ChoreReminderMarker(url: marker.url) == marker)
        for other in ["ohana://f/f1/chores/c1", "https://x.example/f/f1/chores/c1?v=1", "ohana://f/f1/meals/shopping/2026-11-07/1-1?q=1&t=x",
                      "ohana://f/f1/chores?v=1"] {
            #expect(ChoreReminderMarker(url: URL(string: other)) == nil, "\(other)")
        }
        // The app opens it on the chore.
        let url = marker.url
        #expect(AppRoute.parse(webPath: "/" + (url.host() ?? "") + url.path(percentEncoded: false))?.route == .chore(id: "c1"))
    }

    @Test func fingerprintsAreShortAndStable() {
        let bins = chore("c1", rrule: "FREQ=WEEKLY", next: "2026-11-12")
        let print = fingerprint(bins)
        #expect(print.count == 8 && print.allSatisfy(\.isHexDigit))
        #expect(fingerprint(bins) == print)
        // A passing occurrence changes nothing; an edit does.
        #expect(fingerprint(chore("c1", rrule: "FREQ=WEEKLY", next: "2026-11-19")) == print)
        #expect(fingerprint(chore("c1", "Bins out", rrule: "FREQ=WEEKLY", next: "2026-11-12")) != print)
        #expect(fingerprint(chore("c1", rrule: "FREQ=WEEKLY", next: "2026-11-12", note: "x")) != print)
        #expect(fingerprint(chore("c1", time: "19:00", rrule: "FREQ=WEEKLY", next: "2026-11-12")) != print)
        // A single chore keeps its fingerprint when it's done.
        #expect(fingerprint(chore("c2")) == fingerprint(chore("c2", done: true)))
    }

    @Test func createsTheChoresReminders() throws {
        let bins = chore("c1", for: Self.ben, day: "2026-10-29", time: "19:00", rrule: "FREQ=WEEKLY", next: "2026-11-05",
                         note: " Both bins ")
        let car = chore("c2", "Car service", day: "2026-11-08")
        let done = chore("c3", "Windows", done: true)
        let ended = chore("c4", "Old", rrule: "FREQ=DAILY;COUNT=2", next: nil)
        let p = plan([bins, car, done, ended])
        #expect(p.creates.map(\.choreID) == ["c1", "c2"])
        let b = p.creates[0].content
        #expect(b.title == "Bins · Ben")
        #expect(b.notes == "Both bins")
        #expect(b.due == ReminderDue(day: today, hour: 19, minute: 0))
        #expect(b.rule == RepeatRule(.weekly))
        #expect(ChoreReminderMarker(url: b.url) == ChoreReminderMarker(familyID: family, choreID: "c1", fingerprint: p.creates[0].fingerprint))
        let c = p.creates[1].content
        #expect(c.title == "Car service" && c.notes == nil && c.due == ReminderDue(day: Day("2026-11-08")!) && c.rule == nil)
        #expect(p.updates.isEmpty && p.completions.isEmpty && p.removals.isEmpty && p.markDone.isEmpty)
        #expect(p.links.isEmpty)
    }

    @Test func onlyTheScopesChoresWithoutTheName() {
        let bins = chore("c1", for: Self.ben), tidy = chore("c2", "Tidy", for: Self.mia), plants = chore("c3", "Plants")
        let p = plan([bins, tidy, plants], scope: "u1")
        #expect(p.creates.map(\.choreID) == ["c1"])
        #expect(p.creates[0].content.title == "Bins")
    }

    @Test func leavesWhatIsThereAlone() {
        let bins = chore("c1", rrule: "FREQ=WEEKLY", next: "2026-11-05"), car = chore("c2", "Car", day: "2026-11-08")
        let p = plan([bins, car], [written("r1", bins), written("r2", car)])
        #expect(p.changesNothing)
        #expect(p.links == [
            "c1": ChoreReminderLink(reminderID: "r1", done: false, fingerprint: fingerprint(bins)),
            "c2": ChoreReminderLink(reminderID: "r2", done: false, fingerprint: fingerprint(car)),
        ])
    }

    @Test func aDeletedReminderStaysDeletedUntilTheChoreChanges() {
        let car = chore("c2", "Car", day: "2026-11-08")
        let link = ChoreReminderLink(reminderID: "gone", done: false, fingerprint: fingerprint(car))
        let p = plan([car], links: ["c2": link])
        #expect(p.changesNothing)
        #expect(p.links["c2"] == link)
        // Changed since: written again.
        let moved = chore("c2", "Car", day: "2026-11-09")
        #expect(plan([moved], links: ["c2": link]).creates.map(\.choreID) == ["c2"])
    }

    @Test func updatesAnOpenReminderWhenTheChoreChanged() throws {
        let old = chore("c2", "Car", day: "2026-11-08")
        let new = chore("c2", "Car service", day: "2026-11-09", time: "10:00", rrule: nil)
        let link = ChoreReminderLink(reminderID: "r2", done: false, fingerprint: fingerprint(old))
        let p = plan([new], [written("r2", old)], links: ["c2": link])
        let update = try #require(p.updates.first)
        #expect(update.id == "r2" && update.content.title == "Car service")
        #expect(update.content.due == ReminderDue(day: Day("2026-11-09")!, hour: 10, minute: 0))
        #expect(p.links["c2"]?.fingerprint == fingerprint(new))
        // A done reminder isn't written again.
        let done = chore("c2", "Car service", day: "2026-11-09", done: true)
        let donePlan = plan([done], [written("r2", old, done: true)], links: ["c2": ChoreReminderLink(reminderID: "r2", done: true, fingerprint: fingerprint(old))])
        #expect(donePlan.changesNothing)
        // A repeating chore gets its rule.
        let weekly = chore("c2", "Car", day: "2026-11-08", rrule: "FREQ=MONTHLY", next: "2026-11-08")
        #expect(plan([weekly], [written("r2", old)], links: ["c2": link]).updates.first?.content.rule == RepeatRule(.monthly))
    }

    @Test func doneGoesBothWays() {
        let open = chore("c2", "Car"), done = chore("c2", "Car", done: true)
        let linkOpen = ChoreReminderLink(reminderID: "r2", done: false, fingerprint: fingerprint(open))
        let linkDone = ChoreReminderLink(reminderID: "r2", done: true, fingerprint: fingerprint(open))

        // Ticked off in Reminders: reported to the server.
        let ticked = plan([open], [written("r2", open, done: true)], links: ["c2": linkOpen])
        #expect(ticked.markDone == [.init(choreID: "c2", done: true)])
        #expect(ticked.completions.isEmpty && ticked.updates.isEmpty)
        #expect(ticked.links["c2"]?.done == true)

        // Opened again in Reminders.
        let reopened = plan([done], [written("r2", open)], links: ["c2": linkDone])
        #expect(reopened.markDone == [.init(choreID: "c2", done: false)])

        // Done on the server: the reminder is completed.
        let serverDone = plan([done], [written("r2", open)], links: ["c2": linkOpen])
        #expect(serverDone.completions == [.init(id: "r2", done: true)])
        #expect(serverDone.markDone.isEmpty && serverDone.links["c2"]?.done == true)

        // Opened again on the server: so is the reminder.
        let serverOpen = plan([open], [written("r2", open, done: true)], links: ["c2": linkDone])
        #expect(serverOpen.completions == [.init(id: "r2", done: false)])
        #expect(serverOpen.markDone.isEmpty)

        // Both changed: they agree, nothing to do but remember.
        let both = plan([done], [written("r2", open, done: true)], links: ["c2": linkOpen])
        #expect(both.changesNothing && both.links["c2"]?.done == true)

        // No link: what Reminders says counts against "not done".
        let fresh = plan([open], [written("r9", open, done: true)])
        #expect(fresh.markDone == [.init(choreID: "c2", done: true)])
        // Repeating chores have no done.
        let weekly = chore("c1", rrule: "FREQ=WEEKLY", next: "2026-11-05")
        #expect(plan([weekly], [written("r1", weekly)]).markDone.isEmpty)
    }

    @Test func completedCopiesOfARepeatingReminderAreNotTheLiveOne() {
        let weekly = chore("c1", rrule: "FREQ=WEEKLY", next: "2026-11-05")
        let link = ChoreReminderLink(reminderID: "copy", done: false, fingerprint: fingerprint(weekly))
        // The linked one is a completed copy; the open one (moved on) is the chore's now.
        let p = plan([weekly], [written("copy", weekly, done: true), written("live", weekly)], links: ["c1": link])
        #expect(p.changesNothing)
        #expect(p.links["c1"]?.reminderID == "live")
        // Only completed ones and the chore unchanged: left (the series was ended in Reminders).
        let ended = plan([weekly], [written("copy", weekly, done: true)], links: ["c1": link])
        #expect(ended.changesNothing && ended.links["c1"] == link)
        // Never linked: a new one, not the completed copy.
        #expect(plan([weekly], [written("copy", weekly, done: true)]).creates.map(\.choreID) == ["c1"])
    }

    @Test func findsAReminderAnotherDeviceWrote() {
        let car = chore("c2", "Car", day: "2026-11-08")
        // Another family's or another chore's markers aren't it.
        let other = ReminderSnapshot(id: "x", listID: "list", title: "Car",
                                     url: ChoreReminderMarker(familyID: "f2", choreID: "c2", fingerprint: "1").url)
        #expect(plan([car], [other]).creates.count == 1)
        let p = plan([car], [written("theirs", car)])
        #expect(p.changesNothing && p.links["c2"]?.reminderID == "theirs")
    }

    @Test func removesOnlyItsOwnLinkedRemindersOfChoresGoneOrOutOfScope() {
        let bins = chore("c1", for: Self.ben), tidy = chore("c2", "Tidy", for: Self.mia), gone = chore("c3", "Gone")
        let links = [
            "c2": ChoreReminderLink(reminderID: "r2", done: false, fingerprint: fingerprint(tidy)),
            "c3": ChoreReminderLink(reminderID: "r3", done: false, fingerprint: fingerprint(gone)),
            "c4": ChoreReminderLink(reminderID: "r4", done: true, fingerprint: "x"),
        ]
        let reminders = [
            written("r1", bins), written("r2", tidy), written("r3", gone),
            // Done: left.
            written("r4", chore("c4", "Done one"), done: true),
            // Another device's, of a chore gone: left.
            written("r5", chore("c5", "Theirs")),
        ]
        let p = plan([bins, tidy], reminders, links: links, scope: "u1")
        #expect(p.removals == ["r2", "r3"])
        #expect(Set(p.links.keys) == ["c1"])
        // Everyone's: Mia's stays.
        #expect(plan([bins, tidy], reminders, links: links).removals == ["r3"])
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

    private func get<T: Decodable>(_ path: String, as type: T.Type = T.self) throws -> T {
        let url = DemoServer.baseURL.appending(path: "/api/v1/families/demo\(path)")
        let (data, response) = server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200, "\(path): \(String(decoding: data, as: UTF8.self))")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    @Test func listsTheChores() throws {
        let page: ChoresPage = try get("/chores")
        #expect(!page.canEdit)
        #expect(page.people.contains { $0.id == "demo-user" })
        #expect(page.chores.count == 7)
        #expect(page.chores.contains { $0.isRepeating } && page.chores.contains { $0.done })
        // Sorted by next (none last), each due day as the server would say.
        let next = page.chores.compactMap(\.next)
        #expect(next == next.sorted())
        #expect(page.chores.last?.next == nil)
        for chore in page.chores where !chore.isRepeating && !chore.done {
            #expect(chore.next == chore.day)
        }
        // The people are the household's.
        for chore in page.chores {
            if let assignee = chore.assignee { #expect(page.people.contains(assignee), "\(assignee.id)") }
        }
        let sections = ChoreSections.make(page.chores, today: today, now: Day.calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9))!)
        #expect(!sections.overdue.isEmpty && !sections.today.isEmpty && !sections.upcoming.isEmpty
            && !sections.repeating.isEmpty && !sections.done.isEmpty)
    }

    @Test func answersOneChore() throws {
        let one: ChoreResponse = try get("/chores/chore-bins")
        #expect(one.chore.title == "Take out the bins")
        let (_, response) = server.respond(to: URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/chores/nope")))
        #expect(response.statusCode == 404)
    }
}

import Foundation
import Testing
@testable import Ohana

/// The chores' answers as the server sends them (the contract's JSON), their sections and text.
struct ChoreModelTests {
    static let json = """
    {"chores":[
      {"id":"c1","title":"Bins","note":"","assignee":{"id":"u1","name":"Ben","account":true},"day":"2026-10-20","time":"19:00","rrule":"FREQ=WEEKLY","done":false,"doneAt":null,"next":"2026-11-03","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-01T10:00:00.000Z","occurrences":["2026-10-27","2026-11-03"]},
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
        #expect(bins.occurrences == [Day("2026-10-27")!, Day("2026-11-03")!])
        let car = page.chores[1]
        #expect(!car.isRepeating && car.assignee == nil && car.note == "Garage")
        // Without occurrences (an older server): none.
        #expect(car.occurrences.isEmpty)
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

    /// Berlin's calendar, so the times don't depend on the machine's time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// A moment in Berlin.
    func at(_ day: String, _ hour: Int, _ minute: Int = 0) -> Date {
        let d = Day(day)!
        return Self.calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: hour, minute: minute))!
    }

    func chore(_ id: String, _ title: String = "Bins", for person: ChorePerson? = nil, day: String = "2026-11-05",
               time: String? = nil, rrule: String? = nil, done: Bool = false, next: String? = "default",
               note: String = "", occurrences: [String] = [], createdAt: String = "2026-09-01T08:00:00.000Z") -> Chore {
        let nextDay: Day? = next == "default" ? (done ? nil : Day(day)) : next.flatMap(Day.init)
        return Chore(id: id, title: title, note: note, assignee: person, day: Day(day)!, time: time, rrule: rrule,
                     done: done, doneAt: done ? "2026-11-05T08:00:00.000Z" : nil, next: nextDay,
                     createdAt: createdAt, updatedAt: createdAt,
                     occurrences: occurrences.compactMap(Day.init))
    }

    /// A weekly chore at 19:00 whose occurrences around today are 29 Oct, today and 12 Nov.
    func weekly(_ title: String = "Bins", time: String? = "19:00", rrule: String = "FREQ=WEEKLY",
                occurrences: [String] = ["2026-10-29", "2026-11-05", "2026-11-12"], for person: ChorePerson? = nil) -> Chore {
        chore("c1", title, for: person, day: "2026-10-01", time: time, rrule: rrule, next: "2026-11-05", occurrences: occurrences)
    }

    /// A reminder as the sync writes it for `chore` (or for an older version of it); `occurrence`
    /// for a repeating chore's.
    func written(_ id: String, _ chore: Chore, occurrence: String? = nil, scope: String? = nil, done: Bool = false,
                 fingerprint: String? = nil) -> ReminderSnapshot {
        let day = occurrence.flatMap(Day.init)
        let content = ChoreReminderPlan.content(familyID: family, chore: chore, occurrence: day, everyone: scope == nil)
        let url = ChoreReminderMarker(familyID: family, choreID: chore.id, fingerprint: fingerprint ?? self.fingerprint(chore, scope: scope),
                                      occurrence: day).url
        return ReminderSnapshot(id: id, listID: "list", title: content.title, notes: content.notes, due: content.due,
                                isCompleted: done, url: url)
    }

    func fingerprint(_ chore: Chore, scope: String? = nil) -> String {
        ChoreReminderPlan.fingerprint(chore, everyone: scope == nil)
    }

    /// The link of a repeating chore's occurrence.
    func link(_ id: String, _ chore: Chore, _ occurrence: String, fingerprint: String? = nil) -> (String, ChoreReminderLink) {
        ("\(chore.id)@\(occurrence)",
         ChoreReminderLink(reminderID: id, done: false, fingerprint: fingerprint ?? self.fingerprint(chore), occurrence: Day(occurrence)))
    }

    func plan(_ chores: [Chore], _ reminders: [ReminderSnapshot] = [], links: [String: ChoreReminderLink] = [:],
              scope: String? = nil, now: Date? = nil) -> ChoreReminderPlan {
        ChoreReminderPlan.make(familyID: family, chores: chores, reminders: reminders, links: links, scope: scope,
                               today: today, now: now ?? at("2026-11-05", 12), calendar: Self.calendar)
    }

    @Test func theMarkerGoesThroughTheURL() throws {
        let marker = ChoreReminderMarker(familyID: "fam 1", choreID: "c1", fingerprint: "0a1b2c3d")
        #expect(marker.url.absoluteString == "ohana://f/fam%201/chores/c1?v=0a1b2c3d")
        #expect(ChoreReminderMarker(url: marker.url) == marker)
        // An occurrence's.
        let occurrence = ChoreReminderMarker(familyID: "f1", choreID: "c1", fingerprint: "0a1b2c3d", occurrence: Day("2026-11-05"))
        #expect(occurrence.url.absoluteString == "ohana://f/f1/chores/c1?v=0a1b2c3d&o=2026-11-05")
        #expect(ChoreReminderMarker(url: occurrence.url) == occurrence)
        for other in ["ohana://f/f1/chores/c1", "https://x.example/f/f1/chores/c1?v=1", "ohana://f/f1/meals/shopping/2026-11-07/1-1?q=1&t=x",
                      "ohana://f/f1/chores?v=1", "ohana://f/f1/chores/c1?v=1&o=soon"] {
            #expect(ChoreReminderMarker(url: URL(string: other)) == nil, "\(other)")
        }
        // The app opens it on the chore.
        let url = occurrence.url
        #expect(AppRoute.parse(webPath: "/" + (url.host() ?? "") + url.path(percentEncoded: false))?.route == .chore(id: "c1"))
    }

    @Test func linksAreKeptByChoreAndOccurrence() throws {
        #expect(ChoreReminderLink.key(choreID: "c1", occurrence: nil) == "c1")
        #expect(ChoreReminderLink.key(choreID: "c1", occurrence: Day("2026-11-05")) == "c1@2026-11-05")
        #expect(ChoreReminderLink.choreID(ofKey: "c1@2026-11-05") == "c1")
        #expect(ChoreReminderLink.choreID(ofKey: "c1") == "c1")
        // Saved links from before occurrences decode (without one).
        let old = try JSONDecoder().decode(ChoreReminderLink.self, from: Data(#"{"reminderID":"r1","done":false,"fingerprint":"x"}"#.utf8))
        #expect(old == ChoreReminderLink(reminderID: "r1", done: false, fingerprint: "x"))
        let new = ChoreReminderLink(reminderID: "r1", done: false, fingerprint: "x", occurrence: Day("2026-11-05"))
        #expect(try JSONDecoder().decode(ChoreReminderLink.self, from: JSONEncoder().encode(new)) == new)
    }

    @Test func fingerprintsAreShortAndStable() {
        let bins = weekly()
        let print = fingerprint(bins)
        #expect(print.count == 8 && print.allSatisfy(\.isHexDigit))
        #expect(fingerprint(bins) == print)
        // A repeating chore's: passing occurrences and its first day change nothing; an edit does.
        #expect(fingerprint(chore("c1", day: "2026-09-01", time: "19:00", rrule: "FREQ=WEEKLY", next: "2026-11-12",
                                  occurrences: ["2026-11-05", "2026-11-12"])) == print)
        #expect(fingerprint(weekly("Bins out")) != print)
        #expect(fingerprint(weekly(time: "20:00")) != print)
        #expect(fingerprint(weekly(rrule: "FREQ=WEEKLY;INTERVAL=2")) != print)
        #expect(fingerprint(chore("c1", day: "2026-10-01", time: "19:00", rrule: "FREQ=WEEKLY", note: "x")) != print)
        #expect(fingerprint(weekly(for: Self.ben)) != print)
        // A single chore's has its day, and stays when it's done.
        #expect(fingerprint(chore("c2")) == fingerprint(chore("c2", done: true)))
        #expect(fingerprint(chore("c2")) != fingerprint(chore("c2", day: "2026-11-06")))
    }

    // MARK: Single chores

    @Test func createsTheSingleChoresReminders() throws {
        let car = chore("c2", "Car service", for: Self.ben, day: "2026-11-08", time: "10:30", note: " Garage ")
        let plain = chore("c5", "Plants", day: "2026-11-09")
        let done = chore("c3", "Windows", done: true)
        let p = plan([car, plain, done])
        #expect(p.creates.map(\.choreID) == ["c2", "c5"])
        let c = p.creates[0]
        #expect(c.key == "c2" && c.occurrence == nil)
        #expect(c.content.title == "Car service · Ben" && c.content.notes == "Garage")
        #expect(c.content.due == ReminderDue(day: Day("2026-11-08")!, hour: 10, minute: 30))
        #expect(ChoreReminderMarker(url: c.content.url) == ChoreReminderMarker(familyID: family, choreID: "c2", fingerprint: c.fingerprint))
        #expect(p.creates[1].content.notes == nil && p.creates[1].content.due == ReminderDue(day: Day("2026-11-09")!))
        #expect(p.updates.isEmpty && p.completions.isEmpty && p.removals.isEmpty && p.markDone.isEmpty)
        #expect(p.links.isEmpty && p.nextAppearance == nil)
    }

    @Test func onlyTheScopesChoresWithoutTheName() {
        let bins = chore("c1", for: Self.ben), tidy = chore("c2", "Tidy", for: Self.mia), plants = chore("c3", "Plants")
        let p = plan([bins, tidy, plants], scope: "u1")
        #expect(p.creates.map(\.choreID) == ["c1"])
        #expect(p.creates[0].content.title == "Bins")
    }

    @Test func leavesWhatIsThereAlone() {
        let bins = weekly(), car = chore("c2", "Car", day: "2026-11-08")
        let (key, binsLink) = link("r1", bins, "2026-10-29")
        let p = plan([bins, car], [written("r1", bins, occurrence: "2026-10-29"), written("r2", car)], links: [key: binsLink])
        #expect(p.changesNothing)
        #expect(p.links == [
            key: binsLink,
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
    }

    @Test func doneGoesBothWaysForSingleChores() {
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
    }

    @Test func findsAReminderAnotherDeviceWrote() {
        let car = chore("c2", "Car", day: "2026-11-08")
        // Another family's or another chore's markers aren't it, nor an occurrence's.
        let other = ReminderSnapshot(id: "x", listID: "list", title: "Car",
                                     url: ChoreReminderMarker(familyID: "f2", choreID: "c2", fingerprint: "1").url)
        let occurrence = ReminderSnapshot(id: "y", listID: "list", title: "Car",
                                          url: ChoreReminderMarker(familyID: family, choreID: "c2", fingerprint: "1",
                                                                   occurrence: Day("2026-11-01")).url)
        #expect(plan([car], [other, occurrence]).creates.count == 1)
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

    // MARK: Repeating chores

    @Test func anOccurrenceAppearsThreeHoursBeforeItsTime() throws {
        // Only today's at 19:00: from 16:00 on.
        let bins = weekly(occurrences: ["2026-11-05", "2026-11-12"])
        let before = plan([bins], now: at("2026-11-05", 15, 59))
        #expect(before.creates.isEmpty && before.changesNothing)
        #expect(before.nextAppearance == at("2026-11-05", 16))
        let after = plan([bins], now: at("2026-11-05", 16))
        let create = try #require(after.creates.first)
        #expect(after.creates.count == 1)
        #expect(create.key == "c1@2026-11-05" && create.occurrence == today)
        #expect(create.content.due == ReminderDue(day: today, hour: 19, minute: 0))
        #expect(after.nextAppearance == at("2026-11-12", 16))

        // All day: from 21:00 the evening before.
        let tidy = chore("c2", "Tidy", day: "2026-11-01", rrule: "FREQ=DAILY", next: "2026-11-06", occurrences: ["2026-11-06"])
        #expect(plan([tidy], now: at("2026-11-05", 20, 59)).creates.isEmpty)
        let evening = plan([tidy], now: at("2026-11-05", 21))
        #expect(evening.creates.map(\.key) == ["c2@2026-11-06"])
        #expect(evening.creates.first?.content.due == ReminderDue(day: Day("2026-11-06")!))
        #expect(evening.nextAppearance == nil)
    }

    @Test func noOccurrenceFromBeforeTheChoreOrOfAnEndedSeries() {
        // Made yesterday, starting weeks ago: last week's isn't made, today's comes at 16:00.
        let new = chore("c1", day: "2026-10-01", time: "19:00", rrule: "FREQ=WEEKLY", next: "2026-11-05",
                        occurrences: ["2026-10-29", "2026-11-05", "2026-11-12"], createdAt: "2026-11-04T10:00:00.000Z")
        #expect(plan([new]).creates.isEmpty)
        #expect(plan([new], now: at("2026-11-05", 16)).creates.map(\.key) == ["c1@2026-11-05"])
        // A series that ended before today: its last one isn't made.
        let ended = chore("c2", day: "2026-10-01", rrule: "FREQ=WEEKLY;COUNT=3", next: nil, occurrences: ["2026-10-15"])
        #expect(plan([ended]).creates.isEmpty)
        // Its last one today still is.
        let endsToday = chore("c3", day: "2026-10-22", rrule: "FREQ=WEEKLY;COUNT=3", next: "2026-11-05",
                              occurrences: ["2026-10-29", "2026-11-05"])
        #expect(plan([endsToday]).creates.map(\.key) == ["c3@2026-11-05"])
    }

    @Test func theCurrentOccurrenceIsTheLatestThatAppeared() throws {
        let bins = weekly(for: Self.ben)
        // Noon: today's hasn't appeared yet, last week's is the current one.
        let noon = plan([bins])
        #expect(noon.creates.map(\.key) == ["c1@2026-10-29"])
        #expect(noon.nextAppearance == at("2026-11-05", 16))
        // Evening: today's (only it: last week's isn't made anymore).
        let evening = plan([bins], now: at("2026-11-05", 17))
        let create = try #require(evening.creates.first)
        #expect(evening.creates.count == 1 && create.key == "c1@2026-11-05")
        let c = create.content
        #expect(c.title == "Bins · Ben" && c.notes == nil)
        #expect(c.due == ReminderDue(day: today, hour: 19, minute: 0))
        #expect(ChoreReminderMarker(url: c.url) == ChoreReminderMarker(familyID: family, choreID: "c1", fingerprint: create.fingerprint,
                                                                       occurrence: today))
        #expect(evening.nextAppearance == at("2026-11-12", 16))
        // Before the first one appears: nothing.
        let first = weekly(occurrences: ["2026-11-12"])
        let none = plan([first])
        #expect(none.changesNothing && none.links.isEmpty && none.nextAppearance == at("2026-11-12", 16))
        // The series ended: nothing to wait for.
        #expect(plan([weekly(occurrences: [])]).changesNothing)
        #expect(plan([weekly(occurrences: [])]).nextAppearance == nil)
    }

    @Test func anOccurrenceIsMadeOnce() {
        let bins = weekly()
        let now = at("2026-11-05", 17)
        let (key, link) = link("r1", bins, "2026-11-05")
        // Linked and there (open or ticked off): nothing.
        for done in [false, true] {
            let p = plan([bins], [written("r1", bins, occurrence: "2026-11-05", done: done)], links: [key: link], now: now)
            #expect(p.changesNothing && p.links[key] == link)
            // Ticked off: nothing goes to the server.
            #expect(p.markDone.isEmpty)
        }
        // Written on another device sharing the list: linked, not made again.
        let theirs = plan([bins], [written("theirs", bins, occurrence: "2026-11-05")], now: now)
        #expect(theirs.changesNothing)
        #expect(theirs.links[key] == ChoreReminderLink(reminderID: "theirs", done: false, fingerprint: fingerprint(bins),
                                                      occurrence: today))
        // Another occurrence's marker isn't it.
        #expect(plan([bins], [written("old", bins, occurrence: "2026-10-29")], now: now).creates.map(\.key) == [key])
    }

    @Test func aDeletedOccurrenceStaysDeleted() {
        let bins = weekly()
        let now = at("2026-11-05", 17)
        let (key, link) = link("gone", bins, "2026-11-05")
        let p = plan([bins], links: [key: link], now: now)
        #expect(p.changesNothing && p.links[key] == link)
        // Even when the chore changed since.
        let renamed = plan([weekly("Bins out")], links: [key: link], now: now)
        #expect(renamed.changesNothing && renamed.links[key] == link)
    }

    @Test func eachOccurrenceHasItsOwnLink() {
        let bins = weekly()
        let (oldKey, oldLink) = link("r0", bins, "2026-10-29")
        // Last week's was made; today's appears now: a reminder of its own, last week's left.
        let p = plan([bins], [written("r0", bins, occurrence: "2026-10-29")], links: [oldKey: oldLink], now: at("2026-11-05", 17))
        #expect(p.creates.map(\.key) == ["c1@2026-11-05"])
        #expect(p.updates.isEmpty && p.removals.isEmpty)
        #expect(p.links == [oldKey: oldLink])
        // Links of occurrences long past are forgotten; those of the last 60 days kept.
        let (key60, link60) = link("r60", bins, "2026-09-10")
        let (key70, link70) = link("r70", bins, "2026-08-27")
        let pruned = plan([bins], links: [key60: link60, key70: link70, oldKey: oldLink])
        #expect(Set(pruned.links.keys) == [key60, oldKey])
        // Unless the server still names it (a yearly chore's last).
        let yearly = chore("c1", day: "2025-08-27", rrule: "FREQ=YEARLY", next: "2027-08-27", occurrences: ["2026-08-27", "2027-08-27"])
        let (yearKey, yearLink) = link("ry", yearly, "2026-08-27")
        let kept = plan([yearly], links: [yearKey: yearLink])
        #expect(kept.changesNothing && kept.links == [yearKey: yearLink])
    }

    @Test func anEditRewritesTheOpenOccurrencesFromToday() throws {
        let old = chore("c1", "Tidy", day: "2026-10-01", rrule: "FREQ=DAILY", next: "2026-11-05",
                        occurrences: ["2026-11-04", "2026-11-05", "2026-11-06"])
        let new = chore("c1", "Tidy up", day: "2026-10-01", time: "18:00", rrule: "FREQ=DAILY", next: "2026-11-05",
                        occurrences: ["2026-11-04", "2026-11-05", "2026-11-06"])
        let days = ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"]
        var links: [String: ChoreReminderLink] = [:]
        for day in days {
            let (key, l) = link("r\(day.suffix(1))", old, day)
            links[key] = l
        }
        let reminders = [
            written("r3", old, occurrence: "2026-11-03", done: true),
            // Missed: left as it is.
            written("r4", old, occurrence: "2026-11-04"),
            written("r5", old, occurrence: "2026-11-05"),
            written("r6", old, occurrence: "2026-11-06"),
        ]
        let p = plan([new], reminders, links: links, now: at("2026-11-05", 22))
        #expect(p.updates.map(\.id) == ["r5", "r6"])
        let update = try #require(p.updates.last)
        #expect(update.content.title == "Tidy up")
        #expect(update.content.due == ReminderDue(day: Day("2026-11-06")!, hour: 18, minute: 0))
        #expect(ChoreReminderMarker(url: update.content.url)?.occurrence == Day("2026-11-06"))
        #expect(p.creates.isEmpty && p.removals.isEmpty)
        #expect(p.links["c1@2026-11-05"]?.fingerprint == fingerprint(new))
        #expect(p.links["c1@2026-11-06"]?.fingerprint == fingerprint(new))
        #expect(p.links["c1@2026-11-04"]?.fingerprint == fingerprint(old))
        // A completed one of today isn't written again.
        let ticked = plan([new], [written("r5", old, occurrence: "2026-11-05", done: true)],
                          links: ["c1@2026-11-05": links["c1@2026-11-05"]!], now: at("2026-11-05", 16))
        #expect(ticked.changesNothing)
    }

    @Test func anOccurrenceNoLongerInTheRuleIsRemoved() {
        let old = chore("c1", "Tidy", day: "2026-10-01", rrule: "FREQ=DAILY", next: "2026-11-05",
                        occurrences: ["2026-11-04", "2026-11-05", "2026-11-06"])
        // Every third day now: the 5th and 6th aren't occurrences anymore.
        let new = chore("c1", "Tidy", day: "2026-10-01", rrule: "FREQ=DAILY;INTERVAL=3", next: "2026-11-07",
                        occurrences: ["2026-11-04", "2026-11-07"])
        var links: [String: ChoreReminderLink] = [:]
        for day in ["2026-11-04", "2026-11-05", "2026-11-06"] {
            let (key, l) = link("r\(day.suffix(1))", old, day)
            links[key] = l
        }
        let reminders = ["2026-11-04", "2026-11-05", "2026-11-06"].map { written("r\($0.suffix(1))", old, occurrence: $0) }
        let p = plan([new], reminders, links: links, now: at("2026-11-05", 22))
        #expect(p.removals == ["r5", "r6"])
        #expect(p.creates.isEmpty)
        // The 4th is past: left (and still written from the old version).
        #expect(p.updates.isEmpty)
        #expect(Set(p.links.keys) == ["c1@2026-11-04"])
        // Turned into a single chore: the same.
        let single = chore("c1", "Tidy", day: "2026-11-20")
        let s = plan([single], reminders, links: links, now: at("2026-11-05", 22))
        #expect(s.removals == ["r5", "r6"])
        #expect(s.creates.map(\.key) == ["c1"])
        #expect(Set(s.links.keys) == ["c1@2026-11-04"])
    }

    @Test func aRepeatingReminderFromBeforeIsReplaced() {
        let bins = weekly()
        // The one repeating reminder this device wrote before occurrences had their own.
        let legacy = ChoreReminderLink(reminderID: "series", done: false, fingerprint: "old")
        let series = ReminderSnapshot(id: "series", listID: "list", title: "Bins",
                                      url: ChoreReminderMarker(familyID: family, choreID: "c1", fingerprint: "old").url)
        let p = plan([bins], [series], links: ["c1": legacy], now: at("2026-11-05", 17))
        #expect(p.removals == ["series"])
        #expect(p.creates.map(\.key) == ["c1@2026-11-05"])
        #expect(p.links["c1"] == nil)
        // Another device's isn't removed (nor taken for an occurrence).
        let theirs = plan([bins], [series], now: at("2026-11-05", 17))
        #expect(theirs.removals.isEmpty && theirs.creates.map(\.key) == ["c1@2026-11-05"])
    }

    @Test func removesTheOccurrencesOfAChoreGone() {
        let bins = weekly(for: Self.ben)
        let (k1, l1) = link("r1", bins, "2026-10-29")
        let (k2, l2) = link("r2", bins, "2026-11-05")
        let (k3, l3) = link("r3", bins, "2026-10-22")
        let reminders = [
            written("r1", bins, occurrence: "2026-10-29"), written("r2", bins, occurrence: "2026-11-05"),
            // Ticked off: left.
            written("r3", bins, occurrence: "2026-10-22", done: true),
        ]
        let links = [k1: l1, k2: l2, k3: l3]
        let gone = plan([], reminders, links: links)
        #expect(gone.removals == ["r1", "r2"])
        #expect(gone.links.isEmpty)
        // Out of the scope: the same.
        #expect(plan([bins], reminders, links: links, scope: "p1").removals == ["r1", "r2"])
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
        // The repeating ones have their occurrences around today.
        for chore in page.chores {
            #expect(chore.isRepeating != chore.occurrences.isEmpty, "\(chore.id)")
            #expect(chore.occurrences == chore.occurrences.sorted())
            if let next = chore.next, chore.isRepeating { #expect(chore.occurrences.contains(next), "\(chore.id)") }
        }
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

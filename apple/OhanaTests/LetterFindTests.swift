import CoreGraphics
import Foundation
import Testing
@testable import Ohana

/// What the letter scan's review finds to add: asking the server once the text is read, its
/// answer (found, nothing, no assistant, an error, given up on Done), the editor's draft and
/// adding the ticked items (the ones that failed stay for another Done).
struct LetterFindTests {
    static let today = Day(year: 2026, month: 11, day: 1)

    /// Answers with `findings` (or throws `error`), after `delay` when given; records what it got.
    final class FakeFinder: LetterItemFinding {
        var findings = LetterFindings(ai: true)
        var error: (any Error)?
        var delay: Duration?
        private(set) var asked: [(text: String, today: Day, tags: [String])] = []

        func find(_ text: String, today: Day, tags: [String]) async throws -> LetterFindings {
            asked.append((text, today, tags))
            if let delay { try await Task.sleep(for: delay) }
            if let error { throw error }
            return findings
        }
    }

    static func pages(_ lines: [String]) -> [ScanPage] {
        let image = LetterFilingTests.image()
        return [ScanPage(image: image, lines: lines.enumerated().map { index, text in
            ScanLine(text: text, box: CGRect(x: 0.1, y: 0.9 - Double(index) * 0.05, width: 0.6, height: 0.02))
        })]
    }

    static func review(_ finder: FakeFinder?, tags: [String] = []) -> LetterReview {
        let settings = LetterFilingTests.settings()
        settings.remember(tags: tags)
        return LetterReview(images: [LetterFilingTests.image()], finder: finder, settings: settings, today: today)
    }

    static let items: [AssistantSuggestionOp] = [
        .init(op: "event", title: "Evening", date: "2026-11-13", start: "15:00", end: "17:00", person: "Mia"),
        .init(op: "task", title: "Sign"),
        .init(op: "poll", title: "Vote"),
        .init(op: "deadline", title: "Pay", due: "2026-11-12"),
    ]

    // MARK: Looking

    @Test func asksTheServerOnceTheTextIsRead() async {
        let finder = FakeFinder()
        finder.findings = LetterFindings(ai: true, source: "Grundschule Nord", items: Self.items)
        let review = Self.review(finder)
        #expect(review.findsItems)
        #expect(review.finding == .off)
        review.took(Self.pages(["Elternbrief", "Laternenfest am 13.11."]))
        #expect(review.reading == .read)
        #expect(review.finding == .looking)
        await review.findTask?.value
        #expect(finder.asked.count == 1)
        #expect(finder.asked.first?.text == "Elternbrief\nLaternenfest am 13.11.")
        #expect(finder.asked.first?.today == Self.today)
        #expect(review.finding == .found)
        #expect(review.foundSource == "Grundschule Nord")
        // What this app can't add is left out; the rest is ticked.
        #expect(review.found.map(\.op.title) == ["Evening", "Sign", "Pay"])
        #expect(review.found.allSatisfy { $0.picked })
        #expect(review.hasPending)
        #expect(review.needsReminders)
    }

    @Test func nothingToLookForWithoutTextOrFinder() async {
        let finder = FakeFinder()
        let review = Self.review(finder)
        review.took(Self.pages([]))
        #expect(review.readFailed)
        #expect(review.finding == .off)
        #expect(finder.asked.isEmpty)

        // The assistant's paperclip: no finder.
        let attached = Self.review(nil)
        #expect(!attached.findsItems)
        attached.took(Self.pages(["Elternbrief"]))
        #expect(attached.finding == .off)
        #expect(attached.findTask == nil)
        #expect(attached.outcome.text == "Elternbrief")
    }

    @Test func nothingFoundNoAssistantOrAnError() async {
        let finder = FakeFinder()
        let empty = Self.review(finder)
        empty.took(Self.pages(["Hallo"]))
        await empty.findTask?.value
        #expect(empty.finding == .found)
        #expect(empty.found.isEmpty)
        #expect(!empty.hasPending)

        finder.findings = LetterFindings(ai: false)
        let noAssistant = Self.review(finder)
        noAssistant.took(Self.pages(["Hallo"]))
        await noAssistant.findTask?.value
        #expect(noAssistant.finding == .off)

        finder.error = APIError.http(status: 502, message: "The model didn’t answer")
        let failed = Self.review(finder)
        failed.took(Self.pages(["Hallo"]))
        await failed.findTask?.value
        #expect(failed.finding == .failed(APIError.http(status: 502, message: "The model didn’t answer").localizedDescription))
        #expect(!failed.hasPending)
    }

    @Test func doneWhileLookingGivesUp() async {
        let finder = FakeFinder()
        finder.findings = LetterFindings(ai: true, items: Self.items)
        finder.delay = .seconds(10)
        let review = Self.review(finder)
        review.took(Self.pages(["Hallo"]))
        #expect(review.finding == .looking)
        review.stopFinding()
        #expect(review.finding == .off)
        await review.findTask?.value
        #expect(review.finding == .off)
        #expect(review.found.isEmpty)
        #expect(!review.hasPending)
    }

    @Test func decodesTheAnswerAndSendsTheText() throws {
        let json = """
        {"ai": true, "source": "Kita Sonnenschein", "items": [
          {"op": "event", "title": "Closed", "date": "2026-12-23", "endDate": "2026-12-31"},
          {"op": "deadline", "title": "Register", "due": "2026-11-20T12:00", "list": null, "listTitle": null}
        ]}
        """
        let findings = try APIClient.decoder.decode(LetterFindings.self, from: Data(json.utf8))
        #expect(findings.ai)
        #expect(findings.source == "Kita Sonnenschein")
        #expect(findings.items == [
            .init(op: "event", title: "Closed", date: "2026-12-23", endDate: "2026-12-31"),
            .init(op: "deadline", title: "Register", due: "2026-11-20T12:00"),
        ])
        #expect(findings.filing == nil)
        let off = try APIClient.decoder.decode(LetterFindings.self, from: Data(#"{"ai": false, "items": []}"#.utf8))
        #expect(off == LetterFindings(ai: false))

        let body = FamilyLetterFinder.body(String(repeating: "a", count: LetterScan.maxText + 10), today: Self.today,
                                           tags: ["Michi", "Arzt"], lang: "de")
        #expect(body.text.count == FamilyLetterFinder.maxText)
        #expect(body.today == "2026-11-01")
        #expect(body.lang == "de")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(encoded?["tags"] as? [String] == ["Michi", "Arzt"])
        #expect(FamilyLetterFinder.body("x", today: Self.today, tags: (1...300).map { "T\($0)" }).tags.count
            == FamilyLetterFinder.maxTags)
    }

    @Test func decodesTheFilingLeniently() throws {
        func filing(_ json: String) throws -> LetterFiling? {
            try APIClient.decoder.decode(LetterFindings.self, from: Data(#"{"ai": true, "items": [], "filing": \#(json)}"#.utf8)).filing
        }
        #expect(try filing(#"{"title": " Information Psychotherapie ", "date": "2026-07-16", "person": "Michael Krug", "tags": ["Michi"]}"#)
            == LetterFiling(title: "Information Psychotherapie", date: Day(year: 2026, month: 7, day: 16),
                            person: "Michael Krug", tags: ["Michi"]))
        #expect(try filing(#"{"title": "", "date": "16.07.2026", "person": 3, "tags": "Michi"}"#) == LetterFiling())
        #expect(try filing(#""nonsense""#) == nil)
        #expect(try filing("null") == nil)
    }

    // MARK: Whose letter it is, and its name

    static let psychotherapy = LetterFindings(ai: true, filing: LetterFiling(
        title: "Information Psychotherapie", date: Day(year: 2026, month: 7, day: 16), person: "Michael Krug",
        tags: ["Arzt", "Erfunden"]))

    static func filingReview(_ finder: FakeFinder) -> LetterReview {
        let review = Self.review(finder, tags: ["Michi", "Arzt", "Schule", "Mia"])
        review.people = ["Sascha Krug", "Michael Krug", "Mia Krug"]
        return review
    }

    @Test func theServersFilingNamesTheLetterAfterItsPerson() async {
        let finder = FakeFinder()
        finder.findings = Self.psychotherapy
        let review = Self.filingReview(finder)
        review.took(Self.pages(["Information zur Psychotherapie"]))
        #expect(review.suggesting)
        await review.findTask?.value
        #expect(finder.asked.first?.tags == ["Michi", "Arzt", "Schule", "Mia"])
        // Michael's tag is Michi: it names the file and comes first.
        #expect(review.filing.name == "2026-07-16_Michi_Information_Psychotherapie")
        #expect(review.filing.tags == ["Michi", "Arzt"])
        #expect(!review.suggesting)
    }

    @Test func theServerBeatsTheModelWhicheverComesFirst() async {
        let model = LetterSuggestion(title: "Brief", date: Day(year: 2026, month: 7, day: 1), tags: ["Schule"],
                                     person: "Mia Krug")

        // The model first, then the server.
        let finder = FakeFinder()
        finder.findings = Self.psychotherapy
        finder.delay = .milliseconds(50)
        let later = Self.filingReview(finder)
        later.took(Self.pages(["Hallo"]))
        later.apply(model)
        #expect(later.filing.name == "2026-07-01_Mia_Brief")
        #expect(later.filing.tags == ["Mia", "Schule"])
        await later.findTask?.value
        #expect(later.filing.name == "2026-07-16_Michi_Information_Psychotherapie")

        // The server first, then the model: the server's stays.
        finder.delay = nil
        let first = Self.filingReview(finder)
        first.took(Self.pages(["Hallo"]))
        await first.findTask?.value
        first.apply(model)
        #expect(first.filing.name == "2026-07-16_Michi_Information_Psychotherapie")
        #expect(first.filing.tags == ["Michi", "Arzt"])

        // What the server leaves out is the model's; a person not of the family is no one.
        finder.findings = LetterFindings(ai: true, filing: LetterFiling(person: "Oma Erna"))
        let partial = Self.filingReview(finder)
        partial.apply(model)
        partial.took(Self.pages(["Hallo"]))
        await partial.findTask?.value
        #expect(partial.filing.name == "2026-07-01_Mia_Brief")
    }

    @Test func theUsersEditsWinOverTheServer() async {
        let finder = FakeFinder()
        finder.findings = Self.psychotherapy
        finder.delay = .milliseconds(50)
        let review = Self.filingReview(finder)
        review.took(Self.pages(["Hallo"]))
        review.filing.editName("Mein Name")
        review.filing.addTag("Schule")
        await review.findTask?.value
        #expect(review.filing.name == "Mein Name")
        #expect(review.filing.tags == ["Schule"])
    }

    // MARK: The editor

    @Test func switchingTheKindCarriesTheDateAndTime() {
        var draft = LetterItemDraft(Self.items[0], today: Self.today)
        #expect(draft.kind == .event)
        #expect(draft.op == Self.items[0])

        draft.setKind(.task)
        #expect(draft.op == AssistantSuggestionOp(op: "task", title: "Evening", due: "2026-11-13T15:00"))
        draft.setKind(.deadline)
        #expect(draft.op.due == "2026-11-13T15:00")
        #expect(draft.problem == nil)
        draft.setKind(.event)
        #expect(draft.op == Self.items[0])

        // A task without a due day: as an event, today; as a deadline it needs a day.
        var task = LetterItemDraft(Self.items[1], today: Self.today)
        #expect(task.day == nil)
        task.setKind(.deadline)
        #expect(task.problem != nil)
        task.setHasDue(true)
        #expect(task.problem == nil)
        #expect(task.op.due == "2026-11-01")
        task.setHasDue(false)
        task.setKind(.event)
        #expect(task.op == AssistantSuggestionOp(op: "event", title: "Sign", date: "2026-11-01"))

        var blank = task
        blank.title = "  "
        #expect(blank.problem != nil)
    }

    @Test func editorDaysAndTimes() {
        var draft = LetterItemDraft(.init(op: "event", title: "Trip", date: "2026-11-13", endDate: "2026-11-15"),
                                    today: Self.today)
        #expect(draft.isAllDay)
        // A new first day keeps the length; a last day not after the first is one day.
        draft.setDay(Day(year: 2026, month: 11, day: 20))
        #expect(draft.op.date == "2026-11-20")
        #expect(draft.op.endDate == "2026-11-22")
        draft.setEndDay(Day(year: 2026, month: 11, day: 19))
        #expect(draft.op.endDate == nil)

        draft.setAllDay(false)
        #expect(draft.op.start == "09:00")
        draft.setHasEndTime(true)
        #expect(draft.op.end == "10:00")
        draft.endTime = "08:00"
        #expect(draft.timeProblem != nil)
        draft.setAllDay(true)
        #expect(draft.op.start == nil && draft.op.end == nil)
        #expect(draft.problem == nil)

        // A reminder keeps the list it was given; the note and blanks trimmed.
        var deadline = LetterItemDraft(.init(op: "deadline", title: " Pay ", note: "12 €", due: "2026-11-12",
                                             list: "L2", listTitle: "School"), today: Self.today)
        deadline.note = "  "
        #expect(deadline.op == AssistantSuggestionOp(op: "deadline", title: "Pay", due: "2026-11-12", list: "L2",
                                                     listTitle: "School"))
    }

    // MARK: Adding

    @Test func addsTheTickedOnesAndKeepsTheFailedOnes() async {
        let finder = FakeFinder()
        finder.findings = LetterFindings(ai: true, items: [
            .init(op: "event", title: "Evening", date: "2026-11-13", start: "15:00", end: "17:00"),
            .init(op: "event", title: "Refused", date: "2026-11-14"),
            .init(op: "task", title: "Sign"),
            .init(op: "event", title: "Left out", date: "2026-11-15"),
        ])
        let review = Self.review(finder)
        review.took(Self.pages(["Hallo"]))
        await review.findTask?.value
        review.togglePick(review.found[3].id)
        #expect(!review.found[3].picked)

        let events = AssistantSuggestionsTests.FakeEvents()
        events.failing = ["Refused"]
        let reminders = AssistantRemindersTests.FakeReminders()
        let first = await review.addPicked(events: events, reminders: reminders, defaultListID: "L1")
        #expect(first.ok == false)
        #expect(first.addedEvent)
        #expect(events.added.map(\.title) == ["Evening"])
        #expect(reminders.calls == ["add Sign L1 - -", "commit"])
        #expect(review.found.map(\.added) == [true, false, true, false])
        #expect(review.found[1].error == APIError.http(status: 400, message: "No").localizedDescription)
        #expect(review.found[0].error == nil)
        #expect(review.hasPending)
        #expect(!review.needsReminders)
        // An added one can't be unticked or edited any more.
        review.togglePick(review.found[0].id)
        review.update(review.found[0].id, op: .init(op: "event", title: "Changed", date: "2026-11-13"))
        #expect(review.found[0].picked && review.found[0].op.title == "Evening")

        // Editing the failed one clears its error; Done again adds only it.
        review.update(review.found[1].id, op: .init(op: "event", title: "Fixed", date: "2026-11-14"))
        #expect(review.found[1].error == nil)
        let second = await review.addPicked(events: events, reminders: nil, defaultListID: nil)
        #expect(second.ok && second.addedEvent)
        #expect(events.added.map(\.title) == ["Evening", "Fixed"])
        #expect(reminders.calls == ["add Sign L1 - -", "commit"])
        #expect(review.found.map(\.added) == [true, true, true, false])
        #expect(!review.hasPending)

        // Nothing left: Done just finishes.
        let third = await review.addPicked(events: events, reminders: nil, defaultListID: nil)
        #expect(third.ok && !third.addedEvent)
    }
}

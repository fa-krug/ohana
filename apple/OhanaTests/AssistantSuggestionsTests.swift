import Foundation
import Testing
@testable import Ohana

/// The assistant's suggestions (e.g. from a scanned letter): the item, how each suggestion reads,
/// adding the picked ones, the answer, and the letter's text.
struct AssistantSuggestionsTests {
    static let itemsJSON = """
    {
      "chat": { "id": "c1", "title": "School letter", "status": "idle", "updatedAt": "2026-11-01T08:00:00.000Z" },
      "rev": 3,
      "items": [
        { "kind": "suggestions", "id": "call_1", "summary": "4 dates from the school letter", "source": "Grundschule Nord",
          "ops": [
            { "op": "event", "title": "Parents’ evening", "date": "2026-11-13", "start": "15:00", "end": "17:00",
              "location": "Room 4", "person": "Mia", "note": "Bring the form" },
            { "op": "task", "title": "Sign the form", "list": null, "listTitle": null },
            { "op": "deadline", "title": "Pay for the trip", "due": "2026-11-12", "note": "12 €", "list": "L2",
              "listTitle": "School" },
            { "op": "poll", "title": "Vote on the date" }
          ] },
        { "kind": "suggestions", "id": "call_2", "summary": "S",
          "ops": [ { "op": "event", "title": "A", "date": "2026-11-13" }, { "op": "task", "title": "B" },
                   { "op": "task", "title": "C" } ],
          "answer": { "applied": true, "results": [ { "ok": true, "id": "e1" }, { "ok": false, "declined": true },
                                                    { "ok": false, "error": "The list is gone." } ] } },
        { "kind": "suggestions", "id": "call_3", "summary": "S", "source": "", "ops": [], "answer": { "applied": false } },
        { "kind": "suggestions", "id": "call_4", "summary": "S", "ops": [ { "op": "task", "title": "B" } ], "skipped": true }
      ]
    }
    """

    private func store(_ items: [AssistantItem]) -> AssistantChatStore {
        let store = AssistantChatStore(api: FamilyAPI(client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil),
                                                      familyID: "f1"))
        store.remindersContext = { nil }
        store.calendarContext = { nil }
        store.show(AssistantChat(id: "c1", title: "C", status: "idle", items: items, rev: 1, usage: nil, page: "calendar",
                                 queued: []))
        return store
    }

    private let gb = Locale(identifier: "en_GB")

    @Test func decodesTheSuggestionsItem() throws {
        let state = try JSONDecoder().decode(AssistantChatState.self, from: Data(Self.itemsJSON.utf8))
        #expect(state.items.count == 4)
        guard case let .suggestions(open) = state.items[0] else { Issue.record("suggestions"); return }
        #expect(open.id == "call_1")
        #expect(open.summary == "4 dates from the school letter")
        #expect(open.source == "Grundschule Nord")
        #expect(open.answer == nil)
        #expect(!open.skipped)
        #expect(open.ops.map(\.kind) == [.event, .task, .deadline, .unknown])
        #expect(open.ops[0] == AssistantSuggestionOp(op: "event", title: "Parents’ evening", date: "2026-11-13",
                                                     start: "15:00", end: "17:00", location: "Room 4", person: "Mia",
                                                     note: "Bring the form"))
        #expect(open.ops[1] == AssistantSuggestionOp(op: "task", title: "Sign the form"))
        #expect(open.ops[2].due == "2026-11-12")
        #expect(open.ops[2].list == "L2")
        #expect(open.ops[2].listTitle == "School")
        #expect(open.ops[3].op == "poll")
        // What this app can't add isn't ticked.
        #expect(open.initialPicks == [0, 1, 2])
        #expect(open.needsReminders([0]) == false)
        #expect(open.needsReminders([0, 2]))
        #expect(open.outcome == nil)

        guard case let .suggestions(answered) = state.items[1], case let .suggestions(none) = state.items[2],
              case let .suggestions(skipped) = state.items[3] else { Issue.record("answered"); return }
        #expect(answered.answer?.results == [.done("e1"), .declined, .failed("The list is gone.")])
        #expect(answered.answer?.results?[1].isDeclined == true)
        // Left out isn't failed.
        #expect(answered.answer?.failures == 1)
        #expect(answered.outcome == "Added 1 of 3, 1 failed")
        #expect(none.source == nil)
        #expect(none.outcome == "Nothing added")
        #expect(skipped.outcome == "Not answered")
    }

    @Test func declinedResultsArentFailures() {
        let answer = AssistantRemindersEdit.Answer(applied: true, results: [.done("a"), .declined, .declined])
        #expect(answer.failures == 0)
        #expect(AssistantRemindersEdit.outcome(answer: answer, skipped: false, count: 3) == "Applied")
        let edit = AssistantSuggestions(id: "s", summary: "S", ops: [
            .init(op: "task", title: "A"), .init(op: "task", title: "B"), .init(op: "task", title: "C"),
        ], answer: answer, skipped: false)
        #expect(edit.outcome == "Added 1 of 3")
        let markdown = AssistantTranscript.markdown([.suggestions(edit)])
        #expect(markdown.contains("- A · Reminders ✓"))
        #expect(markdown.contains("- B · Reminders –"))
        #expect(markdown.contains("(Added 1 of 3)"))
    }

    @Test func findsTheWaitingSuggestions() {
        let edit = AssistantSuggestions(id: "s1", summary: "S", ops: [.init(op: "task", title: "A")], answer: nil,
                                        skipped: false)
        let question = AssistantQuestion(id: "q1", question: "?", options: [], multiple: false, answer: nil, skipped: false)
        let s = store([.question(question), .suggestions(edit)])
        #expect(s.openSuggestions()?.edit.id == "s1")
        #expect(s.openQuestion() == nil)
        #expect(store([.suggestions(edit), .user(text: "No", attachments: [])]).openSuggestions() == nil)
        var answered = edit
        answered.answer = .init(applied: false, results: nil)
        #expect(store([.suggestions(answered)]).openSuggestions() == nil)

        // The ticks stay with the store.
        #expect(s.picks(edit) == [0])
        s.togglePick(edit, 0)
        #expect(s.picks(edit).isEmpty)
        s.togglePick(edit, 0)
        #expect(s.picks(edit) == [0])
    }

    @Test func notWaitingIsntAdded() async {
        let edit = AssistantSuggestions(id: "s1", summary: "S", ops: [], answer: nil, skipped: false)
        #expect(await store([.suggestions(edit)]).applySuggestions("other", selected: []) == .notWaiting)
    }

    @Test func describesTheSuggestions() {
        let single = AssistantSuggestionLine.make(.init(op: "event", title: "Parents’ evening", date: "2026-11-13",
                                                        start: "15:00", end: "17:00", location: "Room 4", person: "Mia",
                                                        note: "Bring the form"), locale: gb)
        #expect(single.icon == "calendar")
        #expect(single.title == "Parents’ evening")
        #expect(single.when?.contains("13") == true)
        #expect(single.when?.contains("15:00") == true)
        #expect(single.when?.contains("17:00") == true)
        #expect(single.detail == "Room 4 · Mia · Bring the form")

        let allDay = AssistantSuggestionLine.make(.init(op: "event", title: "Closed", date: "2026-11-13"), locale: gb)
        #expect(allDay.when?.contains("13") == true)
        #expect(allDay.when?.contains(":") == false)
        #expect(allDay.detail == nil)

        let trip = AssistantSuggestionLine.make(.init(op: "event", title: "Trip", date: "2026-11-13", endDate: "2026-11-15"),
                                                locale: gb)
        #expect(trip.when?.contains("13") == true)
        #expect(trip.when?.contains("15") == true)
        #expect(trip.when?.contains(":") == false)

        let overnight = AssistantSuggestionLine.make(.init(op: "event", title: "Camp", date: "2026-11-13",
                                                           endDate: "2026-11-14", start: "18:00", end: "10:00"), locale: gb)
        #expect(overnight.when?.contains("18:00") == true)
        #expect(overnight.when?.contains("14") == true)
        #expect(overnight.when?.contains("10:00") == true)

        let deadline = AssistantSuggestionLine.make(.init(op: "deadline", title: "Pay", note: "12 €", due: "2026-11-12",
                                                          list: "L2", listTitle: "School"), locale: gb)
        #expect(deadline.icon == "flag")
        #expect(deadline.when?.hasPrefix("by ") == true)
        #expect(deadline.when?.contains("12") == true)
        #expect(deadline.detail == "School · 12 €")

        let task = AssistantSuggestionLine.make(.init(op: "task", title: "Sign", due: "2026-11-10T18:30"), locale: gb)
        #expect(task.icon == "checklist")
        #expect(task.when?.hasPrefix("due ") == true)
        #expect(task.when?.contains("18:30") == true)
        #expect(task.detail == "Reminders")
        #expect(AssistantSuggestionLine.make(.init(op: "task", title: "Sign"), locale: gb).when == nil)

        let unknown = AssistantSuggestionLine.make(.init(op: "poll", title: "Vote"), locale: gb)
        #expect(unknown.icon == "questionmark.circle")
        #expect(unknown.detail == "This version of Ohana can’t add this.")
    }

    @Test func buildsTheEventAndTheReminder() throws {
        let event = try AssistantSuggestionOp(op: "event", title: "Trip", date: "2026-11-13", endDate: "2026-11-15",
                                              start: "08:00", end: "18:00", location: "Zoo").eventInput()
        #expect(event == CalendarEventInput(date: Day(year: 2026, month: 11, day: 13),
                                            endDate: Day(year: 2026, month: 11, day: 15), start: "08:00", end: "18:00",
                                            title: "Trip", location: "Zoo"))
        // An end without a start is all day.
        let allDay = try AssistantSuggestionOp(op: "event", title: "X", date: "2026-11-13", end: "10:00").eventInput()
        #expect(allDay.start == nil && allDay.end == nil)
        #expect(throws: DeviceCalendarError.self) {
            try AssistantSuggestionOp(op: "event", title: "X", date: "13.11.2026").eventInput()
        }
        #expect(throws: DeviceCalendarError.self) {
            try AssistantSuggestionOp(op: "event", title: "X", date: "2026-11-13", start: "25:00").eventInput()
        }

        let deadline = try AssistantSuggestionOp(op: "deadline", title: "Pay", note: "12 €", due: "2026-11-12T09:30")
            .reminderDraft()
        #expect(deadline == ReminderDraft(title: "Pay", notes: "12 €",
                                          due: ReminderDue(day: Day(year: 2026, month: 11, day: 12), hour: 9, minute: 30)))
        #expect(throws: DeviceCalendarError.self) { try AssistantSuggestionOp(op: "deadline", title: "Pay").reminderDraft() }
        let task = try AssistantSuggestionOp(op: "task", title: "Sign").reminderDraft()
        #expect(task.due == nil)
    }

    /// Records the events added; titles in `failing` are refused.
    final class FakeEvents: AssistantEventCreating {
        var added: [CalendarEventInput] = []
        var failing: Set<String> = []

        func createEvent(_ input: CalendarEventInput) async throws -> String {
            if failing.contains(input.title) { throw APIError.http(status: 400, message: "No") }
            added.append(input)
            return "ev-\(input.title)"
        }
    }

    private var ops: [AssistantSuggestionOp] {
        [
            .init(op: "event", title: "Evening", date: "2026-11-13", start: "15:00", end: "17:00"),
            .init(op: "task", title: "Sign"),
            .init(op: "deadline", title: "Pay", due: "2026-11-12", list: "L2", listTitle: "School"),
            .init(op: "event", title: "Refused", date: "2026-11-14"),
            .init(op: "poll", title: "Vote"),
            .init(op: "event", title: "Left out", date: "2026-11-15"),
        ]
    }

    @Test func addsThePickedOnes() async {
        let events = FakeEvents()
        events.failing = ["Refused"]
        let reminders = AssistantRemindersTests.FakeReminders()
        let results = await AssistantSuggestionsApply.perform(ops, picks: [0, 1, 2, 3, 4], events: events,
                                                              reminders: reminders, defaultListID: "L1")
        #expect(events.added.map(\.title) == ["Evening"])
        #expect(reminders.calls == ["add Sign L1 - -", "add Pay L2 2026-11-12 -", "commit"])
        #expect(results.count == 6)
        #expect(results[0] == .done("ev-Evening"))
        #expect(results[1] == .done("new-Sign"))
        #expect(results[2] == .done("new-Pay"))
        #expect(results[3].failed)
        #expect(results[3].error == APIError.http(status: 400, message: "No").localizedDescription)
        #expect(results[4] == .failed(AssistantSuggestionsApply.ApplyError.unsupported.localizedDescription))
        #expect(results[5] == .declined)
    }

    @Test func remindersFailTogether() async {
        let events = FakeEvents()
        let broken = AssistantRemindersTests.FakeReminders()
        broken.commitFails = true
        let results = await AssistantSuggestionsApply.perform(ops, picks: [0, 1, 2], events: events, reminders: broken,
                                                              defaultListID: "L1")
        #expect(broken.calls.suffix(2) == ["commit", "reset"])
        // The event is in the calendar; the reminders aren't saved.
        #expect(results[0] == .done("ev-Evening"))
        #expect(results[1] == .failed(RemindersError.noAccess.localizedDescription))
        #expect(results[2] == .failed(RemindersError.noAccess.localizedDescription))
        #expect(results[3...].filter(\.isDeclined).count == 3)

        // No default list for a task without one.
        let reminders = AssistantRemindersTests.FakeReminders()
        let noList = await AssistantSuggestionsApply.perform(ops, picks: [1, 2], events: events, reminders: reminders,
                                                             defaultListID: nil)
        #expect(noList[1] == .failed(AssistantSuggestionsApply.ApplyError.noDefaultList.localizedDescription))
        #expect(noList[2] == .done("new-Pay"))
        #expect(reminders.calls == ["add Pay L2 2026-11-12 -", "commit"])

        // Only events: Reminders isn't touched.
        let none = await AssistantSuggestionsApply.perform(ops, picks: [0], events: FakeEvents(), reminders: nil,
                                                           defaultListID: nil)
        #expect(none.map(\.ok) == [true, false, false, false, false, false])
    }

    @Test func encodesTheAnswer() throws {
        let applied = AssistantChatStore.remindersAnswer(
            id: "call_1", answer: .init(applied: true, results: [.done("e1"), .declined, .failed("No")]),
            page: "calendar", year: 2026, lang: "en", today: "2026-11-01", reminders: nil
        )
        let a = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(applied)) as? [String: Any]
        #expect(a?["id"] as? String == "call_1")
        #expect(a?["applied"] as? Bool == true)
        let results = a?["results"] as? [[String: Any]] ?? []
        #expect(results.count == 3)
        #expect(results[0]["ok"] as? Bool == true)
        #expect(results[0]["id"] as? String == "e1")
        #expect(results[0]["declined"] == nil)
        #expect(results[1]["ok"] as? Bool == false)
        #expect(results[1]["declined"] as? Bool == true)
        #expect(results[1]["error"] == nil)
        #expect(results[2]["error"] as? String == "No")

        let declined = AssistantChatStore.remindersAnswer(
            id: "call_1", answer: .init(applied: false, results: nil), page: "calendar", year: 2026, lang: "de",
            today: "2026-11-01", reminders: nil
        )
        let d = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(declined)) as? [String: Any]
        #expect(d?["applied"] as? Bool == false)
        #expect(d?["results"] == nil)
    }

    @Test func namesTheTool() {
        let call = AssistantToolCall(id: "t", name: "suggest_items", args: ["items": .array([
            .object(["op": .string("event"), "title": .string("Evening")]),
            .object(["op": .string("task"), "title": .string("Sign")]),
        ])], status: "ok", summary: nil, result: nil, interrupted: false)
        #expect(AssistantToolLabels.label(call) == "Suggesting what to add")
        #expect(AssistantToolLabels.icon("suggest_items") == "doc.text.viewfinder")
        #expect(AssistantToolLabels.detail(call) == "2 suggestions · Evening, Sign")
    }

    @Test func readsTheLetterInOrder() {
        func piece(_ text: String, x: Double, y: Double) -> ReceiptTextPiece {
            ReceiptTextPiece(text: text, x: x, y: y, height: 0.02)
        }
        let first = [piece("Dear parents,", x: 0.1, y: 0.2), piece("Grundschule Nord", x: 0.1, y: 0.05),
                     piece("13 Nov", x: 0.7, y: 0.051), piece("the trip is on Friday.", x: 0.1, y: 0.25)]
        let second = [piece("Kind regards", x: 0.1, y: 0.1)]
        #expect(AssistantLetter.text(pages: [first, [], second])
            == "Grundschule Nord  13 Nov\nDear parents,\nthe trip is on Friday.\n\nKind regards")
        #expect(AssistantLetter.text(pages: [[], [piece("  ", x: 0, y: 0)]]).isEmpty)

        let attachment = AssistantLetter.attachment("Dear parents")
        #expect(attachment.kind == "file")
        #expect(attachment.name == "Scanned letter.txt")
        #expect(attachment.outgoing.text == "Dear parents")
        #expect(attachment.outgoing.url == nil)
        #expect(AssistantLetter.attachment(String(repeating: "a", count: LetterScan.maxText + 10)).text?.hasSuffix("…(cut off)") == true)
    }

    @Test func asksWithAttachments() {
        let family = FamilyContext(family: FamilySummary(id: "f1", name: "F", role: .editor, memberCount: 1), api: FamilyAPI(
            client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil), familyID: "f1"))
        family.ask("Hi")
        #expect(family.takeAssistantRequest()?.attachments.isEmpty == true)
        family.ask(AssistantLetter.prompt, send: true, newChat: true, attachments: [AssistantLetter.attachment("Text")])
        let request = family.takeAssistantRequest()
        #expect(request?.send == true)
        #expect(request?.newChat == true)
        #expect(request?.attachments.map(\.name) == ["Scanned letter.txt"])
    }
}

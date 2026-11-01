import Foundation
import Testing
@testable import Ohana

/// The assistant's Apple Calendar tools on the device: the edit item, the snapshot every request
/// carries, the times of an event, applying an edit and its answer.
struct AssistantAppleCalendarTests {
    static let itemsJSON = """
    {
      "chat": { "id": "c1", "title": "Dentist", "status": "idle", "updatedAt": "2026-11-01T08:00:00.000Z" },
      "rev": 3,
      "items": [
        { "kind": "calendar", "id": "call_1", "summary": "Add 1 event, change 1 event, delete 1 event",
          "ops": [
            { "op": "add", "calendar": "C1", "calendarTitle": "Family", "title": "Dentist", "start": "2026-11-05T09:00",
              "end": "2026-11-05T10:00", "location": "Main St 1", "rrule": "FREQ=WEEKLY;BYDAY=TH" },
            { "op": "update", "id": "E1@2026-11-12", "span": "future", "eventTitle": "Yoga", "eventStart": "2026-11-12T18:00",
              "eventEnd": "2026-11-12T19:00", "eventAllDay": false, "calendar": "C2", "calendarTitle": "Work",
              "start": "2026-11-12T19:00", "notes": "" },
            { "op": "delete", "id": "E2", "eventTitle": "Trip", "calendar": "C1", "calendarTitle": "Family",
              "start": "2026-11-20", "end": "2026-11-22", "allDay": true },
            { "op": "teleport", "id": "E3" }
          ] },
        { "kind": "calendar", "id": "call_2", "summary": "Delete “X”",
          "ops": [ { "op": "delete", "id": "E9", "eventTitle": "X", "calendar": "C1", "calendarTitle": "Family" } ],
          "answer": { "applied": true, "results": [ { "ok": false, "error": "The event is gone." } ] } },
        { "kind": "calendar", "id": "call_3", "summary": "S", "ops": [], "answer": { "applied": false } },
        { "kind": "calendar", "id": "call_4", "summary": "S", "ops": [], "skipped": true }
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

    private func at(_ day: Day, _ hour: Int, _ minute: Int = 0) -> Date {
        Day.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day.date)!
    }

    private let nov5 = Day(year: 2026, month: 11, day: 5)

    @Test func decodesTheCalendarItem() throws {
        let state = try JSONDecoder().decode(AssistantChatState.self, from: Data(Self.itemsJSON.utf8))
        #expect(state.items.count == 4)
        guard case let .calendar(open) = state.items[0] else { Issue.record("calendar"); return }
        #expect(open.id == "call_1")
        #expect(open.answer == nil)
        #expect(!open.skipped)
        #expect(open.ops.map(\.op) == ["add", "update", "delete", "teleport"])
        #expect(open.ops[0] == AssistantCalendarOp(op: "add", calendar: "C1", calendarTitle: "Family", title: "Dentist",
                                                   start: "2026-11-05T09:00", end: "2026-11-05T10:00",
                                                   location: "Main St 1", rrule: "FREQ=WEEKLY;BYDAY=TH"))
        let update = open.ops[1]
        #expect(update.span == "future")
        #expect(update.eventStart == "2026-11-12T18:00")
        #expect(update.eventAllDay == false)
        #expect(update.start == "2026-11-12T19:00")
        #expect(update.end == nil)
        #expect(update.notes == "")
        #expect(update.near == Day(year: 2026, month: 11, day: 12))
        // A delete's times are the event's.
        let delete = open.ops[2]
        #expect(delete.eventStart == "2026-11-20")
        #expect(delete.eventEnd == "2026-11-22")
        #expect(delete.eventAllDay == true)
        #expect(delete.start == nil)
        #expect(delete.allDay == nil)
        #expect(open.ops[3].calendar == "")
        #expect(open.outcome == nil)

        guard case let .calendar(failed) = state.items[1], case let .calendar(declined) = state.items[2],
              case let .calendar(skipped) = state.items[3] else { Issue.record("answered"); return }
        #expect(failed.answer?.results == [.failed("The event is gone.")])
        #expect(failed.outcome == "Applied, 1 of 1 failed")
        #expect(declined.outcome == "Not applied")
        #expect(skipped.outcome == "Not answered")
    }

    @Test func findsTheWaitingEdit() {
        let edit = AssistantCalendarEdit(id: "e1", summary: "Add “Dentist”", ops: [], answer: nil, skipped: false)
        let reminders = AssistantRemindersEdit(id: "r1", summary: "Add “Milk”", ops: [], answer: nil, skipped: false)
        // Only the last of them waits.
        let s = store([.reminders(reminders), .calendar(edit)])
        #expect(s.openCalendarEdit()?.edit.id == "e1")
        #expect(s.openRemindersEdit() == nil)
        #expect(store([.calendar(edit), .reminders(reminders)]).openCalendarEdit() == nil)
        #expect(store([.calendar(edit), .user(text: "No", attachments: [])]).openCalendarEdit() == nil)
        var answered = edit
        answered.answer = .init(applied: false, results: nil)
        #expect(store([.calendar(answered)]).openCalendarEdit() == nil)
        #expect(store([.calendar(edit)]).applyCalendar("other") == .notWaiting)
    }

    @Test func parsesTheIDs() {
        #expect(DeviceEventRef("ABC:123@2026-11-12") == DeviceEventRef(id: "ABC:123", occurrence: Day(year: 2026, month: 11, day: 12)))
        #expect(DeviceEventRef("ABC:123") == DeviceEventRef(id: "ABC:123"))
        #expect(DeviceEventRef("a@b.c") == DeviceEventRef(id: "a@b.c"))
        #expect(DeviceEventRef(id: "X", occurrence: nov5).description == "X@2026-11-05")
    }

    @Test func buildsTheSnapshot() throws {
        let calendars = (0..<105).map { DeviceCalendar(id: "C\($0)", title: "Cal \($0)", account: "iCloud", isWritable: true) }
            + [DeviceCalendar(id: String(repeating: "x", count: 301), title: "Long", account: "iCloud", isWritable: true)]
        let long = String(repeating: "a", count: 250)
        let start = ReminderDue(day: nov5, hour: 9, minute: 0)
        let end = ReminderDue(day: nov5, hour: 10, minute: 0)
        var events = (0..<1010).map { i in
            DeviceEvent(id: "E\(i)", calendarID: "C0", title: "Event \(i)", allDay: false,
                        start: ReminderDue(day: nov5.adding(days: 1 + i / 20), hour: 9, minute: 0),
                        end: ReminderDue(day: nov5.adding(days: 1 + i / 20), hour: 10, minute: 0))
        }
        events += [
            DeviceEvent(id: "first", calendarID: "C1", title: "  \(long)  ", allDay: false, start: start, end: end,
                        location: String(repeating: "l", count: 400), notes: String(repeating: "n", count: 1200)),
            DeviceEvent(id: "allday", calendarID: "C1", title: "Trip", allDay: true, start: ReminderDue(day: nov5),
                        end: ReminderDue(day: nov5.adding(days: 2)), location: " ", notes: ""),
            DeviceEvent(id: "beyond", calendarID: "C104", title: "Beyond the calendars", allDay: false, start: start, end: end),
        ]
        let snapshot = AssistantCalendarContext.build(calendars: calendars, events: events, from: nov5.adding(days: -7),
                                                      to: nov5.adding(days: 90), ohanaCalendarID: "C3")
        #expect(snapshot.from == "2026-10-29")
        #expect(snapshot.calendars.count == 100)
        #expect(snapshot.calendars.filter(\.ohana).map(\.id) == ["C3"])
        #expect(snapshot.events.count == 1000)
        #expect(snapshot.events[0].id == "allday") // all day first, then by start
        #expect(snapshot.events[1].id == "first")
        #expect(snapshot.events[1].title.count == 200)
        #expect(snapshot.events[1].title.first == "a")
        #expect(snapshot.events[1].location?.count == 300)
        #expect(snapshot.events[1].notes?.count == 1000)
        #expect(snapshot.events[0].location == nil)
        #expect(snapshot.events[0].notes == nil)
        #expect(!snapshot.events.contains { $0.id == "beyond" })

        let repeating = DeviceEvent(id: "S1", calendarID: "C1", title: "Yoga", allDay: false, start: start, end: end,
                                    rrule: "FREQ=WEEKLY;BYDAY=TH", occurrence: nov5)
        let small = AssistantCalendarContext.build(
            calendars: [DeviceCalendar(id: "C1", title: "Family", account: "iCloud", isWritable: true),
                        DeviceCalendar(id: "H", title: "Holidays", account: "Subscribed", isWritable: false)],
            events: [repeating, events[1011]], from: nov5, to: nov5, ohanaCalendarID: nil
        )
        let json = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(small)) as? [String: Any]
        #expect(json?["from"] as? String == "2026-11-05")
        let cals = json?["calendars"] as? [[String: Any]] ?? []
        #expect(cals.count == 2)
        #expect(cals[0]["account"] as? String == "iCloud")
        #expect(cals[0]["ohana"] as? Bool == false)
        #expect(cals[1]["writable"] as? Bool == false)
        let list = json?["events"] as? [[String: Any]] ?? []
        #expect(list.count == 2)
        #expect(list[0]["id"] as? String == "allday")
        #expect(list[0]["allDay"] as? Bool == true)
        #expect(list[0]["start"] as? String == "2026-11-05")
        #expect(list[0]["end"] as? String == "2026-11-07")
        #expect(list[0]["location"] == nil)
        #expect(list[0]["rrule"] == nil)
        #expect(list[1]["id"] as? String == "S1@2026-11-05")
        #expect(list[1]["calendar"] as? String == "C1")
        #expect(list[1]["start"] as? String == "2026-11-05T09:00")
        #expect(list[1]["end"] as? String == "2026-11-05T10:00")
        #expect(list[1]["rrule"] as? String == "FREQ=WEEKLY;BYDAY=TH")
    }

    @Test func eventTimes() {
        let nine = ReminderDue(day: nov5, hour: 9, minute: 0)
        // A timed event without an end lasts an hour; a date alone is all day.
        let timed = DeviceEventTimes.new(start: nine, end: nil, allDay: nil)
        #expect(timed == DeviceEventTimes(start: at(nov5, 9), end: at(nov5, 10), allDay: false))
        let trip = DeviceEventTimes.new(start: ReminderDue(day: nov5), end: ReminderDue(day: nov5.adding(days: 2)), allDay: nil)
        #expect(trip.allDay)
        #expect(trip.start == Day.calendar.startOfDay(for: nov5.date))
        #expect(trip.lastDay == nov5.adding(days: 2))
        #expect(trip.text.start.description == "2026-11-05")
        #expect(trip.text.end.description == "2026-11-07")
        let overnight = DeviceEventTimes.new(start: ReminderDue(day: nov5, hour: 22, minute: 0),
                                             end: ReminderDue(day: nov5.adding(days: 1), hour: 1, minute: 30), allDay: nil)
        #expect(overnight.text.end.description == "2026-11-06T01:30")

        // A moved start keeps the length; a new end alone keeps the start.
        let meeting = DeviceEventTimes(start: at(nov5, 9), end: at(nov5, 10, 30), allDay: false)
        #expect(meeting.changed(start: ReminderDue(day: nov5.adding(days: 1), hour: 14, minute: 0), end: nil, allDay: nil)
            == DeviceEventTimes(start: at(nov5.adding(days: 1), 14), end: at(nov5.adding(days: 1), 15, 30), allDay: false))
        #expect(meeting.changed(start: nil, end: ReminderDue(day: nov5, hour: 12, minute: 0), allDay: nil)
            == DeviceEventTimes(start: at(nov5, 9), end: at(nov5, 12), allDay: false))
        #expect(meeting.changed(start: nil, end: nil, allDay: true).text.start.description == "2026-11-05")
        // An all-day event moved keeps its days; made timed it lasts an hour.
        let moved = trip.changed(start: ReminderDue(day: nov5.adding(days: 7)), end: nil, allDay: nil)
        #expect(moved.allDay)
        #expect(moved.text.start.description == "2026-11-12")
        #expect(moved.text.end.description == "2026-11-14")
        #expect(trip.changed(start: ReminderDue(day: nov5, hour: 15, minute: 0), end: nil, allDay: nil)
            == DeviceEventTimes(start: at(nov5, 15), end: at(nov5, 16), allDay: false))
        // An all-day end at midnight (as some accounts keep it) ends the day before.
        let stored = DeviceEventTimes(start: Day.calendar.startOfDay(for: nov5.date),
                                      end: Day.calendar.startOfDay(for: nov5.adding(days: 1).date), allDay: true)
        #expect(stored.lastDay == nov5)
    }

    @Test func describesTheOps() {
        let gb = Locale(identifier: "en_GB")
        let add = AssistantCalendarOp(op: "add", calendar: "C1", calendarTitle: "Family", title: "Dentist",
                                      start: "2026-11-05T09:00", end: "2026-11-05T10:00", location: "Main St 1",
                                      rrule: "FREQ=WEEKLY")
        let line = AssistantCalendarOpLine.make(add, locale: gb)
        #expect(line.text == "Add “Dentist” to Family")
        #expect(line.detail?.contains("09:00 – 10:00") == true)
        #expect(line.detail?.contains("Weekly") == true)
        #expect(line.detail?.hasSuffix("Main St 1") == true)
        #expect(!line.destructive)

        let trip = AssistantCalendarOpLine.whenText(start: ReminderDue(day: nov5), end: ReminderDue(day: nov5.adding(days: 2)),
                                                    allDay: true, locale: gb)
        #expect(trip.contains("5"))
        #expect(trip.contains("7"))
        #expect(!trip.contains(":"))

        let move = AssistantCalendarOp(op: "update", id: "E1", eventTitle: "Yoga", eventStart: "2026-11-05T18:00",
                                       calendar: "C2", calendarTitle: "Work")
        let moved = AssistantCalendarOpLine.make(move, locale: gb)
        #expect(moved.text.hasPrefix("Move “Yoga” to Work · "))
        #expect(moved.text.contains("18:00"))

        let change = AssistantCalendarOp(op: "update", id: "E1@2026-11-05", span: "future", eventTitle: "Yoga",
                                         calendar: "C2", calendarTitle: "Work", title: "Pilates", location: "", notes: "Mat")
        let changed = AssistantCalendarOpLine.make(change, currentCalendarID: "C2")
        #expect(changed.text == "Change “Yoga”")
        #expect(changed.detail == "rename to “Pilates”, remove the location, notes: Mat, this and all following")
        #expect(AssistantCalendarOpLine.make(change, currentCalendarID: "C1").detail?.contains("move to Work") == true)

        let delete = AssistantCalendarOp(op: "delete", id: "E2@2026-11-05", eventTitle: "Yoga", eventStart: "2026-11-05",
                                         eventAllDay: true, calendar: "C1", calendarTitle: "Family")
        let deleted = AssistantCalendarOpLine.make(delete, locale: gb)
        #expect(deleted.text.hasPrefix("Delete “Yoga” · "))
        #expect(deleted.detail == "Family · only this one")
        #expect(deleted.destructive)
    }

    @Test func encodesTheAnswer() throws {
        let context = AssistantCalendarContext(
            from: "2026-10-25", to: "2027-01-30",
            calendars: [.init(id: "C1", title: "Family", account: "iCloud", writable: true, ohana: true)], events: []
        )
        let applied = AssistantChatStore.calendarAnswer(
            id: "call_1", answer: .init(applied: true, results: [.done("new"), .failed("The event is gone.")]),
            page: "calendar", year: 2026, lang: "en", today: "2026-11-01", reminders: nil, appleCalendar: context
        )
        let a = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(applied)) as? [String: Any]
        #expect(a?["id"] as? String == "call_1")
        #expect(a?["applied"] as? Bool == true)
        #expect(a?["page"] as? String == "calendar")
        let results = a?["results"] as? [[String: Any]] ?? []
        #expect(results.count == 2)
        #expect(results[0]["id"] as? String == "new")
        #expect(results[1]["error"] as? String == "The event is gone.")
        #expect((a?["appleCalendar"] as? [String: Any])?["from"] as? String == "2026-10-25")
        #expect(a?["reminders"] == nil)

        let declined = AssistantChatStore.calendarAnswer(
            id: "call_1", answer: .init(applied: false, results: nil), page: "calendar", year: 2026, lang: "de",
            today: "2026-11-01", reminders: nil, appleCalendar: nil
        )
        let d = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(declined)) as? [String: Any]
        #expect(d?["applied"] as? Bool == false)
        #expect(d?["results"] == nil)
        #expect(d?["appleCalendar"] == nil)

        let message = AssistantChatInput(text: "Hi", attachments: nil, page: "overview", year: 2026, lang: "en",
                                         today: "2026-11-01", reminders: nil, appleCalendar: context)
        let m = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(message)) as? [String: Any]
        #expect(((m?["appleCalendar"] as? [String: Any])?["calendars"] as? [[String: Any]])?.first?["ohana"] as? Bool == true)
        let without = AssistantChatInput(text: "Hi", attachments: nil, page: "overview", year: 2026, lang: "en",
                                         today: "2026-11-01", reminders: nil)
        let w = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(without)) as? [String: Any]
        #expect(w?["appleCalendar"] == nil)
    }

    /// Records what applying does; ids in `missing` are gone, and `commitFails` breaks the save.
    final class FakeCalendars: DeviceCalendarWriting {
        var calls: [String] = []
        var missing: Set<String> = []
        var commitFails = false
        var committed = false
        var calendars = ["C1": DeviceCalendar(id: "C1", title: "Family", account: "", isWritable: true),
                         "C2": DeviceCalendar(id: "C2", title: "Work", account: "", isWritable: true),
                         "H": DeviceCalendar(id: "H", title: "Holidays", account: "", isWritable: false)]

        func calendar(_ id: String) -> DeviceCalendar? { calendars[id] }
        func add(_ draft: DeviceEventDraft, commit: Bool) throws -> () -> String? {
            #expect(!commit)
            guard let calendar = calendars[draft.calendarID] else { throw DeviceCalendarError.calendarNotFound }
            guard calendar.isWritable else { throw DeviceCalendarError.readOnlyCalendar }
            let text = draft.times.text
            calls.append("add \(draft.title) \(draft.calendarID) \(text.start)-\(text.end) \(draft.rule?.string ?? "-")")
            return { [unowned self] in committed ? "new-\(draft.title)" : nil }
        }
        func update(_ ref: DeviceEventRef, near: Day?, span: DeviceEventSpan, _ change: DeviceEventChange, commit: Bool) throws {
            guard !missing.contains(ref.id) else { throw DeviceCalendarError.eventNotFound }
            let notes = change.notes.map { $0 ?? "clear" } ?? "keep"
            calls.append("update \(ref) \(span) \(change.title ?? "-") \(change.start?.description ?? "-") \(notes) "
                + "\(change.calendarID ?? "-") near \(near?.description ?? "-")")
        }
        func delete(_ ref: DeviceEventRef, near: Day?, span: DeviceEventSpan, commit: Bool) throws {
            guard !missing.contains(ref.id) else { throw DeviceCalendarError.eventNotFound }
            calls.append("delete \(ref) \(span)")
        }
        func commit() throws {
            calls.append("commit")
            if commitFails { throw DeviceCalendarError.noAccess }
            committed = true
        }
        func reset() { calls.append("reset") }
    }

    @Test func appliesEachOpAndReportsFailures() {
        let ops = [
            AssistantCalendarOp(op: "add", calendar: "C1", calendarTitle: "Family", title: "Dentist",
                                start: "2026-11-05T09:00", rrule: "FREQ=WEEKLY;BYDAY=TH"),
            AssistantCalendarOp(op: "update", id: "E1@2026-11-12", span: "future", eventTitle: "Yoga",
                                eventStart: "2026-11-13T18:00", calendar: "C2", calendarTitle: "Work",
                                start: "2026-11-12T19:00", notes: ""),
            AssistantCalendarOp(op: "delete", id: "gone", eventTitle: "Gone", calendar: "C1", calendarTitle: "Family"),
            AssistantCalendarOp(op: "update", id: "E2", eventTitle: "Y", calendar: "H", calendarTitle: "Holidays", title: "Z"),
            AssistantCalendarOp(op: "add", calendar: "C1", calendarTitle: "Family", title: "Bad", start: "tomorrow"),
            AssistantCalendarOp(op: "add", calendar: "C1", calendarTitle: "Family", title: "Bad rule", start: "2026-11-05",
                                rrule: "FREQ=SOMETIMES"),
            AssistantCalendarOp(op: "delete", id: "E3@2026-11-05", eventTitle: "V", calendar: "C1", calendarTitle: "Family"),
            AssistantCalendarOp(op: "teleport", calendar: "", calendarTitle: ""),
        ]
        let fake = FakeCalendars()
        fake.missing = ["gone"]
        let results = AssistantCalendarApply.perform(ops, on: fake)
        #expect(fake.calls == [
            "add Dentist C1 2026-11-05T09:00-2026-11-05T10:00 FREQ=WEEKLY;BYDAY=TH",
            "update E1@2026-11-12 future - 2026-11-12T19:00 clear C2 near 2026-11-13",
            "delete E3@2026-11-05 this",
            "commit",
        ])
        #expect(results.map(\.ok) == [true, true, false, false, false, false, true, false])
        #expect(results[0].id == "new-Dentist") // once saved
        #expect(results[1].id == "E1@2026-11-12")
        #expect(results[2].error == DeviceCalendarError.eventNotFound.errorDescription)
        #expect(results[3].error == DeviceCalendarError.readOnlyCalendar.errorDescription)
        #expect(results[4].error == DeviceCalendarError.invalidTime.errorDescription)
        #expect(results[5].error == DeviceCalendarError.invalidRule.errorDescription)

        let broken = FakeCalendars()
        broken.commitFails = true
        let none = AssistantCalendarApply.perform(Array(ops.prefix(2)), on: broken)
        #expect(broken.calls.suffix(2) == ["commit", "reset"])
        #expect(none.allSatisfy { !$0.ok && $0.error == DeviceCalendarError.noAccess.errorDescription })

        // Nothing went through: nothing to save.
        let nothing = FakeCalendars()
        nothing.missing = ["gone"]
        _ = AssistantCalendarApply.perform([ops[2]], on: nothing)
        #expect(nothing.calls.isEmpty)
    }

    @Test func namesTheTools() {
        func call(_ name: String, _ args: [String: JSONValue] = [:]) -> AssistantToolCall {
            AssistantToolCall(id: "t", name: name, args: args, status: "ok", summary: nil, result: nil, interrupted: false)
        }
        #expect(AssistantToolLabels.label(call("get_apple_calendar")) == "Reading your Apple calendars")
        #expect(AssistantToolLabels.label(call("edit_apple_calendar")) == "Suggesting changes to your Apple calendars")
        #expect(AssistantToolLabels.icon("edit_apple_calendar") == "calendar.badge.checkmark")
        #expect(AssistantToolLabels.detail(call("get_apple_calendar", ["calendar": .string("Work")])) == "“Work”")
        let edit = call("edit_apple_calendar", ["ops": .array([
            .object(["op": .string("add"), "calendar": .string("Family"), "title": .string("Dentist")]),
            .object(["op": .string("delete"), "id": .string("E1")]),
        ])])
        #expect(AssistantToolLabels.detail(edit) == "2 changes · Dentist")
        #expect(AssistantToolLinks.route(edit, familyID: "f1") == nil)
    }
}

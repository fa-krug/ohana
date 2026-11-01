import Foundation
import Testing
@testable import Ohana

private func d(_ s: String) -> Day { Day(s)! }

private let en = Locale(identifier: "en_US")

/// How repeat rules read, and the Repeat menu's choices.
struct RepeatRuleTextTests {
    private func summary(_ rrule: String) -> String? { RepeatRule(rrule)?.summary(locale: en) }

    @Test func readsTheRulesTheEditorMakes() {
        #expect(summary("FREQ=DAILY") == "Daily")
        #expect(summary("FREQ=WEEKLY") == "Weekly")
        #expect(summary("FREQ=MONTHLY") == "Monthly")
        #expect(summary("FREQ=YEARLY") == "Yearly")
        #expect(summary("FREQ=DAILY;INTERVAL=3;COUNT=5") == "Every 3 days, 5 times")
        #expect(summary("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20270101")
                == "Every 2 weeks on Monday and Wednesday, until Jan 1, 2027")
        #expect(summary("FREQ=WEEKLY;BYDAY=FR,MO,WE") == "Weekly on Monday, Wednesday, and Friday")
        #expect(summary("FREQ=MONTHLY;BYDAY=-1FR") == "Monthly on the last Friday")
        #expect(summary("FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU") == "Every 2 months on the second Tuesday")
        #expect(summary("FREQ=MONTHLY;BYMONTHDAY=15") == "Monthly on the 15th")
        #expect(summary("FREQ=YEARLY;INTERVAL=4") == "Every 4 years")
    }

    @Test func readsRulesFromElsewhere() {
        #expect(summary("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1") == "Monthly on the last weekday")
        #expect(summary("FREQ=MONTHLY;BYMONTHDAY=1,15") == "Monthly on the 1st and 15th")
        #expect(summary("FREQ=MONTHLY;BYMONTHDAY=-1") == "Monthly on the last day")
        #expect(summary("FREQ=YEARLY;BYMONTH=3,6") == "Yearly in March and June")
        #expect(summary("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH") == "Yearly in November on the fourth Thursday")
    }

    @Test func knowsWhichRulesTheEditorCanChange() throws {
        #expect(try #require(RepeatRule("FREQ=WEEKLY;BYDAY=MO,WE")).isEditable)
        #expect(try #require(RepeatRule("FREQ=MONTHLY;BYMONTHDAY=15")).isEditable)
        #expect(try #require(RepeatRule("FREQ=MONTHLY;BYDAY=-1FR")).isEditable)
        #expect(!(try #require(RepeatRule("FREQ=MONTHLY;BYMONTHDAY=1,15")).isEditable))
        #expect(!(try #require(RepeatRule("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")).isEditable))
        #expect(!(try #require(RepeatRule("FREQ=YEARLY;BYMONTH=3")).isEditable))
    }

    @Test func picksTheMenusChoice() {
        #expect(CalendarRepeatChoice(nil) == .never)
        #expect(CalendarRepeatChoice(RepeatRule("FREQ=DAILY")) == .daily)
        // A preset with an end is still the preset.
        #expect(CalendarRepeatChoice(RepeatRule("FREQ=WEEKLY;UNTIL=20270101")) == .weekly)
        #expect(CalendarRepeatChoice(RepeatRule("FREQ=WEEKLY;INTERVAL=2;COUNT=4")) == .biweekly)
        #expect(CalendarRepeatChoice(RepeatRule("FREQ=WEEKLY;BYDAY=MO,WE")) == .custom)
        #expect(CalendarRepeatChoice(RepeatRule("FREQ=MONTHLY;BYDAY=-1FR")) == .custom)
    }

    @Test func picksTheDayOfAMonthlyRule() throws {
        // 3 Nov 2026 is the first Tuesday, 27 Nov the last Friday.
        #expect(CalendarMonthlyRepeat.position(of: d("2026-11-03")) == (1, 3))
        #expect(CalendarMonthlyRepeat.position(of: d("2026-11-27")) == (-1, 6))
        let start = d("2026-11-15")
        var rule = RepeatRule(.monthly)
        #expect(CalendarMonthlyRepeat(rule, start: start) == .day(15))
        CalendarMonthlyRepeat.day(20).apply(to: &rule, start: start)
        #expect(rule.string == "FREQ=MONTHLY;BYMONTHDAY=20")
        // The event's own day needs no BYMONTHDAY.
        CalendarMonthlyRepeat.day(15).apply(to: &rule, start: start)
        #expect(rule.string == "FREQ=MONTHLY")
        CalendarMonthlyRepeat.weekday(ordinal: -1, weekday: 6).apply(to: &rule, start: start)
        #expect(rule.string == "FREQ=MONTHLY;BYDAY=-1FR")
        #expect(CalendarMonthlyRepeat(rule, start: start) == .weekday(ordinal: -1, weekday: 6))
    }
}

/// The editor's draft: days, times, how it repeats and what's wrong with it.
struct CalendarEventDraftTests {
    @Test func keepsTheLengthWhenTheStartMoves() {
        var draft = CalendarEventDraft.new(on: d("2026-11-03"))
        draft.input.title = "Trip"
        #expect(draft.input.endDate == d("2026-11-03") && draft.isAllDay)
        draft.setEnd(d("2026-11-05"))
        draft.setStart(d("2026-11-10"))
        #expect(draft.input.date == d("2026-11-10") && draft.endDay == d("2026-11-12"))
        #expect(draft.problem == nil)
    }

    @Test func findsTheProblems() {
        var draft = CalendarEventDraft.new(on: d("2026-11-03"))
        #expect(draft.problem == "Give it a title.")
        draft.input.title = "Camp"
        draft.setEnd(d("2026-11-02"))
        #expect(draft.problem == "The end must be after the start.")
        draft.setEnd(d("2026-11-03"))
        draft.setAllDay(false)
        #expect(draft.input.start == "09:00" && draft.input.end == nil)
        draft.input.end = "08:00"
        #expect(draft.problem == "The end must be after the start.")
        // Over two days an earlier time on the last day is fine.
        draft.setEnd(d("2026-11-04"))
        #expect(draft.problem == nil)
        draft.setRepeat(.weekly)
        draft.setRepeatEnd(.until(d("2026-11-01")))
        #expect(draft.problem == "The repeat must end after the event starts.")
        draft.setRepeatEnd(.until(d("2026-12-01")))
        #expect(draft.problem == nil)
        draft.input.url = "example.com"
        #expect(draft.problem == "The link must start with http:// or https://.")
    }

    @Test func turningTheEndTimeOffMakesItOneDay() {
        var draft = CalendarEventDraft.new(on: d("2026-11-03"))
        draft.setAllDay(false)
        draft.setHasEnd(true)
        #expect(draft.input.end == "10:00")
        draft.setEnd(d("2026-11-05"))
        draft.setHasEnd(false)
        #expect(draft.input.end == nil && draft.endDay == d("2026-11-03"))
    }

    @Test func choosesHowItRepeats() {
        var draft = CalendarEventDraft.new(on: d("2026-11-03"))
        #expect(draft.repeatChoice == .never && draft.rule == nil)
        draft.setRepeat(.biweekly)
        #expect(draft.input.rrule == "FREQ=WEEKLY;INTERVAL=2")
        draft.setRepeatEnd(.count(5))
        #expect(draft.input.rrule == "FREQ=WEEKLY;INTERVAL=2;COUNT=5")
        // Another preset keeps the end.
        draft.setRepeat(.monthly)
        #expect(draft.input.rrule == "FREQ=MONTHLY;COUNT=5" && draft.repeatChoice == .monthly)
        draft.setRepeat(.never)
        #expect(draft.input.rrule == nil)
        draft.setRepeat(.custom)
        #expect(draft.input.rrule == "FREQ=WEEKLY")
    }

    @Test func editsAnOccurrenceAndKeepsARuleFromElsewhere() {
        let event = CalendarEvent(id: "s1", occurrence: d("2026-11-30"), date: d("2026-11-30"), start: "18:00", end: "19:00",
                                  title: "Team dinner", rrule: "freq=monthly;byday=mo,tu,we,th,fr;bysetpos=-1")
        var draft = CalendarEventDraft(event)
        #expect(draft.isOccurrence && !draft.ruleChanged)
        #expect(draft.input.rrule == "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1")
        #expect(draft.repeatChoice == .custom && draft.rule?.isEditable == false)
        draft.input.title = "Team lunch"
        #expect(!draft.ruleChanged)
        draft.setRepeat(.monthly)
        #expect(draft.ruleChanged)
        // A single event isn't an occurrence.
        #expect(!CalendarEventDraft(CalendarEvent(id: "e1", date: d("2026-11-30"), start: nil, end: nil, title: "x")).isOccurrence)
    }
}

/// The requests of this / future / all changes and deletions.
struct CalendarEventRequestTests {
    private let series = CalendarEvent(id: "s1", occurrence: d("2026-11-10"), date: d("2026-11-10"), start: "16:00",
                                       end: "17:00", title: "Swimming", rrule: "FREQ=WEEKLY;COUNT=10")

    private func body(_ request: CalendarEventRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func picksTheScope() {
        #expect(CalendarEventScope(series, span: .this, seriesStart: d("2026-11-03")) == .this(d("2026-11-10")))
        #expect(CalendarEventScope(series, span: .future, seriesStart: d("2026-11-03")) == .future(d("2026-11-10")))
        // From the first occurrence on: all of them.
        #expect(CalendarEventScope(series, span: .future, seriesStart: d("2026-11-10")) == .all)
        #expect(CalendarEventScope(series, span: nil, seriesStart: nil) == .all)
        let single = CalendarEvent(id: "e1", date: d("2026-11-10"), start: nil, end: nil, title: "Trip")
        #expect(CalendarEventScope(single, span: .this, seriesStart: nil) == .all)
        #expect(CalendarEventScope(nil, span: nil, seriesStart: nil) == .all)
    }

    @Test func savesAllThisOrFuture() throws {
        var input = CalendarEventInput(series)
        input.start = "16:30"

        let all = CalendarEventRequest.save(input, id: "s1", scope: .all)
        #expect(all.method == .patch && all.path == "/events/s1" && all.query.isEmpty)
        #expect(try body(all)["rrule"] as? String == "FREQ=WEEKLY;COUNT=10")
        #expect(try body(all)["endDate"] as? String == "2026-11-10")

        let this = CalendarEventRequest.save(input, id: "s1", scope: .this(d("2026-11-10")))
        #expect(this.query == ["occurrence": "2026-11-10", "span": "this"])
        #expect(try body(this)["rrule"] == nil && body(this)["start"] as? String == "16:30")

        // The rule unchanged: left out, so the new series keeps what's left of the count.
        let future = CalendarEventRequest.save(input, id: "s1", scope: .future(d("2026-11-10")), keepRule: true)
        #expect(future.query == ["occurrence": "2026-11-10", "span": "future"])
        #expect(try body(future)["rrule"] == nil)
        // It stops repeating from here on: null.
        input.rrule = nil
        let stop = CalendarEventRequest.save(input, id: "s1", scope: .future(d("2026-11-10")), keepRule: false)
        #expect(try body(stop).keys.contains("rrule") && body(stop)["rrule"] is NSNull)

        let create = CalendarEventRequest.create(input)
        #expect(create.method == .post && create.path == "/events" && create.query.isEmpty)
    }

    @Test func movesTheRulesWeekdaysWithTheSeries() {
        let weekly = CalendarEvent(id: "s1", occurrence: d("2026-11-02"), date: d("2026-11-02"), start: nil, end: nil,
                                   title: "Gym", rrule: "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10")
        var input = CalendarEventInput(weekly)
        input.date = d("2026-11-03")
        input.endDate = d("2026-11-03")
        // All of them a day later: Tuesday and Thursday now, sent.
        let all = CalendarEventRequest.moved(input, from: weekly, scope: .all)
        #expect(all.input.rrule == "FREQ=WEEKLY;BYDAY=TU,TH;COUNT=10" && !all.keepRule)
        // One occurrence alone keeps the rule; so does a move by whole weeks.
        #expect(CalendarEventRequest.moved(input, from: weekly, scope: .this(d("2026-11-02"))).input.rrule == weekly.rrule)
        input.date = d("2026-11-09")
        #expect(CalendarEventRequest.moved(input, from: weekly, scope: .all).keepRule)
        // Sunday wraps to Monday; ordinals stay.
        #expect(RepeatRule("FREQ=MONTHLY;BYDAY=-1SU")?.shiftingWeekdays(by: 1).string == "FREQ=MONTHLY;BYDAY=-1MO")
        #expect(RepeatRule("FREQ=WEEKLY;BYDAY=SA,SU")?.shiftingWeekdays(by: -1).string == "FREQ=WEEKLY;BYDAY=FR,SA")
    }

    @Test func deletesAllThisOrFuture() {
        #expect(CalendarEventRequest.delete(id: "s1", scope: .all)
                == CalendarEventRequest(method: .delete, path: "/events/s1"))
        #expect(CalendarEventRequest.delete(id: "s1", scope: .this(d("2026-11-10"))).query
                == ["occurrence": "2026-11-10", "span": "this"])
        #expect(CalendarEventRequest.delete(id: "s1", scope: .future(d("2026-11-17"))).query
                == ["occurrence": "2026-11-17", "span": "future"])
    }

    @Test func movesOneOccurrenceOrAWholeEvent() throws {
        let one = CalendarEventRequest.move(id: "s1", occurrence: d("2026-11-10"), date: d("2026-11-11"), endDate: d("2026-11-11"))
        #expect(one.method == .patch && one.query == ["occurrence": "2026-11-10", "span": "this"])
        #expect(try body(one) as? [String: String] == ["date": "2026-11-11", "endDate": "2026-11-11"])
        let whole = CalendarEventRequest.move(id: "e1", occurrence: nil, date: d("2026-11-11"), endDate: d("2026-11-13"))
        #expect(whole.query.isEmpty && whole.path == "/events/e1")
    }

    @Test func putsASeriesBack() throws {
        let stored = CalendarEventSeries(id: "s1", date: d("2026-11-03"), start: "16:00", end: "17:00", title: "Swimming",
                                         source: "apple", externalId: "EK-1", rrule: "FREQ=WEEKLY",
                                         exdates: [d("2026-11-17")],
                                         overrides: [CalendarEventOverride(occurrence: d("2026-11-24"), date: d("2026-11-25"),
                                                                           endDate: d("2026-11-25"), start: "16:00", end: "17:00",
                                                                           title: "Swimming")])
        // Still there: PATCH with everything, its exdates and overrides replacing the ones it has now.
        let patch = CalendarEventRequest.restore(stored, id: "s1")
        #expect(patch.method == .patch && patch.path == "/events/s1")
        #expect(try body(patch)["exdates"] as? [String] == ["2026-11-17"])
        #expect(try body(patch)["externalId"] == nil)
        // Deleted: POSTed again with its rule, exdates and overrides (and its Apple Calendar link).
        let post = CalendarEventRequest.restore(stored, id: nil)
        #expect(post.method == .post && post.path == "/events")
        let json = try body(post)
        #expect(json["rrule"] as? String == "FREQ=WEEKLY" && json["externalId"] as? String == "EK-1")
        #expect((json["overrides"] as? [[String: Any]])?.first?["date"] as? String == "2026-11-25")
    }
}

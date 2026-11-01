import CoreGraphics
import Foundation
import Observation
import Testing
@testable import Ohana

private func d(_ s: String) -> Day { Day(s)! }

private func editableStore() -> CalendarStore {
    let client = APIClient(baseURL: URL(string: "https://ohana.invalid")!, token: nil)
    let store = CalendarStore(api: FamilyAPI(client: client, familyID: "f1"), year: 2026, readOnly: false)
    store.skipWeekends = false
    return store
}

struct CalendarFillTests {
    @Test func findsTheDaysTheHandleFills() {
        let source = CalendarMath.range(d("2026-03-02"), d("2026-03-04"))
        let forwards = CalendarMath.fillTargets(source: source, hover: d("2026-03-08"))
        #expect(forwards.days == CalendarMath.range(d("2026-03-05"), d("2026-03-08")))
        #expect(!forwards.backwards)
        let backwards = CalendarMath.fillTargets(source: source, hover: d("2026-02-27"))
        #expect(backwards.days == CalendarMath.range(d("2026-02-27"), d("2026-03-01")))
        #expect(backwards.backwards)
        // Over the selection itself: nothing.
        #expect(CalendarMath.fillTargets(source: source, hover: d("2026-03-03")).days.isEmpty)
        #expect(CalendarMath.isContiguous(source))
        #expect(!CalendarMath.isContiguous([d("2026-03-02"), d("2026-03-04")]))
        #expect(!CalendarMath.isContiguous([]))
    }

    @Test func repeatsThePatternForwardsAndBackwards() {
        let entries: CalendarEntries = [d("2026-03-02"): ["a"], d("2026-03-03"): ["b"]]
        let source = [d("2026-03-02"), d("2026-03-03")]
        let forwards = CalendarMath.fillChanges(entries, source: source,
                                                targets: CalendarMath.range(d("2026-03-04"), d("2026-03-06")), backwards: false)
        #expect(forwards == [d("2026-03-04"): ["a"], d("2026-03-05"): ["b"], d("2026-03-06"): ["a"]])
        // Backwards the pattern ends right before the source: …, a, b | a, b.
        let backwards = CalendarMath.fillChanges(entries, source: source,
                                                 targets: CalendarMath.range(d("2026-02-27"), d("2026-03-01")), backwards: true)
        #expect(backwards == [d("2026-02-27"): ["b"], d("2026-02-28"): ["a"], d("2026-03-01"): ["b"]])
        // An empty day in the source clears its repetitions.
        let gappy = CalendarMath.fillChanges([d("2026-03-02"): ["a"]], source: source,
                                             targets: [d("2026-03-04"), d("2026-03-05")], backwards: false)
        #expect(gappy == [d("2026-03-04"): ["a"], d("2026-03-05"): []])
        #expect(CalendarMath.alignedPattern([["a"], ["b"], ["c"]], count: 4, backwards: true) == [["c"], ["a"], ["b"]])
        #expect(CalendarMath.alignedPattern([["a"], ["b"], ["c"]], count: 3, backwards: true) == [["a"], ["b"], ["c"]])
    }

    @Test func previewsTheFillWhileDragging() {
        let s = editableStore()
        s.select(d("2026-03-02"), d("2026-03-03"))
        #expect(s.canRepeat)
        #expect(s.beginFill())
        s.dragFill(to: d("2026-03-10"))
        #expect(s.fill?.targets == CalendarMath.range(d("2026-03-04"), d("2026-03-10")))
        #expect(s.fill?.targetSet.contains(d("2026-03-07")) == true)
        // Skip weekends leaves out Saturday and Sunday.
        s.skipWeekends = true
        s.dragFill(to: d("2026-03-09"))
        #expect(s.fill?.targets == [d("2026-03-04"), d("2026-03-05"), d("2026-03-06"), d("2026-03-09")])
        s.skipWeekends = false
        s.dragFill(to: d("2026-02-26"))
        #expect(s.fill?.backwards == true)
        #expect(s.fill?.targets.first == d("2026-02-26"))
        #expect(CalendarText.fill(s.fill!) == "Fill 4 days")
        s.dragFill(to: d("2026-03-03"))
        #expect(CalendarText.fill(s.fill!) == "Drag past the selection to repeat it")
        #expect(s.cancelFill())
        #expect(s.fill == nil)
        #expect(!s.cancelFill())
        // Letting go without targets changes nothing.
        s.beginFill()
        s.endFill()
        #expect(s.fill == nil)
        #expect(!s.canUndo)
    }

    @Test func onlyRepeatsDaysThatFollowEachOther() {
        let s = editableStore()
        s.select(d("2026-03-02"))
        s.toggleDay(d("2026-03-05"))
        #expect(!s.canRepeat)
        #expect(!s.beginFill())
        let viewer = CalendarStore(api: s.api, year: 2026, readOnly: true)
        viewer.select(d("2026-03-02"))
        #expect(!viewer.canRepeat)
    }

    @Test func boundsTheRepeatSheet() {
        let source = [d("2026-03-02"), d("2026-03-03")]
        #expect(CalendarRepeatSheet.bounds(source: source, backwards: false, year: 2026) == d("2026-03-04")...d("2026-12-31"))
        #expect(CalendarRepeatSheet.bounds(source: source, backwards: true, year: 2026) == d("2026-01-01")...d("2026-03-01"))
        #expect(CalendarRepeatSheet.bounds(source: [d("2026-12-31")], backwards: false, year: 2026) == nil)
        #expect(CalendarRepeatSheet.bounds(source: [d("2026-01-01")], backwards: true, year: 2026) == nil)
    }
}

struct CalendarZoomTests {
    @Test func stepsLikeTheWeb() {
        #expect(CalendarZoom.step(31, 1) == 25)
        #expect(CalendarZoom.step(25, -1) == 31)
        #expect(CalendarZoom.step(8, 1) == 7)
        #expect(CalendarZoom.step(7, 1) == 7)
        #expect(CalendarZoom.step(31, -1) == 31)
        #expect(CalendarZoom.step(12, 0) == 31)
        #expect(CalendarZoom.clamp(3) == 7)
        #expect(CalendarZoom.clamp(40) == 31)
    }

    @Test func pinchesAndSlides() {
        #expect(CalendarZoom.pinched(from: 31, magnification: 2) == 16)
        #expect(CalendarZoom.pinched(from: 16, magnification: 0.5) == 31)
        #expect(CalendarZoom.pinched(from: 10, magnification: 10) == 7)
        #expect(CalendarZoom.pinched(from: 10, magnification: 0) == 10)
        // Right = zoomed in.
        #expect(CalendarZoom.sliderValue(31) == 7)
        #expect(CalendarZoom.sliderValue(7) == 31)
        #expect(CalendarZoom.zoom(sliderValue: 20) == 18)
    }

    @Test func growsTheCellsWhenZoomedIn() {
        let all = CalendarYearGrid.metrics(width: 40 + 31 * 30, zoom: 31)
        #expect(all.cellWidth == 30)
        #expect(all.rowHeight == 28.5)
        let week = CalendarYearGrid.metrics(width: 40 + 31 * 30, zoom: 7)
        #expect(abs(week.cellWidth - 31 * 30 / 7) < 0.001)
        #expect(abs(week.rowHeight - 28.5 * 31 / 7) < 0.001)
    }

    @Test func picksTheListOfMonthsByWidth() {
        #expect(CalendarLayoutRule.monthList(width: 700, compact: false))
        #expect(CalendarLayoutRule.monthList(width: 1000, compact: false))
        #expect(!CalendarLayoutRule.monthList(width: 1026, compact: false))
        #expect(CalendarLayoutRule.monthList(width: 1200, compact: true))
        #expect(!CalendarLayoutRule.monthList(width: nil, compact: false))
    }
}

struct CalendarMonthListTests {
    @Test func findsDaysAcrossMonths() {
        // January and February 2026 (weeks from Monday), one under the other with a title between.
        let frames: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 350, height: 250),
                                     2: CGRect(x: 0, y: 300, width: 350, height: 250)]
        func day(_ x: CGFloat, _ y: CGFloat, clamp: Bool = false) -> Day? {
            CalendarGridLayout.day(at: CGPoint(x: x, y: y), inMonths: frames, year: 2026, firstWeekday: 2, clamp: clamp)
        }
        #expect(day(160, 10) == d("2026-01-01"))
        // 1 February 2026 is a Sunday: the last column of the first week.
        #expect(day(340, 310) == d("2026-02-01"))
        // Between the months only while dragging: the nearest month.
        #expect(day(10, 260) == nil)
        #expect(day(340, 260, clamp: true) == d("2026-01-31"))
        #expect(day(10, 290, clamp: true) == d("2026-02-01"))
        #expect(day(10, 2000, clamp: true) == d("2026-02-23"))
        #expect(day(340, 2000, clamp: true) == d("2026-02-28"))
        #expect(CalendarGridLayout.day(at: .zero, inMonths: [:], year: 2026, firstWeekday: 2, clamp: true) == nil)
    }

    @Test func findsDaysBetweenTheGapsOfTheMonthView() {
        // March 2026 in weeks from Sunday: 5 rows of 40 points with 3 points between them.
        let frames: [Int: CGRect] = [3: CGRect(x: 10, y: 100, width: 7 * 50 + 6 * 3, height: 5 * 40 + 4 * 3)]
        func day(_ x: CGFloat, _ y: CGFloat) -> Day? {
            CalendarGridLayout.day(at: CGPoint(x: x, y: y), inMonths: frames, year: 2026, firstWeekday: 1, spacing: 3)
        }
        // 1 March 2026 is a Sunday: the first cell.
        #expect(day(15, 105) == d("2026-03-01"))
        // The second row starts after the first one and its gap.
        #expect(day(15, 100 + 43 + 1) == d("2026-03-08"))
        // A point in the gap belongs to the day before it.
        #expect(day(10 + 51, 105) == d("2026-03-01"))
        #expect(day(10 + 54, 105) == d("2026-03-02"))
    }
}

struct CalendarMonthViewTests {
    @Test func laysOutTheWeeksFromTheLocalesFirstDay() {
        // February 2026 starts on a Sunday: no blank from Sunday, six from Monday.
        let sunday = CalendarGridLayout.Month(year: 2026, month: 2, firstWeekday: 1, width: 350, rowHeight: 40)
        #expect(sunday.weeks.count == 4)
        #expect(sunday.weeks[0] == [1, 2, 3, 4, 5, 6, 7])
        let monday = CalendarGridLayout.Month(year: 2026, month: 2, firstWeekday: 2, width: 350, rowHeight: 40)
        #expect(monday.weeks.count == 5)
        #expect(monday.weeks[0] == [nil, nil, nil, nil, nil, nil, 1])
        #expect(monday.weeks[4] == [23, 24, 25, 26, 27, 28, nil])
    }

    @Test func keepsTheWebsCellsWithGaps() {
        let layout = CalendarGridLayout.Month(year: 2026, month: 1, firstWeekday: 2, width: 7 * 50 + 6 * 3,
                                              rowHeight: 40, spacing: 3)
        #expect(layout.cellWidth == 50)
        #expect(layout.height == CGFloat(5 * 40 + 4 * 3))
        #expect(layout.frame(of: d("2026-01-05")) == CGRect(x: 0, y: 43, width: 50, height: 40))
        // Cells of 1 : 0.8, taller when the text needs it (Dynamic Type).
        #expect(CalendarGridLayout.Month.rowHeight(width: 7 * 50 + 6 * 3, spacing: 3, minimum: 30) == 40)
        #expect(CalendarGridLayout.Month.rowHeight(width: 7 * 50 + 6 * 3, spacing: 3, minimum: 84) == 84)
    }

    @Test func namesTheWeekdaysInTheLocalesOrder() {
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        #expect(CalendarText.inWeekOrder(symbols, firstWeekday: 1) == symbols)
        #expect(CalendarText.inWeekOrder(symbols, firstWeekday: 2) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        #expect(CalendarText.inWeekOrder(symbols, firstWeekday: 7).first == "Sat")
        #expect(CalendarText.weekdayNames.count == 7)
    }
}

struct CalendarAccessibilityTests {
    @Test func readsTheWholeDay() {
        let type = CalendarEntryType(id: "t1", year: 2026, name: "Vacation", color: "#3b82f6", role: .covers)
        let event = CalendarEvent(id: "e1", date: d("2026-03-10"), start: "09:30", end: nil, title: "Dentist")
        let text = CalendarDayCell.accessibilityText(day: d("2026-03-10"), types: [type],
                                                     note: CalendarNote(icon: "🎈", comment: "Party"), events: [event],
                                                     birthdays: [CalendarBirthday(name: "Mia", age: 7)], gap: true)
        #expect(text == CalendarText.longDay(d("2026-03-10")) + ", Vacation, 🎈 Party, 09:30 Dentist, 🎂 Mia turns 7, Not covered")
        #expect(CalendarDayCell.accessibilityText(day: d("2026-03-10"), types: [], note: nil, events: [], birthdays: [],
                                                  gap: false) == CalendarText.longDay(d("2026-03-10")))
    }

    @Test func announcesTheSelection() {
        #expect(CalendarText.selectionAnnouncement(0) == "No days selected")
        #expect(CalendarText.selectionAnnouncement(1) == "1 day selected")
        #expect(CalendarText.selectionAnnouncement(5) == "5 days selected")
    }
}

/// The grids hand each cell its values, and the store changes only what really changed: a
/// cell redraws when its own day changes, not on every change anywhere in the year.
struct CalendarCellTests {
    private func state() -> CalendarState {
        let family = CalendarFamilyInfo(id: "f1", feedId: "feed", legacyId: nil, name: "Family", access: "editor",
                                        readOnly: false, updatedAt: nil)
        return CalendarState(
            family: family,
            types: [CalendarEntryType(id: "kita", year: 2026, name: "Kita", color: "#f59e0b", role: .needsCover),
                    CalendarEntryType(id: "vac", year: 2026, name: "Vacation", color: "#3b82f6", role: .covers)],
            typeYears: [2026],
            entries: ["2026-03-02": ["kita"], "2026-03-03": ["kita", "vac"]],
            notes: ["2026-03-02": CalendarNote(icon: "🎈", comment: "")],
            events: nil, birthdays: nil
        )
    }

    @Test func givesEachDayItsValues() {
        let s = editableStore()
        s.apply(state())
        s.select(d("2026-03-02"), d("2026-03-03"))
        let context = s.cellContext(gridFocused: true)
        // Both selected days have Kita, only one Vacation.
        #expect(context.selectionTypes == ["kita"])
        let monday = s.cell(d("2026-03-02"), context)
        #expect(monday.types.map(\.id) == ["kita"])
        #expect(monday.note?.icon == "🎈")
        #expect(monday.selected && monday.gap && !monday.focused)
        #expect(monday.onTypes == ["kita"])
        let tuesday = s.cell(d("2026-03-03"), context)
        #expect(tuesday.focused && !tuesday.gap)
        let other = s.cell(d("2026-03-04"), context)
        #expect(!other.selected && other.types.isEmpty && other.onTypes.isEmpty)
        // Without the keyboard focus no day shows the outline.
        #expect(!s.cell(d("2026-03-03"), s.cellContext(gridFocused: false)).focused)
        // A touch drag outlines the day under the finger, keyboard focus or not.
        s.dragging = true
        #expect(s.cell(d("2026-03-03"), s.cellContext(gridFocused: false)).focused)
    }

    @Test func changesNothingForTheSameState() {
        let s = editableStore()
        s.apply(state())
        s.select(d("2026-03-02"))
        // onChange runs synchronously, in the change itself.
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = (s.entries, s.types, s.notes, s.events, s.selection, s.focus)
        } onChange: { changed = true }
        // A poll that brings the same calendar, a drag that stays on the same day.
        s.apply(state())
        s.setSelection([d("2026-03-02")], anchor: d("2026-03-02"), focus: d("2026-03-02"))
        #expect(!changed)
        s.select(d("2026-03-03"))
        #expect(changed)
    }
}

/// Answers the calendar's requests like the server would (a deleted event, one made again)
/// and records them; nothing leaves the test.
nonisolated final class CalendarStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []

    static var requests: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.log.append("\(method) \(path)") }
        var status = 200
        var body = Data("{}".utf8)
        if method == "POST" && path.hasSuffix("/events") {
            body = Data(#"{"id":"e2","date":"2026-03-10","start":"09:30","end":null,"title":"Dentist"}"#.utf8)
        } else if method == "GET" {
            status = 503
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct CalendarEventUndoTests {
    private func store() -> CalendarStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarStubProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://x.example")!, token: nil, session: URLSession(configuration: config))
        return CalendarStore(api: FamilyAPI(client: client, familyID: "f1"), year: 2026, readOnly: false)
    }

    private func waitFor(_ request: String, times: Int = 1) async -> Bool {
        for _ in 0..<200 {
            if CalendarStubProtocol.requests.filter({ $0 == request }).count >= times { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func undoBringsADeletedEventBackAndRedoDeletesItAgain() async throws {
        CalendarStubProtocol.reset()
        let store = store()
        let event = CalendarEvent(id: "e1", date: d("2026-03-10"), start: "09:30", end: nil, title: "Dentist")
        try await store.deleteEvent(event)
        #expect(CalendarStubProtocol.requests.contains("DELETE /api/v1/families/f1/events/e1"))
        #expect(store.canUndo)
        #expect(store.toast == "Deleted “Dentist”")
        #expect(store.toastOffersUndo)

        store.undo()
        #expect(await waitFor("POST /api/v1/families/f1/events"))
        #expect(store.canRedo)
        // Made again with a new id (then reloaded), which redo deletes.
        #expect(await waitFor("GET /api/v1/families/f1", times: 2))
        store.redo()
        #expect(await waitFor("DELETE /api/v1/families/f1/events/e2"))
    }

    @Test func movesAnEventAndUndoMovesItBack() async throws {
        CalendarStubProtocol.reset()
        let store = store()
        store.apply(calendarWithEvent())
        let event = try #require(store.events[d("2026-03-10")]?.first)
        let patch = "PATCH /api/v1/families/f1/events/e1"

        // Moved here at once, then saved; a booked appointment stays one.
        store.moveEvent(event, to: d("2026-03-12"))
        #expect(store.events[d("2026-03-10")] == nil)
        #expect(store.events[d("2026-03-12")]?.map(\.id) == ["e0", "e1", "e3"])
        #expect(store.events[d("2026-03-12")]?[1].isAppointment == true)
        #expect(store.toast == "Moved “Dentist” to \(CalendarText.day(d("2026-03-12")))")
        #expect(store.toastOffersUndo && store.canUndo)
        #expect(await waitFor(patch))

        store.undo()
        #expect(store.events[d("2026-03-12")]?.map(\.id) == ["e0", "e3"])
        #expect(store.events[d("2026-03-10")]?.map(\.id) == ["e1"])
        #expect(store.canRedo)
        #expect(await waitFor(patch, times: 2))

        store.redo()
        #expect(store.events[d("2026-03-12")]?.map(\.id) == ["e0", "e1", "e3"])
        #expect(await waitFor(patch, times: 3))
    }
}

/// A calendar with a booked appointment on 10 March 2026.
private func calendarWithEvent(readOnly: Bool = false) -> CalendarState {
    CalendarState(
        family: CalendarFamilyInfo(id: "f1", feedId: "feed", legacyId: nil, name: "Family", access: "editor",
                                   readOnly: readOnly, updatedAt: nil),
        types: [], typeYears: [2026], entries: [:], notes: nil,
        events: ["2026-03-10": [CalendarEvent(id: "e1", date: d("2026-03-10"), start: "09:30", end: nil, title: "Dentist",
                                              source: "appointment", searchId: "s1")],
                 "2026-03-12": [CalendarEvent(id: "e0", date: d("2026-03-12"), start: nil, end: nil, title: "Trip"),
                                CalendarEvent(id: "e3", date: d("2026-03-12"), start: "11:00", end: nil, title: "Call")]],
        birthdays: nil
    )
}

struct CalendarEventDragTests {
    @Test func dropsOnlyThisFamilysEventsOnOtherDays() {
        let s = editableStore()
        s.apply(calendarWithEvent())
        s.dropEvent(CalendarEventDragItem(familyID: "f2", eventID: "e1", date: "2026-03-10"), on: d("2026-03-11"))
        s.dropEvent(CalendarEventDragItem(familyID: "f1", eventID: "e1", date: "2026-03-10"), on: d("2026-03-10"))
        s.dropEvent(CalendarEventDragItem(familyID: "f1", eventID: "gone", date: "2026-03-10"), on: d("2026-03-11"))
        #expect(s.events[d("2026-03-10")]?.map(\.id) == ["e1"])
        #expect(!s.canUndo)
        // Among the day's events by start time, after the all-day ones.
        s.dropEvent(CalendarEventDragItem(familyID: "f1", eventID: "e1", date: "2026-03-10"), on: d("2026-03-12"))
        #expect(s.events[d("2026-03-12")]?.map(\.id) == ["e0", "e1", "e3"])
        #expect(s.events[d("2026-03-12")]?[1].date == d("2026-03-12"))
        #expect(s.canUndo)
        #expect(s.dragItem(s.events[d("2026-03-12")]![1]) ==
                CalendarEventDragItem(familyID: "f1", eventID: "e1", date: "2026-03-12"))
    }

    @Test func viewersCantMoveEvents() throws {
        let s = CalendarStore(api: editableStore().api, year: 2026, readOnly: true)
        s.apply(calendarWithEvent(readOnly: true))
        let event = try #require(s.events[d("2026-03-10")]?.first)
        s.moveEvent(event, to: d("2026-03-11"))
        #expect(s.events[d("2026-03-10")]?.map(\.id) == ["e1"])
        #expect(s.events[d("2026-03-11")] == nil)
        #expect(!s.canUndo && s.toast == nil)
        s.setDropTarget(d("2026-03-11"))
        #expect(s.dropTarget == nil)
    }

    @Test func showsWhereItWouldLand() {
        let s = editableStore()
        s.apply(calendarWithEvent())
        s.select(d("2026-03-11"))
        s.setDropTarget(d("2026-03-11"))
        let context = s.cellContext(gridFocused: false)
        #expect(s.cell(d("2026-03-11"), context).dropTarget)
        #expect(!s.cell(d("2026-03-12"), context).dropTarget)
        s.setDropTarget(nil)
        #expect(!s.cell(d("2026-03-11"), s.cellContext(gridFocused: false)).dropTarget)
    }

    @Test func findsTheEventUnderAPress() {
        let s = editableStore()
        s.eventLabels["e1@2026-03-10"] = (d("2026-03-10"), CGRect(x: 10, y: 40, width: 80, height: 14))
        #expect(s.isOnEvent(CGPoint(x: 20, y: 45), day: d("2026-03-10")))
        #expect(!s.isOnEvent(CGPoint(x: 20, y: 70), day: d("2026-03-10")))
        // A label that overflows into the next week's cell doesn't count there.
        #expect(!s.isOnEvent(CGPoint(x: 20, y: 45), day: d("2026-03-17")))
        #expect(!s.isOnEvent(CGPoint(x: 20, y: 45), day: nil))
    }

    @Test func sendsOnlyTheNewDate() throws {
        let body = try JSONEncoder().encode(CalendarEventDateBody(date: d("2026-03-12")))
        #expect(String(decoding: body, as: UTF8.self) == #"{"date":"2026-03-12"}"#)
    }
}

/// Answers the saved copy's and the queue's requests as set (GETs: 503 or `state`; POST /entries:
/// `entriesStatus`) and records them; nothing leaves the test.
nonisolated final class CalendarQueueStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var getBody: String?
    nonisolated(unsafe) private static var postStatus = 200

    static var requests: [String] { lock.withLock { log } }
    /// The GETs' answer; nil: 503 (the server down).
    static var state: String? {
        get { lock.withLock { getBody } }
        set { lock.withLock { getBody = newValue } }
    }
    static var entriesStatus: Int {
        get { lock.withLock { postStatus } }
        set { lock.withLock { postStatus = newValue } }
    }
    static func reset() { lock.withLock { log = []; getBody = nil; postStatus = 200 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        Self.lock.withLock { Self.log.append("\(method) \(path)") }
        var status = 200
        var body = "{}"
        if method == "GET" {
            if let state = Self.state { body = state } else { status = 503 }
        } else if path.hasSuffix("/entries") {
            status = Self.entriesStatus
            if status >= 400 { body = #"{"error":"Unknown type"}"# }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The copy on the device and the queue of changes kept there (offline editing; the server wins).
@Suite(.serialized)
struct CalendarSavedCopyTests {
    private static let json = #"""
    {"family":{"id":"f1","feedId":"Abc123Def456","name":"Krug","access":"edit","readOnly":false},
     "types":[{"id":"sick","year":2026,"name":"Sick","color":"#ef4444","role":"none","position":0}],
     "entries":{"2026-03-02":["sick"]}}
    """#

    private var state: CalendarState { try! JSONDecoder().decode(CalendarState.self, from: Data(Self.json.utf8)) }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ohana-calendar-\(UUID().uuidString)")
    }

    private func client(cache: ResponseCache? = nil) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarQueueStubProtocol.self]
        return APIClient(baseURL: URL(string: "https://x.example")!, token: nil,
                         session: URLSession(configuration: config), cache: cache)
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func showsTheCopyOnTheDeviceWhileTheServerIsDownAndQueuesChanges() async throws {
        CalendarQueueStubProtocol.reset()
        CalendarQueueStubProtocol.entriesStatus = 503
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory.appending(path: "responses"))
        let queueFile = directory.appending(path: "queue/queue.json")
        let store = CalendarStore(api: FamilyAPI(client: client(cache: cache), familyID: "f1"), year: 2026,
                                  readOnly: false, queueFile: queueFile)
        let key = store.api.cached("", query: ["year": "2026"], as: CalendarState.self).key
        cache.write(Data(Self.json.utf8), for: key)
        ResponseCache.waitForWrites()

        // GETs answer 503: the copy stays, without an error, and can be changed.
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.types(on: d("2026-03-02")).map(\.id) == ["sick"])
        #expect(store.savedCopy?.updating == false)
        #expect(!store.readOnly && !store.isViewer)
        // Types are changed on the server at once: not on the copy.
        #expect(store.typesReadOnly)
        store.select(d("2026-03-03"))
        store.toggleOnSelection("sick")
        #expect(store.entries[d("2026-03-03")] == ["sick"])
        #expect(FileManager.default.fileExists(atPath: queueFile.path()))
        #expect(await until { store.sync == .retrying })

        // The server's answer replaces the copy; what's still queued shows on top of it.
        store.apply(state)
        #expect(store.savedCopy == nil)
        #expect(!store.typesReadOnly)
        #expect(store.entries[d("2026-03-03")] == ["sick"])
        CalendarQueueStubProtocol.entriesStatus = 200
        store.retryNow()
        #expect(await until { !store.pending })
        #expect(!FileManager.default.fileExists(atPath: queueFile.path()))
    }

    @Test func readsTheQueueBackAndSendsItWhenTheServerAnswers() async throws {
        CalendarQueueStubProtocol.reset()
        CalendarQueueStubProtocol.entriesStatus = 503
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueFile = directory.appending(path: "queue.json")
        let api = FamilyAPI(client: client(), familyID: "f1")
        let first = CalendarStore(api: api, year: 2026, readOnly: false, queueFile: queueFile)
        first.skipWeekends = false
        first.apply(state)
        first.select(d("2026-03-02"))
        first.toggleOnSelection("sick")
        first.setNote(CalendarNote(icon: "🎈", comment: "Party"), on: [d("2026-03-04")])
        #expect(first.entries[d("2026-03-02")] == nil)
        #expect(FileManager.default.fileExists(atPath: queueFile.path()))

        // The app quit and starts again: the changes show on top of the loaded state.
        let second = CalendarStore(api: api, year: 2026, readOnly: false, queueFile: queueFile)
        second.apply(state)
        #expect(second.entries[d("2026-03-02")] == nil)
        #expect(second.notes[d("2026-03-04")] == CalendarNote(icon: "🎈", comment: "Party"))
        #expect(second.pending)

        // The server answers again: what was queued is sent and the file removed; the server's
        // state is then the truth.
        CalendarQueueStubProtocol.entriesStatus = 200
        CalendarQueueStubProtocol.state = Self.json
        second.retryNow()
        #expect(await until { !second.pending })
        #expect(!FileManager.default.fileExists(atPath: queueFile.path()))
        #expect(CalendarQueueStubProtocol.requests.contains("POST /api/v1/families/f1/entries"))
        #expect(CalendarQueueStubProtocol.requests.contains("POST /api/v1/families/f1/notes"))
        first.retryNow()
        #expect(await until { !first.pending })
    }

    @Test func aLoadWhileChangesWaitShowsThemOnTop() async throws {
        CalendarQueueStubProtocol.reset()
        CalendarQueueStubProtocol.entriesStatus = 503
        CalendarQueueStubProtocol.state = Self.json
        let store = CalendarStore(api: FamilyAPI(client: client(), familyID: "f1"), year: 2026, readOnly: false)
        store.skipWeekends = false
        store.apply(state)
        store.select(d("2026-03-05"))
        store.toggleOnSelection("sick")
        #expect(await until { store.sync == .retrying })
        await store.load()
        #expect(store.entries[d("2026-03-02")] == ["sick"])
        #expect(store.entries[d("2026-03-05")] == ["sick"])
        CalendarQueueStubProtocol.entriesStatus = 200
        store.retryNow()
        #expect(await until { !store.pending })
    }

    @Test func aRefusalDropsTheBatchAlsoFromTheDevice() async throws {
        CalendarQueueStubProtocol.reset()
        CalendarQueueStubProtocol.entriesStatus = 400
        CalendarQueueStubProtocol.state = Self.json
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queueFile = directory.appending(path: "queue.json")
        let store = CalendarStore(api: FamilyAPI(client: client(), familyID: "f1"), year: 2026,
                                  readOnly: false, queueFile: queueFile)
        store.skipWeekends = false
        store.apply(state)
        store.select(d("2026-03-06"))
        store.toggleOnSelection("sick")
        #expect(store.entries[d("2026-03-06")] == ["sick"])
        // The server wins: the change is dropped, the file removed, the server's state loaded.
        #expect(await until { !store.pending && store.entries[d("2026-03-06")] == nil })
        #expect(!FileManager.default.fileExists(atPath: queueFile.path()))
        #expect(CalendarQueueStubProtocol.requests.filter { $0 == "GET /api/v1/families/f1" }.count >= 1)
    }

    @Test func appliesOpsLikeTheServer() {
        var entries: CalendarEntries = [d("2026-03-02"): ["a"], d("2026-03-03"): ["a", "b"]]
        CalendarMath.apply([CalendarEntryOp(action: .add, type: "b", dates: [d("2026-03-02"), d("2027-01-01")]),
                            CalendarEntryOp(action: .remove, type: "a", dates: [d("2026-03-03")])],
                           to: &entries, year: 2026)
        // Days of another year are left to that year.
        #expect(entries == [d("2026-03-02"): ["a", "b"], d("2026-03-03"): ["b"]])
        CalendarMath.apply([CalendarEntryOp(action: .remove, type: "b", dates: [d("2026-03-03")])], to: &entries, year: 2026)
        #expect(entries[d("2026-03-03")] == nil)
        var notes: CalendarNotes = [d("2026-03-02"): CalendarNote(icon: "🎈", comment: "")]
        CalendarMath.apply([CalendarNoteOp(action: .clear, dates: [d("2026-03-02")]),
                            CalendarNoteOp(action: .set, dates: [d("2026-03-04")], icon: "", comment: "Trip")],
                           to: &notes, year: 2026)
        #expect(notes == [d("2026-03-04"): CalendarNote(icon: "", comment: "Trip")])
    }
}

struct CalendarRouteTests {
    @Test func showsADayOfTheYear() {
        let s = editableStore()
        s.select(d("2026-01-05"), d("2026-01-09"))
        s.show(d("2026-07-14"))
        #expect(s.year == 2026)
        #expect(s.selectedDays == [d("2026-07-14")])
        #expect(s.focus == d("2026-07-14"))
    }

    @Test func helpFitsTheDevice() {
        #expect(CalendarHelpSheet.sections(mac: true, compact: false) == [.pointer, .keyboard])
        #expect(CalendarHelpSheet.sections(mac: false, compact: true) == [.touch])
        #expect(CalendarHelpSheet.sections(mac: false, compact: false) == [.touch, .pointer, .keyboard])
        // An iPad's pointer: modifier clicks and the context menu, no click-and-drag (it scrolls).
        #expect(CalendarHelpSheet.rows(.pointer, mac: false).count == 3)
        #expect(CalendarHelpSheet.rows(.pointer, mac: true).count == 8)
    }
}

struct CalendarPluralTests {
    @Test func countsInEnglish() {
        #expect(CalendarText.days(1) == "1 day")
        #expect(CalendarText.days(3) == "3 days")
        #expect(CalendarText.weekdays(1) == "1 weekday")
        #expect(CalendarText.workdays(2) == "2 workdays")
        #expect(CalendarText.usedOn(1, year: 2026) == "It is used on 1 day in 2026. This can’t be undone.")
        #expect(CalendarText.usedOn(4, year: 2026) == "It is used on 4 days in 2026. This can’t be undone.")
        let days = [d("2026-03-07")] // a Saturday
        #expect(CalendarText.selection(days).hasPrefix("1 day selected (0 weekdays): "))
    }
}

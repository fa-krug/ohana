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

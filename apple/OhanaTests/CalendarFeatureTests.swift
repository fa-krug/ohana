import CoreGraphics
import Foundation
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
        #expect(!CalendarLayoutRule.monthList(width: 880, compact: false))
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
            CalendarGridLayout.day(at: CGPoint(x: x, y: y), inMonths: frames, year: 2026, firstWeekday: 2,
                                   rowHeight: 50, clamp: clamp)
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
        #expect(CalendarGridLayout.day(at: .zero, inMonths: [:], year: 2026, firstWeekday: 2, rowHeight: 50, clamp: true) == nil)
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
        #expect(CalendarHelpSheet.sections(mac: false, compact: false) == [.touch, .keyboard])
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

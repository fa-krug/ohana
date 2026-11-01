import CoreGraphics
import Foundation
import Testing
@testable import Ohana

private func d(_ s: String) -> Day { Day(s)! }

private let types: [CalendarEntryType] = [
    CalendarEntryType(id: "holiday", year: 2026, name: "Holiday", color: "#f59e0b", role: .dayOff, position: 0, away: false),
    CalendarEntryType(id: "vacation", year: 2026, name: "Vacation", color: "#22c55e", role: .covers, position: 1, away: true),
    CalendarEntryType(id: "kita", year: 2026, name: "Kita closed", color: "#ef4444", role: .needsCover, position: 2, away: nil),
]

struct CalendarMathTests {
    @Test func countsDaysLikeTheServer() {
        #expect(CalendarMath.weekday(d("2026-01-01")) == 4) // Thursday
        #expect(CalendarMath.weekday(d("1970-01-01")) == 4)
        #expect(CalendarMath.weekday(d("2026-10-31")) == 6)
        #expect(CalendarMath.isWeekend(d("2026-11-01")))
        #expect(!CalendarMath.isWeekend(d("2026-11-02")))
        #expect(CalendarMath.add(d("2028-02-28"), 1) == d("2028-02-29"))
        #expect(CalendarMath.add(d("2026-12-31"), 1) == d("2027-01-01"))
        #expect(CalendarMath.add(d("2026-03-01"), -1) == d("2026-02-28"))
        for s in ["1900-03-01", "2000-02-29", "2026-07-15", "2199-12-31"] {
            #expect(CalendarMath.day(ordinal: CalendarMath.ordinal(d(s))) == d(s))
        }
        #expect(CalendarMath.daysInMonth(year: 2100, month: 2) == 28)
        #expect(CalendarMath.daysInMonth(year: 2000, month: 2) == 29)
        #expect(!CalendarMath.isValid(year: 2026, month: 2, day: 29))
    }

    @Test func buildsInclusiveRangesInEitherOrder() {
        #expect(CalendarMath.range(d("2026-01-30"), d("2026-02-02")).map(\.description)
                == ["2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02"])
        #expect(CalendarMath.range(d("2026-02-02"), d("2026-01-31")).count == 3)
        #expect(CalendarMath.runs([d("2026-01-01"), d("2026-01-02"), d("2026-01-05")]).map(\.count) == [2, 1])
    }

    @Test func placesTheFirstOfTheMonth() {
        // 1 Jan 2026 is a Thursday: 3 blanks in a week from Monday, 4 from Sunday.
        #expect(CalendarMath.leadingBlanks(year: 2026, month: 1, firstWeekday: 2) == 3)
        #expect(CalendarMath.leadingBlanks(year: 2026, month: 1, firstWeekday: 1) == 4)
        // 1 Feb 2026 is a Sunday.
        #expect(CalendarMath.leadingBlanks(year: 2026, month: 2, firstWeekday: 2) == 6)
    }

    @Test func countsWorkdaysPerType() {
        let entries: CalendarEntries = [
            d("2026-01-01"): ["holiday", "vacation"], // Thursday, a holiday: the vacation day is not used up
            d("2026-01-02"): ["vacation"], // Friday
            d("2026-01-03"): ["vacation"], // Saturday
            d("2025-12-31"): ["vacation"], // another year
        ]
        let stats = CalendarMath.stats(entries, types: types, year: 2026)
        #expect(stats["vacation"] == CalendarTypeStats(days: 3, workdays: 1))
        #expect(stats["holiday"] == CalendarTypeStats(days: 1, workdays: 1))
        #expect(stats["kita"] == CalendarTypeStats())
    }

    @Test func findsCoverageGaps() {
        let roles = CalendarMath.roles(types)
        #expect(CalendarMath.isGap(d("2026-01-05"), ["kita"], roles: roles))
        #expect(!CalendarMath.isGap(d("2026-01-05"), ["kita", "vacation"], roles: roles))
        #expect(!CalendarMath.isGap(d("2026-01-05"), ["kita", "holiday"], roles: roles))
        #expect(!CalendarMath.isGap(d("2026-01-03"), ["kita"], roles: roles)) // Saturday
        let entries: CalendarEntries = [d("2026-01-06"): ["kita"], d("2026-01-05"): ["kita"], d("2026-01-07"): ["kita", "vacation"]]
        #expect(CalendarMath.gapDays(entries, types: types, year: 2026) == [d("2026-01-05"), d("2026-01-06")])
    }

    @Test func togglesATypeOnTheSelection() {
        let entries: CalendarEntries = [d("2026-01-05"): ["vacation"], d("2026-01-06"): []]
        let days = [d("2026-01-05"), d("2026-01-06")]
        let added = CalendarMath.toggleType(entries, days: days, typeID: "vacation")
        #expect(added == [d("2026-01-05"): ["vacation"], d("2026-01-06"): ["vacation"]])
        let removed = CalendarMath.toggleType(added, days: days, typeID: "vacation")
        #expect(removed == [d("2026-01-05"): [], d("2026-01-06"): []])
    }

    @Test func turnsChangesIntoOps() {
        let entries: CalendarEntries = [d("2026-01-05"): ["vacation", "kita"], d("2026-01-06"): ["kita"]]
        let next: CalendarEntries = [d("2026-01-05"): ["kita"], d("2026-01-06"): ["kita"], d("2026-01-07"): ["holiday"]]
        let changes = CalendarMath.changedOnly(entries, next)
        #expect(Set(changes.keys) == [d("2026-01-05"), d("2026-01-07")])
        let ops = CalendarMath.ops(entries, changes)
        #expect(ops == [
            CalendarEntryOp(action: .remove, type: "vacation", dates: [d("2026-01-05")]),
            CalendarEntryOp(action: .add, type: "holiday", dates: [d("2026-01-07")]),
        ])
        var applied = entries
        CalendarMath.apply(CalendarMath.clearDays([d("2026-01-06")]), to: &applied)
        #expect(applied[d("2026-01-06")] == nil)
    }

    @Test func turnsNoteChangesIntoOps() {
        let xmas = CalendarNote(icon: "🎄", comment: "")
        let notes: CalendarNotes = [d("2026-12-24"): xmas, d("2026-12-31"): CalendarNote(icon: "🎆", comment: "")]
        let next: [Day: CalendarNote?] = [
            d("2026-12-24"): xmas, // unchanged
            d("2026-12-25"): xmas,
            d("2026-12-26"): xmas,
            d("2026-12-31"): nil,
            d("2026-12-30"): CalendarNote(icon: "", comment: ""), // empty: nothing to remove
        ]
        let changes = CalendarMath.changedNotes(notes, next)
        #expect(Set(changes.keys) == [d("2026-12-25"), d("2026-12-26"), d("2026-12-31")])
        let ops = CalendarMath.noteOps(changes)
        #expect(ops == [
            CalendarNoteOp(action: .clear, dates: [d("2026-12-31")]),
            CalendarNoteOp(action: .set, dates: [d("2026-12-25"), d("2026-12-26")], icon: "🎄", comment: ""),
        ])
    }

    @Test func pastesPatterns() {
        let pattern: CalendarPattern = [["vacation"], []]
        // One selected day takes the whole pattern, skipping the weekend if asked.
        #expect(CalendarMath.pasteTargets([d("2026-01-09")], patternLength: 2, last: d("2026-12-31"), skipWeekends: true)
                == [d("2026-01-09"), d("2026-01-12")])
        #expect(CalendarMath.pasteTargets([d("2026-12-31")], patternLength: 2, last: d("2026-12-31"), skipWeekends: false)
                == [d("2026-12-31")])
        let filled = CalendarMath.fill([d("2026-01-05"), d("2026-01-06"), d("2026-01-07")], with: pattern)
        #expect(filled[d("2026-01-07")] == ["vacation"])
        #expect(filled[d("2026-01-06")] == [])

        let text = CalendarMath.clipboardText(days: [d("2026-01-05"), d("2026-01-06")],
                                              pattern: [["vacation", "kita"], []], types: types)
        #expect(text == "2026-01-05\tVacation, Kita closed\n2026-01-06\t")
        let parsed = CalendarMath.parseClipboard(text + "\n", types: types)
        #expect(parsed.pattern == [["vacation", "kita"], []])
        #expect(parsed.unknown.isEmpty)
        let column = CalendarMath.parseClipboard("vacation\nHoliday; Sick\r\n", types: types)
        #expect(column.pattern == [["vacation"], ["holiday"]])
        #expect(column.unknown == ["Sick"])
    }

    @Test func picksColors() {
        #expect(CalendarMath.nextColor(types) == "#3b82f6")
        #expect(CalendarMath.prefersDarkText(on: "#f59e0b"))
        #expect(!CalendarMath.prefersDarkText(on: "#3b82f6"))
        #expect(CalendarMath.hex(r: 1, g: 0.5, b: 0) == "#ff8000")
        let rgb = CalendarMath.rgb("#22c55e")
        #expect(rgb?.g == 197.0 / 255.0)
        #expect(CalendarMath.rgb("nope") == nil)
    }
}

struct CalendarGridLayoutTests {
    @Test func hitsDaysInTheYearGrid() {
        let layout = CalendarGridLayout.Year(width: 40 + 31 * 20, labelWidth: 40, headerHeight: 22, rowHeight: 30)
        #expect(layout.day(at: CGPoint(x: 45, y: 25), year: 2026) == d("2026-01-01"))
        #expect(layout.day(at: CGPoint(x: 40 + 20 * 30 + 1, y: 22 + 30 * 11 + 1), year: 2026) == d("2026-12-31"))
        // 30 February doesn't exist; dragging over it clamps to the month's last day.
        #expect(layout.day(at: CGPoint(x: 40 + 20 * 29 + 5, y: 22 + 30 + 5), year: 2026) == nil)
        #expect(layout.day(at: CGPoint(x: 40 + 20 * 29 + 5, y: 22 + 30 + 5), year: 2026, clamp: true) == d("2026-02-28"))
        #expect(layout.day(at: CGPoint(x: 10, y: 10), year: 2026) == nil)
        #expect(layout.day(at: CGPoint(x: -50, y: 1000), year: 2026, clamp: true) == d("2026-12-01"))
        #expect(layout.frame(of: d("2026-03-02")) == CGRect(x: 60, y: 82, width: 20, height: 30))
    }

    @Test func hitsDaysInAMonth() {
        // January 2026, weeks from Monday: Thursday the 1st is in column 3.
        let layout = CalendarGridLayout.Month(year: 2026, month: 1, firstWeekday: 2, width: 350, rowHeight: 50)
        #expect(layout.rows == 5)
        #expect(layout.day(at: CGPoint(x: 160, y: 10)) == d("2026-01-01"))
        #expect(layout.day(at: CGPoint(x: 10, y: 10)) == nil)
        #expect(layout.day(at: CGPoint(x: 10, y: 10), clamp: true) == d("2026-01-01"))
        #expect(layout.day(at: CGPoint(x: 340, y: 240), clamp: true) == d("2026-01-31"))
        #expect(layout.day(at: CGPoint(x: 10, y: 60)) == d("2026-01-05"))
        #expect(layout.frame(of: d("2026-01-05")) == CGRect(x: 0, y: 50, width: 50, height: 50))
    }
}

struct CalendarStoreSelectionTests {
    private func store() -> CalendarStore {
        let client = APIClient(baseURL: URL(string: "https://ohana.invalid")!, token: nil)
        let store = CalendarStore(api: FamilyAPI(client: client, familyID: "f1"), year: 2026, readOnly: true)
        store.skipWeekends = false
        return store
    }

    @Test func selectsByTapShiftAndCommand() {
        let s = store()
        s.tap(d("2026-03-02"))
        #expect(s.selectedDays == [d("2026-03-02")])
        s.tap(d("2026-03-04"), extend: true)
        #expect(s.selectedDays == CalendarMath.range(d("2026-03-02"), d("2026-03-04")))
        s.tap(d("2026-03-10"), toggle: true)
        #expect(s.selection.count == 4)
        s.tap(d("2026-03-10"), toggle: true)
        #expect(s.selection.count == 3)
        s.tap(d("2026-05-01"))
        #expect(s.selectedDays == [d("2026-05-01")])
        // Tapping the only selected day again unselects it.
        s.tap(d("2026-05-01"))
        #expect(s.selection.isEmpty)
    }

    @Test func rangeAndMultiSelectModes() {
        let s = store()
        s.tap(d("2026-03-02"))
        s.rangeMode = true
        s.tap(d("2026-03-05"))
        #expect(s.selection.count == 4)
        #expect(!s.rangeMode)
        s.deselect()
        s.multiSelect = true
        s.tap(d("2026-03-02"))
        s.tap(d("2026-03-09"))
        #expect(s.selectedDays == [d("2026-03-02"), d("2026-03-09")])
        s.deselect()
        #expect(!s.multiSelect)
    }

    @Test func keepsTheSelectionInsideTheYear() {
        let s = store()
        s.select(d("2025-12-30"), d("2026-01-02"))
        #expect(s.selectedDays == [d("2026-01-01"), d("2026-01-02")])
        s.selectAll()
        #expect(s.selection.count == 365)
        s.select(d("2026-12-31"))
        #expect(s.moveFocus(1, extend: false) == nil)
        #expect(s.moveFocus(-31, extend: false) == d("2026-11-30"))
        #expect(s.moveFocus(2, extend: true) == d("2026-12-02"))
        #expect(s.selectedDays == CalendarMath.range(d("2026-11-30"), d("2026-12-02")))
    }

    @Test func skipsWeekendsInRanges() {
        let s = store()
        s.select(d("2026-01-02"), d("2026-01-05")) // Fri – Mon
        #expect(s.targetDays().count == 4)
        s.skipWeekends = true
        #expect(s.targetDays() == [d("2026-01-02"), d("2026-01-05")])
        s.select(d("2026-01-03"))
        #expect(s.targetDays() == [d("2026-01-03")]) // a single day stays
        s.skipWeekends = false
    }

    @Test func jumpsToTheNextGap() throws {
        let s = store()
        let json = """
        {"family":{"id":"f1","name":"Krug","access":"view","readOnly":true,"updatedAt":"2026-01-01T00:00:00.000Z"},
         "types":[{"id":"kita","year":2026,"name":"Kita closed","color":"#ef4444","role":"needs_cover","position":0,"away":false}],
         "typeYears":[2026],
         "entries":{"2026-01-05":["kita"],"2026-01-07":["kita"],"2026-01-10":["kita"]},
         "notes":{}, "events":{}, "birthdays":{}}
        """
        s.apply(try JSONDecoder().decode(CalendarState.self, from: Data(json.utf8)))
        #expect(s.gapDays == [d("2026-01-05"), d("2026-01-07")]) // the 10th is a Saturday
        #expect(s.nextGap() == d("2026-01-05"))
        #expect(s.nextGap() == d("2026-01-07"))
        #expect(s.nextGap() == d("2026-01-05"))
        #expect(s.readOnly)
    }
}

import Foundation
import Testing
@testable import Ohana

/// The imported public and school holidays: GET / PUT /holidays, the regions, their names on the
/// calendar's days (family-routes.ts familyState `holidays`) and the server's flag.
struct CalendarHolidaysTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesTheSettings() throws {
        let settings: CalendarHolidaySettings = try decode("""
        {"public":true,"school":false,"auto":true,"region":{"code":"DE-BY","name":"Bayern, Deutschland"},"status":"ok","syncedAt":"2026-11-04T08:00:00.000Z"}
        """)
        #expect(settings.publicHolidays && !settings.schoolHolidays && settings.auto && settings.isOn)
        #expect(settings.region == CalendarHolidayRegion(code: "DE-BY", name: "Bayern, Deutschland"))
        #expect(settings.status == .ok && settings.problem == nil)
        #expect(settings.syncedAt == "2026-11-04T08:00:00.000Z")

        let none: CalendarHolidaySettings = try decode("""
        {"public":false,"school":true,"auto":true,"region":null,"status":"no_address","syncedAt":null}
        """)
        #expect(none.region == nil && none.status == .noAddress && none.problem != nil)
        // A status the app doesn't know (a newer server) doesn't fail: nothing to tell.
        let newer: CalendarHolidaySettings = try decode(#"{"public":true,"school":true,"auto":false,"region":null,"status":"rate_limited"}"#)
        #expect(newer.status == .pending && newer.problem == nil && !newer.auto)
        // Off: no problem to tell, whatever the status.
        let off: CalendarHolidaySettings = try decode(#"{"public":false,"school":false,"auto":true,"region":null,"status":"failed"}"#)
        #expect(!off.isOn && off.problem == nil)
    }

    @Test func decodesTheRegions() throws {
        let countries: [CalendarHolidayRegion] = try decode(#"[{"code":"DE","name":"Germany"},{"code":"AT","name":"Austria"}]"#)
        #expect(CalendarHolidayRegion.sorted(countries).map(\.code) == ["AT", "DE"])
        #expect(countries[0].children == nil)
        let states: [CalendarHolidayRegion] = try decode("""
        [{"code":"DE-BY","name":"Bayern","children":[{"code":"DE-BY-AU","name":"Augsburg"}]},{"code":"DE-BE","name":"Berlin"}]
        """)
        #expect(states[0].children?.map(\.code) == ["DE-BY-AU"])
        #expect(states[0].contains("DE-BY-AU") && states[0].contains("DE-BY") && countries[0].contains("DE-BY-AU"))
        #expect(!states[1].contains("DE-BY") && !states[1].contains(nil))
    }

    @Test func encodesOnlyWhatChanges() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func text(_ value: CalendarHolidayUpdate) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        #expect(try text(CalendarHolidayUpdate(publicHolidays: true)) == #"{"public":true}"#)
        #expect(try text(CalendarHolidayUpdate(schoolHolidays: false)) == #"{"school":false}"#)
        #expect(try text(CalendarHolidayUpdate(region: .some("DE-BY"))) == #"{"region":"DE-BY"}"#)
        // Back to the home address's region: null, not left out.
        #expect(try text(CalendarHolidayUpdate(region: .some(nil))) == #"{"region":null}"#)
    }

    @Test func showsTheNamesOnTheirDays() throws {
        let json = """
        {"family":{"id":"f1","name":"Krug","access":"edit","readOnly":false,"updatedAt":null},
         "types":[{"id":"holiday","year":2026,"name":"Holiday","color":"#f59e0b","role":"day_off","position":0},
                  {"id":"school-holidays","year":2026,"name":"School holidays","color":"#ef4444","role":"needs_cover","position":1}],
         "entries":{"2026-10-03":["holiday"],"2026-11-02":["school-holidays"]},
         "holidays":{"2026-10-03":[{"name":"Tag der Deutschen Einheit","kind":"public"}],
                     "2026-11-02":[{"name":"Herbstferien","kind":"school"}]}}
        """
        let state: CalendarState = try decode(json)
        #expect(state.holidays?["2026-11-02"] == [CalendarHoliday(name: "Herbstferien", kind: "school")])

        let client = APIClient(baseURL: URL(string: "https://ohana.invalid")!, token: nil)
        let store = CalendarStore(api: FamilyAPI(client: client, familyID: "f1"), year: 2026, readOnly: false)
        store.apply(state)
        let day = Day("2026-10-03")!
        #expect(store.holidays[day]?.map(CalendarText.holiday) == ["Tag der Deutschen Einheit"])
        let cell = store.cell(day, store.cellContext(gridFocused: false))
        #expect(cell.holidays.map(\.name) == ["Tag der Deutschen Einheit"])
        let label = CalendarDayCell.accessibilityText(day: day, types: cell.types, note: nil, events: [],
                                                      holidays: cell.holidays, birthdays: [], gap: false)
        #expect(label.hasSuffix("Holiday, Tag der Deutschen Einheit"))
        let tooltip = CalendarDayCell.tooltip(day: day, types: cell.types, note: nil, events: [],
                                              holidays: cell.holidays, birthdays: [])
        #expect(tooltip.hasSuffix("\nHoliday\nTag der Deutschen Einheit"))

        // A server without them: none.
        store.apply(try decode("""
        {"family":{"id":"f1","name":"Krug","access":"edit","readOnly":false,"updatedAt":null},"types":[],"entries":{}}
        """))
        #expect(store.holidays.isEmpty)
    }

    @Test func theServerSaysWhetherItImportsThem() throws {
        let on: ServerInfo = try decode(#"{"name":"Ohana","version":"0.3.0","apiVersion":1,"modules":["calendar"],"holidays":true}"#)
        #expect(on.holidays)
        let older: ServerInfo = try decode(#"{"name":"Ohana","version":"0.2.0","apiVersion":1,"modules":["calendar"]}"#)
        #expect(!older.holidays && !ServerInfo.legacy.holidays)
        // Kept on the device with it.
        let round: ServerInfo = try JSONDecoder().decode(ServerInfo.self, from: try JSONEncoder().encode(on))
        #expect(round.holidays)
    }
}

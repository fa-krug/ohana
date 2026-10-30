import Foundation
import Testing
@testable import Ohana

/// The JSON of web/lib/calendar (family-routes.ts familyState, vacation.ts publicType,
/// events.ts publicEvent) as the server writes it.
struct CalendarDecodingTests {
    @Test func decodesTheFamilyState() throws {
        let json = """
        {
          "family": {"id":"f1","feedId":"Abc123Def456","legacyId":"old123456789","name":"Krug","access":"edit","readOnly":false,"updatedAt":"2026-10-01T08:00:00.000Z"},
          "session": {"id":"f1","feedId":"Abc123Def456","name":"Krug","access":"edit","readOnly":false,"updatedAt":"2026-10-01T08:00:00.000Z"},
          "types": [
            {"id":"holiday","year":2026,"name":"Holiday","color":"#f59e0b","role":"day_off","position":0,"away":false},
            {"id":"vacation","year":2026,"name":"Vacation","color":"#22c55e","role":"covers","position":1,"away":true},
            {"id":"kita","year":2026,"name":"Kita closed","color":"#ef4444","role":"needs_cover","position":2,"away":false}
          ],
          "typeYears": [2025, 2026],
          "entries": {"2026-01-01":["holiday"],"2026-08-03":["vacation","kita"]},
          "notes": {"2026-12-24":{"icon":"🎄","comment":"Christmas"}},
          "events": {"2026-11-03":[
            {"id":"e1","date":"2026-11-03","start":"10:30","end":"11:00","title":"Dr. Berg","location":"Hauptstr. 1","person":"Mia","note":"","url":"https://example.com","source":"appointment","searchId":"s1"},
            {"id":"e2","date":"2026-11-03","start":null,"end":null,"title":"Trip","location":"","person":"","note":"","url":"","source":"manual","searchId":null}
          ]},
          "birthdays": {"2026-05-04":[{"name":"Mia","age":8}]}
        }
        """
        let state = try JSONDecoder().decode(CalendarState.self, from: Data(json.utf8))
        #expect(state.family.feedId == "Abc123Def456")
        #expect(state.family.legacyId == "old123456789")
        #expect(state.types.map(\.role) == [.dayOff, .covers, .needsCover])
        #expect(state.types[1].isAway)
        #expect(state.typeYears == [2025, 2026])
        #expect(state.entries["2026-08-03"] == ["vacation", "kita"])
        #expect(state.notes?["2026-12-24"]?.text == "🎄 Christmas")
        let events = try #require(state.events?["2026-11-03"])
        #expect(events[0].date == Day("2026-11-03"))
        #expect(events[0].timeText == "10:30–11:00")
        #expect(events[0].line == "10:30 Dr. Berg (Mia)")
        #expect(events[0].isAppointment)
        #expect(events[1].start == nil && events[1].timeText == nil && events[1].searchId == nil)
        #expect(state.birthdays?["2026-05-04"]?.first == CalendarBirthday(name: "Mia", age: 8))

        let client = APIClient(baseURL: URL(string: "https://ohana.invalid")!, token: nil)
        let store = CalendarStore(api: FamilyAPI(client: client, familyID: "f1"), year: 2026, readOnly: false)
        store.apply(state)
        #expect(store.types.map(\.id) == ["holiday", "vacation", "kita"])
        #expect(store.types(on: Day("2026-08-03")!).map(\.id) == ["vacation", "kita"])
        #expect(store.events[Day("2026-11-03")!]?.count == 2)
        #expect(!store.readOnly)
    }

    @Test func decodesAViewersFamilyWithoutExtras() throws {
        // A viewer gets no legacyId; a family-planner script's response has no events or
        // birthdays; a type from family-planner's files has no away flag.
        let json = """
        {"family":{"id":"f1","feedId":"Abc123Def456","name":"Krug","access":"view","readOnly":true,"updatedAt":"2026-10-01 08:00:00"},
         "types":[{"id":"sick","year":2026,"name":"Sick","color":"#ef4444","role":"none","position":0}],
         "entries":{}}
        """
        let state = try JSONDecoder().decode(CalendarState.self, from: Data(json.utf8))
        #expect(state.family.legacyId == nil)
        #expect(state.family.readOnly)
        #expect(state.types[0].away == nil && !state.types[0].isAway)
        #expect(state.typeYears == nil && state.notes == nil && state.events == nil && state.birthdays == nil)
    }

    @Test func decodesTypesAndEventsAnswers() throws {
        let type = try JSONDecoder().decode(CalendarEntryType.self, from: Data(
            ##"{"id":"new-type-4","year":2027,"name":"New type 4","color":"#3b82f6","role":"none","position":3,"away":false}"##.utf8))
        #expect(type.year == 2027 && type.position == 3)
        let copied = try JSONDecoder().decode([CalendarEntryType].self, from: Data(
            ##"[{"id":"holiday","year":2027,"name":"Holiday","color":"#f59e0b","role":"day_off","position":0,"away":false}]"##.utf8))
        #expect(copied.count == 1)
        let event = try JSONDecoder().decode(CalendarEvent.self, from: Data(
            #"{"id":"e1","date":"2026-11-04","start":"10:30","end":null,"title":"Dr. Brandt","location":"","person":"","note":"","url":"","source":"manual","searchId":null}"#.utf8))
        #expect(event.end == nil && event.timeText == "10:30")
    }

    @Test func encodesRequestsLikeTheWebClient() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func text(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }

        #expect(try text(CalendarOpsBody(ops: [CalendarEntryOp(action: .add, type: "vacation", dates: [Day("2026-01-05")!])]))
                == #"{"ops":[{"action":"add","dates":["2026-01-05"],"type":"vacation"}]}"#)
        #expect(try text(CalendarOpsBody(ops: [CalendarNoteOp(action: .clear, dates: [Day("2026-12-31")!])]))
                == #"{"ops":[{"action":"clear","dates":["2026-12-31"]}]}"#)
        #expect(try text(CalendarTypePatch(away: true)) == #"{"away":true}"#)
        #expect(try text(CalendarTypePatch(name: "Sick", color: "#ef4444", role: CalendarRole.none))
                == ##"{"color":"#ef4444","name":"Sick","role":"none"}"##)

        // An all-day event clears start and end (PATCH merges what is sent).
        let allDay = CalendarEventInput(date: Day("2026-11-03")!, start: nil, end: "11:00", title: "Trip")
        #expect(try text(allDay)
                == #"{"date":"2026-11-03","end":null,"location":"","note":"","person":"","start":null,"title":"Trip","url":""}"#)
        let timed = CalendarEventInput(date: Day("2026-11-03")!, start: "10:30", end: "11:00", title: "Dr. Berg", person: "Mia")
        #expect(try text(timed).contains(#""end":"11:00""#))
    }

    @Test func buildsTheFeedURL() {
        let types: [CalendarEntryType] = [
            CalendarEntryType(id: "holiday", name: "Holiday", color: "#f59e0b", role: .dayOff),
            CalendarEntryType(id: "vacation", name: "Vacation", color: "#22c55e", role: .covers),
        ]
        let query = CalendarFeedSection.query(types: types, excluded: ["holiday"], gaps: false, notes: true,
                                              events: true, birthdays: true, language: "de")
        let client = APIClient(baseURL: URL(string: "https://ohana.example")!, token: nil)
        let url = client.url("/api/v1/families/feed1234567/calendar.ics", query: query)
        #expect(url.absoluteString
                == "https://ohana.example/api/v1/families/feed1234567/calendar.ics?birthdays=1&events=1&lang=de&notes=1&types=vacation")
        #expect(CalendarFeedSection.webcal(url)?.absoluteString.hasPrefix("webcal://ohana.example/api/v1/") == true)
        let plain = CalendarFeedSection.query(types: types, excluded: [], gaps: true, notes: false, events: false,
                                              birthdays: false, language: "en")
        #expect(plain == ["gaps": "1"])
    }

    @Test func checksEventDrafts() {
        var draft = CalendarEventDraft.new(on: Day("2026-11-03")!)
        #expect(draft.problem != nil)
        draft.input.title = "Dr. Berg"
        #expect(draft.problem == nil)
        draft.input.start = "11:00"
        draft.input.end = "10:00"
        #expect(draft.problem != nil)
        draft.input.end = "11:30"
        draft.input.url = "example.com"
        #expect(draft.problem != nil)
        draft.input.url = "https://example.com"
        #expect(draft.problem == nil)
        #expect(CalendarEventSheet.later("23:30") == "23:59")
        #expect(CalendarEventSheet.later("09:15") == "10:15")
    }
}

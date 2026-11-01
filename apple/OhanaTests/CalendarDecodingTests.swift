import Foundation
import Testing
@testable import Ohana

/// The JSON of server/lib/calendar (family-routes.ts familyState, vacation.ts publicType,
/// events.ts publicEvent) as the server writes it.
struct CalendarDecodingTests {
    @Test func decodesTheFamilyState() throws {
        let json = """
        {
          "family": {"id":"f1","name":"Krug","access":"edit","readOnly":false,"updatedAt":"2026-10-01T08:00:00.000Z"},
          "session": {"id":"f1","name":"Krug","access":"edit","readOnly":false,"updatedAt":"2026-10-01T08:00:00.000Z"},
          "types": [
            {"id":"holiday","year":2026,"name":"Holiday","color":"#f59e0b","role":"day_off","position":0,"away":false},
            {"id":"vacation","year":2026,"name":"Vacation","color":"#22c55e","role":"covers","position":1,"away":true},
            {"id":"kita","year":2026,"name":"Kita closed","color":"#ef4444","role":"needs_cover","position":2,"away":false}
          ],
          "typeYears": [2025, 2026],
          "entries": {"2026-01-01":["holiday"],"2026-08-03":["vacation","kita"]},
          "notes": {"2026-12-24":{"icon":"🎄","comment":"Christmas"}},
          "events": {"2026-11-03":[
            {"id":"e2","occurrence":null,"date":"2026-11-02","endDate":"2026-11-04","start":null,"end":null,"title":"Trip","location":"","person":"","note":"","url":"","source":"manual","searchId":null,"externalId":null,"rrule":null},
            {"id":"e1","occurrence":null,"date":"2026-11-03","endDate":"2026-11-03","start":"10:30","end":"11:00","title":"Dr. Berg","location":"Hauptstr. 1","person":"Mia","note":"","url":"https://example.com","source":"appointment","searchId":"s1","externalId":null,"rrule":null},
            {"id":"s9","occurrence":"2026-11-03","date":"2026-11-03","endDate":"2026-11-03","start":"16:00","end":"17:00","title":"Swimming","location":"","person":"Leo","note":"","url":"","source":"manual","searchId":null,"externalId":null,"rrule":"FREQ=WEEKLY"}
          ]},
          "birthdays": {"2026-05-04":[{"name":"Mia","age":8}]}
        }
        """
        let state = try JSONDecoder().decode(CalendarState.self, from: Data(json.utf8))
        #expect(state.family.name == "Krug" && !state.family.readOnly)
        #expect(state.types.map(\.role) == [.dayOff, .covers, .needsCover])
        #expect(state.types[1].isAway)
        #expect(state.typeYears == [2025, 2026])
        #expect(state.entries["2026-08-03"] == ["vacation", "kita"])
        #expect(state.notes?["2026-12-24"]?.text == "🎄 Christmas")
        let events = try #require(state.events?["2026-11-03"])
        #expect(events[1].date == Day("2026-11-03"))
        #expect(events[1].timeText == "10:30–11:00")
        #expect(events[1].line == "10:30 Dr. Berg (Mia)")
        #expect(events[1].isAppointment && !events[1].repeats && events[1].uid == "e1")
        // A trip over three days, listed under each of them.
        #expect(events[0].start == nil && events[0].timeText == nil && events[0].searchId == nil)
        #expect(events[0].isMultiDay && events[0].endDate == Day("2026-11-04"))
        // An occurrence of a weekly series: addressed by the series' id and its day.
        #expect(events[2].repeats && events[2].occurrence == Day("2026-11-03") && events[2].uid == "s9@2026-11-03")
        #expect(state.birthdays?["2026-05-04"]?.first == CalendarBirthday(name: "Mia", age: 8))

        let client = APIClient(baseURL: URL(string: "https://ohana.invalid")!, token: nil)
        let store = CalendarStore(api: FamilyAPI(client: client, familyID: "f1"), year: 2026, readOnly: false)
        store.apply(state)
        #expect(store.types.map(\.id) == ["holiday", "vacation", "kita"])
        #expect(store.types(on: Day("2026-08-03")!).map(\.id) == ["vacation", "kita"])
        #expect(store.events[Day("2026-11-03")!]?.count == 3)
        #expect(store.event("s9@2026-11-03")?.title == "Swimming")
        #expect(!store.readOnly)
    }

    @Test func decodesAViewersFamilyWithoutExtras() throws {
        // A family-planner script's response has no events or birthdays; a type from
        // family-planner's files has no away flag.
        let json = """
        {"family":{"id":"f1","name":"Krug","access":"view","readOnly":true,"updatedAt":"2026-10-01 08:00:00"},
         "types":[{"id":"sick","year":2026,"name":"Sick","color":"#ef4444","role":"none","position":0}],
         "entries":{}}
        """
        let state = try JSONDecoder().decode(CalendarState.self, from: Data(json.utf8))
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
        // Without the new fields (an older answer): one day, no repeat.
        #expect(event.endDate == event.date && event.occurrence == nil && event.rrule == nil && event.uid == "e1")
    }

    @Test func decodesOccurrencesThatSpanDays() throws {
        let json = """
        {"events":[
          {"id":"s1","occurrence":"2026-11-05","date":"2026-11-06","endDate":"2026-11-08","start":"09:00","end":"17:00","title":"Camp","location":"","person":"Mia","note":"","url":"","source":"apple","searchId":null,"externalId":"ABC-1","rrule":"FREQ=MONTHLY;BYDAY=1TH"}
        ]}
        """
        let event = try #require(try JSONDecoder().decode(CalendarEventsResponse.self, from: Data(json.utf8)).events.first)
        // An override moved it a day: still addressed by its original day.
        #expect(event.occurrence == Day("2026-11-05") && event.date == Day("2026-11-06") && event.uid == "s1@2026-11-05")
        #expect(event.isMultiDay && event.externalId == "ABC-1" && event.source == "apple")
        #expect(event.timeText(on: Day("2026-11-06")!) == "from 09:00")
        #expect(event.timeText(on: Day("2026-11-07")!) == nil)
        #expect(event.timeText(on: Day("2026-11-08")!) == "until 17:00")
        #expect(event.line(on: Day("2026-11-06")!) == "09:00 Camp (Mia)")
        #expect(event.line(on: Day("2026-11-07")!) == "Camp (Mia)")
        #expect(event.line(on: Day("2026-11-08")!) == "until 17:00 Camp (Mia)")
        #expect(event.repeatText == "Monthly on the first Thursday")
        // Moved to start on another day, it keeps its length.
        let moved = event.on(Day("2026-11-20")!)
        #expect(moved.endDate == Day("2026-11-22") && moved.uid == event.uid)
    }

    @Test func decodesASeries() throws {
        let json = """
        {"id":"s1","date":"2026-11-02","endDate":"2026-11-02","start":"16:00","end":"17:00","title":"Swimming",
         "location":"Stadtbad","person":"Leo","note":"","url":"","source":"manual","searchId":null,"externalId":null,
         "rrule":"FREQ=WEEKLY;UNTIL=20270101","exdates":["2026-12-21","2026-12-28"],
         "overrides":[{"occurrence":"2026-11-16","date":"2026-11-17","endDate":"2026-11-17","start":"17:00","end":"18:00",
                       "title":"Swimming (Tuesday)","location":"Stadtbad","person":"Leo","note":"","url":""}]}
        """
        let series = try JSONDecoder().decode(CalendarEventSeries.self, from: Data(json.utf8))
        #expect(series.repeats && series.exdates == [Day("2026-12-21")!, Day("2026-12-28")!])
        #expect(series.overrides.first?.occurrence == Day("2026-11-16") && series.overrides.first?.date == Day("2026-11-17"))
        #expect(RepeatRule(series.rrule ?? "")?.end == .until(Day("2027-01-01")!))

        // What DELETE answers: the series as it is now, or that it is gone.
        let rest = try JSONDecoder().decode(CalendarEventDeleteAnswer.self, from: Data(json.utf8))
        #expect(rest.deleted == nil && rest.series?.id == "s1")
        let gone = try JSONDecoder().decode(CalendarEventDeleteAnswer.self, from: Data(#"{"deleted":"s1"}"#.utf8))
        #expect(gone.deleted == "s1" && gone.series == nil)

        // Put back as it was: everything, the days taken out and the changed occurrences too.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try #require(try JSONSerialization.jsonObject(with: encoder.encode(CalendarEventSeriesBody(series))) as? [String: Any])
        #expect(body["rrule"] as? String == "FREQ=WEEKLY;UNTIL=20270101")
        #expect(body["exdates"] as? [String] == ["2026-12-21", "2026-12-28"])
        #expect((body["overrides"] as? [[String: Any]])?.first?["occurrence"] as? String == "2026-11-16")
        #expect(body["id"] == nil && body["source"] == nil && body["externalId"] == nil)
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

        // An all-day event clears start and end (PATCH merges what is sent), and the rule.
        let allDay = CalendarEventInput(date: Day("2026-11-03")!, start: nil, end: "11:00", title: "Trip")
        #expect(try text(allDay)
                == #"{"date":"2026-11-03","end":null,"endDate":"2026-11-03","location":"","note":"","person":"","rrule":null,"start":null,"title":"Trip","url":""}"#)
        let timed = CalendarEventInput(date: Day("2026-11-03")!, start: "10:30", end: "11:00", title: "Dr. Berg", person: "Mia")
        #expect(try text(timed).contains(#""end":"11:00""#))
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

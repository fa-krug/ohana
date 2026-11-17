import Foundation
import Testing
@testable import Ohana

/// Check-ups and vaccinations: the module, its routes, decoding the server's answer leniently,
/// how an item reads and what an assistant change reloads.
@MainActor
struct HealthTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func theModuleAndItsRoutes() throws {
        #expect(Module.modules.contains(.health))
        #expect(Module.health.title == "Health")
        // The knowledge base keeps ⌘9; health has no number.
        #expect(Module.knowledge.shortcut?.character == "9")
        #expect(Module.health.shortcut == nil)
        #expect(AppRoute.parse(webPath: "/f/fam1/health")?.route == .module(.health))
        #expect(AppRoute.parse(webPath: "/f/fam1/health/m1")?.route == .healthMember(id: "m1"))
        #expect(AppRoute.healthMember(id: "m1").module == .health)
        let info = try decode(ServerInfo.self, """
        {"name":"Ohana","version":"1","apiVersion":1,"modules":["calendar","health"]}
        """)
        #expect(info.isEnabled(.health))
    }

    @Test func decodesTheOverviewLeniently() throws {
        let overview = try decode(HealthOverview.self, """
        {"members":[{"id":"m1","name":"Mia","account":false,"birthday":"2025-02-10","color":"green","photo":null,
          "canEdit":true,"counts":{"due":1,"past":2,"unknown":0},
          "next":{"code":"u7","kind":"checkup","title":"U7","detail":"Months 21–24","vaccines":[],
                  "notAlwaysPaid":false,"status":"due","from":"2026-10-10","to":"2027-02-10",
                  "until":"2027-05-10","repeats":false,"records":[]},
          "items":[
            {"code":"u7","kind":"checkup","title":"U7","detail":"","status":"due",
             "from":"2026-10-10","until":"2027-05-10"},
            {"code":"u6","kind":"checkup","title":"U6","status":"done",
             "records":[{"id":"r1","day":null,"status":"done","note":""}]},
            {"code":"x","kind":"newKind","title":"X","status":"somethingNew"}
          ]},
         {"id":"m2","name":"Leo","birthday":null}],
         "canEdit":true,"scan":true,"asOf":"STIKO 2025"}
        """)
        #expect(overview.scan && overview.canEdit && overview.asOf == "STIKO 2025")
        let mia = try #require(overview.members.first)
        #expect(mia.birthday == Day(year: 2025, month: 2, day: 10))
        #expect(mia.age(on: Day(year: 2026, month: 11, day: 2)) == 1)
        #expect(mia.due.map(\.code) == ["u7"])
        #expect(mia.checkups.map(\.code) == ["u7", "u6"])
        #expect(mia.items[2].status == .unknown && mia.items[2].kind == .vaccination)
        #expect(mia.items[1].latest?.day == nil)
        #expect(overview.members[1].items.isEmpty && overview.members[1].age() == nil)
    }

    @Test func howAnItemReads() throws {
        let due = try decode(HealthItem.self, #"{"code":"u7","title":"U7","status":"due","until":"2027-05-10"}"#)
        #expect(HealthText.line(due).hasSuffix(HealthText.date(Day(year: 2027, month: 5, day: 10))))
        let unknown = try decode(HealthItem.self, #"{"code":"td","title":"Tetanus","status":"unknown","repeats":true}"#)
        #expect(HealthText.line(unknown) == "When was the last one?")
        #expect(HealthText.systemImage(.done) == "checkmark.circle.fill")
    }

    @Test func encodesARecordWithoutADateAsNull() throws {
        let data = try JSONEncoder().encode(HealthRecordInput(code: "u7", day: nil))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["day"] is NSNull && json["status"] as? String == "done")
    }

    @Test func assistantChangesReloadThePage() {
        #expect(AssistantChangeAreas.areas(change: "health") == [.health])
        #expect(AssistantChangeAreas.areas(path: "/health/records/r1") == [.health])
        #expect(AssistantChangeAreas.areas(tool: "record_health") == [.health])
        #expect(AssistantPages.page(of: .health) == "health")
    }
}

import Foundation
import Testing
@testable import Ohana

struct FamilySettingsTests {
    /// GET /household as the server answered it (web tests' family).
    static let household = """
    {"name":"Krug","role":"editor","selfId":"u1","members":[{"userId":"u1","email":"anna@test","name":"Anna","role":"editor","birthday":"1990-11-20","joinedAt":"2026-11-01T12:00:00.000Z"},{"userId":"u2","email":"ben@test","name":"","role":"viewer","birthday":null,"joinedAt":"2026-11-01T12:00:00.000Z"}],"people":[{"id":"p1","name":"Mia","birthday":"2018-11-15"}],"invites":[{"id":"i1","url":"http://ohana.test/invite/JoB_YiEHiYZCAkViLmlhsA","role":"viewer","personId":"p1","expiresAt":"2026-11-08T12:00:00.000Z"}],"home":{"address":"Hauptstr. 1, Berlin","lat":52.5,"lng":13.4},"channels":[{"id":"c1","name":"Phone","provider":"PUSHBULLET","target":"","enabled":true,"hasToken":true,"smtpHost":"","smtpPort":465,"smtpUsername":"","smtpFrom":""}],"events":[{"event":"appointment_found","enabled":true,"channelIds":null,"hasChannels":false},{"event":"coverage_gap","enabled":true,"channelIds":null,"hasChannels":true},{"event":"shopping_reminder","enabled":false,"channelIds":null,"hasChannels":true},{"event":"assistant_turn_finished","enabled":false,"channelIds":null,"hasChannels":true}]}
    """

    @Test func decodesTheHousehold() throws {
        let h = try JSONDecoder().decode(FamilyHousehold.self, from: Data(Self.household.utf8))
        #expect(h.canEdit)
        #expect(h.members.map(\.label) == ["Anna", "ben@test"])
        #expect(h.members[0].birthday == Day("1990-11-20"))
        #expect(h.members[1].birthday == nil)
        #expect(h.invite(for: h.people[0])?.id == "i1")
        #expect(h.person(h.invites[0].personId)?.name == "Mia")
        #expect(h.invites[0].link?.host() == "ohana.test")
        #expect(h.invites[0].expiryDate != nil)
        #expect(h.home.hasLocation)
        #expect(h.channels[0].kind == .pushbullet)
        #expect(h.channels[0].hasToken)
        #expect(h.events.map(\.hasChannels) == [false, true, true, true])
        #expect(h.events.allSatisfy { $0.channelIds == nil })
    }

    @Test func decodesAViewersHouseholdWithoutAHome() throws {
        let json = """
        {"name":"Krug","role":"viewer","selfId":"u2","members":[],"people":[],"invites":[],"home":{"address":null,"lat":null,"lng":null},"channels":[],"events":[]}
        """
        let h = try JSONDecoder().decode(FamilyHousehold.self, from: Data(json.utf8))
        #expect(!h.canEdit)
        #expect(!h.home.hasLocation)
    }

    @Test func decodesTheAnswersOfChanges() throws {
        let added = try JSONDecoder().decode(FamilyAddedPerson.self, from: Data("""
        {"person":{"id":"p1","name":"Mia","birthday":null},"invite":{"code":"abc","expiresAt":"2026-11-08T12:00:00.000Z","url":"http://ohana.test/invite/abc"}}
        """.utf8))
        #expect(added.invite?.url == "http://ohana.test/invite/abc")
        let suggestions = try JSONDecoder().decode([FamilyLocationSuggestion].self, from: Data("""
        [{"label":"Hauptstraße 1, 10827 Berlin","latitude":"52.48","longitude":"13.35"}]
        """.utf8))
        #expect(Double(suggestions[0].latitude) == 52.48)
    }

    @Test func encodesNullsTheServerNeeds() throws {
        func json(_ value: some Encodable) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        }
        let clear = try json(FamilyBirthdayInput(birthday: nil))
        #expect(clear.keys.contains("birthday") && clear["birthday"] is NSNull)
        #expect(try json(FamilyBirthdayInput(birthday: Day("2001-02-03")))["birthday"] as? String == "2001-02-03")
        let person = try json(FamilyPersonInput(name: "Mia", birthday: nil, invite: .viewer))
        #expect(person["invite"] as? String == "viewer" && person["birthday"] is NSNull)
        let home = try json(FamilyHomeInput(address: "", lat: nil, lng: nil))
        #expect(home["lat"] is NSNull && home["address"] as? String == "")
        let pref = FamilyEventPref(event: "coverage_gap", enabled: true, channelIds: nil, hasChannels: true)
        #expect(try json(pref.input)["channelIds"] is NSNull)
        var channel = FamilyChannelInput()
        channel.provider = .telegram
        #expect(try json(channel)["provider"] as? String == "TELEGRAM")
    }

    @Test func checksChannelFieldsLikeTheServer() {
        var input = FamilyChannelInput()
        input.name = "Phone"
        #expect(input.missing() == [.token])
        #expect(input.canSave(hasToken: true))
        input.provider = .email
        #expect(input.missing() == [.smtpHost, .smtpUsername, .token, .target])
        input.smtpHost = "smtp.example.com"
        input.smtpUsername = "me"
        input.target = "me@example.com"
        input.token = "pw"
        #expect(input.canSave())
        input.smtpPort = 0
        #expect(!input.canSave())
        input.smtpPort = 587
        input.name = "  "
        #expect(!input.canSave())
    }

    @Test func picksEventChannels() {
        let pref = FamilyEventPref(event: "shopping_reminder", enabled: true, channelIds: nil, hasChannels: true)
        let off = pref.toggling("b", on: false, all: ["a", "b", "c"])
        #expect(off.channelIds == ["a", "c"])
        #expect(off.toggling("b", on: true, all: ["a", "b", "c"]).channelIds == ["a", "c", "b"])
        #expect(off.toggling("a", on: true, all: []).channelIds == ["a", "c"])
    }

    @Test func countsAges() {
        let born = Day(year: 2018, month: 11, day: 15)
        #expect(FamilyBirthdays.age(born, on: Day(year: 2026, month: 11, day: 14)) == 7)
        #expect(FamilyBirthdays.age(born, on: Day(year: 2026, month: 11, day: 15)) == 8)
        #expect(FamilyBirthdays.age(Day(year: 2020, month: 2, day: 29), on: Day(year: 2025, month: 2, day: 28)) == 4)
        #expect(FamilyBirthdays.age(Day(year: 2020, month: 2, day: 29), on: Day(year: 2025, month: 3, day: 1)) == 5)
    }

    @Test func namesTheExportFileLikeTheWeb() {
        let today = Day(year: 2026, month: 10, day: 30)
        #expect(FamilyExportFile.fileName(familyName: "Krug", today: today) == "Krug 2026-10-30.json")
        #expect(FamilyExportFile.fileName(familyName: "A/B: C", today: today) == "A-B- C 2026-10-30.json")
        #expect(FamilyExportFile.fileName(familyName: "a//\\b", today: today) == "a-b 2026-10-30.json")
        #expect(FamilyExportFile.fileName(familyName: "  ", today: today) == "family 2026-10-30.json")
    }

    @Test func recognizesExportFiles() {
        #expect(FamilyExportFile.isExportFile(Data(#"{"format":"family-planner","version":2}"#.utf8)))
        #expect(FamilyExportFile.isExportFile(Data(#"{"format":"vacation-planner"}"#.utf8)))
        #expect(!FamilyExportFile.isExportFile(Data(#"{"format":"other"}"#.utf8)))
        #expect(!FamilyExportFile.isExportFile(Data("[1,2]".utf8)))
        #expect(!FamilyExportFile.isExportFile(Data("nope".utf8)))
        let pretty = String(decoding: FamilyExportFile.pretty(Data(#"{"a":"x/y"}"#.utf8)), as: UTF8.self)
        #expect(pretty.contains("\n") && pretty.contains("x/y"))
    }

    @Test func writesAgesWithPlurals() {
        let today = Day(year: 2026, month: 11, day: 20)
        #expect(FamilyBirthdays.text(Day(year: 2025, month: 11, day: 20), today: today).hasSuffix(" · 1 year"))
        #expect(FamilyBirthdays.text(Day(year: 2018, month: 11, day: 15), today: today).hasSuffix(" · 8 years"))
    }

    @Test func opensSettingsPagesByRoute() {
        #expect(FamilySettingsPageView.page(for: .settings(.home)) == .home)
        #expect(FamilySettingsPageView.page(for: .settings(.notifications)) == .notifications)
        #expect(FamilySettingsPageView.page(for: .module(.settings)) == nil)
        #expect(AppRoute.settings(.data).module == .settings)
    }
}

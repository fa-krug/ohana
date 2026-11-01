import Foundation
import Testing
@testable import Ohana

@MainActor
struct ServerInfoTests {
    private func decode(_ json: String) throws -> ServerInfo {
        try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
    }

    @Test func decodesTheServersInfo() throws {
        let info = try decode("""
        {"name":"Ohana","version":"0.2.0","apiVersion":1,"modules":["calendar","finance","meals","appointments","assistant"]}
        """)
        #expect(info.name == "Ohana")
        #expect(info.version == "0.2.0")
        #expect(info.apiVersion == 1)
        #expect(info.isSupported)
        #expect(Module.allCases.allSatisfy { info.isEnabled($0) })
    }

    @Test func hidesTheModulesAServerTurnedOff() throws {
        let info = try decode("""
        {"name":"Ohana","version":"0.2.0","apiVersion":1,"modules":["calendar","meals"]}
        """)
        #expect(info.isEnabled(.calendar) && info.isEnabled(.meals))
        #expect(!info.isEnabled(.finance) && !info.isEnabled(.appointments) && !info.isEnabled(.assistant))
        // The overview, the calendar and the settings are always there.
        #expect(info.isEnabled(.overview) && info.isEnabled(.settings))
        let none = try decode(#"{"name":"Ohana","version":"0.2.0","apiVersion":1,"modules":[]}"#)
        #expect(none.isEnabled(.calendar))
    }

    @Test func refusesOlderAPIVersions() throws {
        #expect(ServerInfo.requiredAPIVersion == 1)
        #expect(!ServerInfo.legacy.isSupported)
        #expect(ServerInfo.legacy.apiVersion == 0)
        #expect(Module.allCases.allSatisfy { ServerInfo.legacy.isEnabled($0) })
        let old = try decode(#"{"name":"Ohana","version":"0.1.0","apiVersion":0,"modules":["calendar"]}"#)
        #expect(!old.isSupported)
        let newer = try decode(#"{"name":"Ohana","version":"1.0.0","apiVersion":2,"modules":["calendar"]}"#)
        #expect(newer.isSupported)
        // Missing fields: no API version is too old, no module list is everything.
        let bare = try decode("{}")
        #expect(!bare.isSupported)
        #expect(bare.isEnabled(.assistant))
        #expect(ServerInfo.outdatedMessage == "This server runs an older version of Ohana. Ask its administrator to update it.")
    }

    @Test func theDemoHasEveryModule() async throws {
        let info = try await ServerInfo.fetch(from: APIClient(demo: DemoServer()))
        #expect(info.isSupported)
        #expect(Module.allCases.allSatisfy { info.isEnabled($0) })

        let app = AppModel(signedOutPreview: ())
        await app.refresh()
        #expect(app.phase == .ready)
        #expect(app.serverInfo == info)
        #expect(app.isEnabled(.assistant) && app.isEnabled(.finance))
    }

    @Test func routesNeedTheirModule() {
        #expect(AppRoute.recipe(id: "r1").requiredModule == .meals)
        #expect(AppRoute.module(.finance).requiredModule == .finance)
        #expect(AppRoute.assistantChat(id: nil).requiredModule == .assistant)
        #expect(AppRoute.settings(.finance).requiredModule == .finance)
        #expect(AppRoute.settings(.assistant).requiredModule == .assistant)
        #expect(AppRoute.settings(.notifications).requiredModule == .settings)
        #expect(AppRoute.calendarDay(Day(year: 2026, month: 11, day: 1)).requiredModule == .calendar)
    }

    @Test func aFamilyIgnoresRoutesAndQuestionsForModulesThatAreOff() {
        let family = FamilySummary(id: "demo", name: "Demo", role: .editor, memberCount: 1)
        let context = FamilyContext(family: family, api: FamilyAPI(client: APIClient(demo: DemoServer()), familyID: "demo"))
        // Unknown: everything shows.
        #expect(context.isEnabled(.assistant))

        context.serverInfo = ServerInfo(name: "Ohana", version: "0.2.0", apiVersion: 1, modules: ["calendar", "meals"])
        context.open(.recipe(id: "r1"))
        #expect(context.pendingRoute == .recipe(id: "r1"))
        _ = context.takeRoute(for: .meals)

        context.open(.financeTransactions(categoryID: nil))
        context.open(.settings(.assistant))
        context.open(.appointmentSearch(id: "s1"))
        #expect(context.pendingRoute == nil)
        context.open(.settings(.notifications))
        #expect(context.pendingRoute == .settings(.notifications))

        context.ask("Hello", send: true)
        #expect(context.assistantRequest == nil)
    }

    @Test func notificationEventsBelongToTheirModules() {
        let modules = ["appointment_found", "coverage_gap", "assistant_turn_finished", "other"].map {
            FamilyEventPref(event: $0, enabled: true, channelIds: nil, hasChannels: true).module
        }
        #expect(modules == [.appointments, .calendar, .assistant, nil])
    }
}

struct ServerAccountPageTests {
    @Test func buildsTheAccountPageURL() throws {
        let attempt = DevicePairing.Attempt(state: "abc-123")
        let url = ServerAccountPage.url(server: URL(string: "https://x.example/sub/")!, attempt: attempt)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "x.example")
        #expect(components.path == "/sub/account")
        #expect(components.queryItems == [URLQueryItem(name: "state", value: "abc-123")])
    }

    @Test func checksTheCallback() {
        let attempt = DevicePairing.Attempt(state: "s-1")
        let outcome = { (link: String) in ServerAccountPage.outcome(of: URL(string: link)!, attempt: attempt) }
        #expect(outcome("ohana://account-callback?state=s-1&changed=passkey") == .finished(changed: .passkey))
        #expect(outcome("ohana://account-callback?state=s-1&changed=email") == .finished(changed: .email))
        #expect(outcome("ohana://account-callback?state=s-1") == .finished(changed: nil))
        // A change the app doesn't know: back, nothing to say.
        #expect(outcome("ohana://account-callback?state=s-1&changed=name") == .finished(changed: nil))
        #expect(outcome("ohana://account-callback?state=forged&changed=passkey") == .stateMismatch)
        #expect(outcome("ohana://account-callback?changed=passkey") == .malformed)
        #expect(outcome("ohana://auth-callback?state=s-1&token=x") == .malformed)
        #expect(outcome("https://x.example/account-callback?state=s-1") == .malformed)
    }
}

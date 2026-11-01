import Foundation
import Testing
@testable import Ohana

struct DevicePairingTests {
    @Test func normalizesTheServerAddress() {
        #expect(DevicePairing.serverURL(from: "ohana.example.com")?.absoluteString == "https://ohana.example.com")
        #expect(DevicePairing.serverURL(from: " http://localhost:3000/ ")?.absoluteString == "http://localhost:3000")
        #expect(DevicePairing.serverURL(from: "https://x.example/sub/?q=1#f")?.absoluteString == "https://x.example/sub")
        #expect(DevicePairing.serverURL(from: "") == nil)
        #expect(DevicePairing.serverURL(from: "ftp://x.example") == nil)
        #expect(DevicePairing.serverURL(from: "not a server") == nil)
    }

    @Test func takesTheServerFromAPastedLink() {
        // The address from the browser, any page of the server, an invite link.
        #expect(ServerLink("https://ohana.example/f/abc/calendar?tab=x")?.server.absoluteString == "https://ohana.example")
        #expect(ServerLink("ohana.example/account")?.server.absoluteString == "https://ohana.example")
        #expect(ServerLink("http://localhost:3000/login?next=/f/a")?.server.absoluteString == "http://localhost:3000")
        let invite = ServerLink(" https://ohana.example/invite/-D3Q5LCqfCN6SYk4HPpRxg\n")
        #expect(invite?.server.absoluteString == "https://ohana.example")
        #expect(invite?.inviteCode == "-D3Q5LCqfCN6SYk4HPpRxg")
        // A server under a sub-path keeps it, up to the web app's own pages.
        let sub = ServerLink("https://x.example/ohana/invite/abc")
        #expect(sub?.server.absoluteString == "https://x.example/ohana")
        #expect(sub?.inviteCode == "abc")
        #expect(ServerLink("https://x.example/ohana")?.server.absoluteString == "https://x.example/ohana")
        // Not an invite: no code.
        #expect(ServerLink("https://ohana.example/invite/")?.inviteCode == nil)
        #expect(ServerLink("https://ohana.example/f/abc")?.inviteCode == nil)
        // No credentials carried over from a pasted link.
        #expect(ServerLink("https://me:secret@ohana.example/f/a")?.server.absoluteString == "https://ohana.example")
        // Not a server.
        #expect(ServerLink("ohana://invite/abc") == nil)
        #expect(ServerLink("ftp://ohana.example") == nil)
        #expect(ServerLink("two words") == nil)
    }

    @Test func saysWhatIsWrongWithTheAddress() {
        #expect(ConnectServerView.problem("") == nil)
        #expect(ConnectServerView.problem("ohana.example.com") == nil)
        #expect(ConnectServerView.problem("https://ohana.example/invite/abc") == nil)
        #expect(ConnectServerView.problem("ohana example") == "An address has no spaces, like ohana.example.com.")
        #expect(ConnectServerView.problem("ftp://ohana.example") == "That isn’t a web address. It looks like ohana.example.com.")
    }

    @Test func buildsThePairingURL() throws {
        let attempt = DevicePairing.Attempt(state: "abc-123-def")
        let url = DevicePairing.pairingURL(server: URL(string: "https://x.example/sub")!, attempt: attempt, deviceName: "Mac mini")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/sub/device/pair")
        #expect(components.queryItems?.first { $0.name == "state" }?.value == "abc-123-def")
        #expect(components.queryItems?.first { $0.name == "deviceName" }?.value == "Mac mini")
    }

    @Test func checksTheCallback() {
        let attempt = DevicePairing.Attempt(state: "s-1-2-3-4")
        let ok = URL(string: "ohana://auth-callback?token=ohana_abc&state=s-1-2-3-4")!
        #expect(DevicePairing.outcome(of: ok, attempt: attempt) == .paired(token: "ohana_abc"))
        let other = URL(string: "ohana://auth-callback?token=ohana_abc&state=forged")!
        #expect(DevicePairing.outcome(of: other, attempt: attempt) == .stateMismatch)
        let cancelled = URL(string: "ohana://auth-callback?error=cancelled&state=s-1-2-3-4")!
        #expect(DevicePairing.outcome(of: cancelled, attempt: attempt) == .cancelled)
        #expect(DevicePairing.outcome(of: URL(string: "ohana://auth-callback")!, attempt: attempt) == .malformed)
    }
}

struct APIClientTests {
    @Test func joinsPathsAndQueries() {
        let client = APIClient(baseURL: URL(string: "https://x.example/base")!, token: nil)
        #expect(client.url("/api/v1/me").absoluteString == "https://x.example/base/api/v1/me")
        #expect(client.url("/api/v1/x?a=1", query: ["b": "2", "c": nil]).absoluteString == "https://x.example/base/api/v1/x?a=1&b=2")
        let family = FamilyAPI(client: client, familyID: "f1")
        #expect(family.path("/finance") == "/api/v1/families/f1/finance")
        #expect(family.path("") == "/api/v1/families/f1")
    }

    @Test func readsBothErrorShapes() {
        #expect(APIError.message(from: Data(#"{"error":"Nope"}"#.utf8)) == "Nope")
        #expect(APIError.message(from: Data(#"{"message":"Also nope"}"#.utf8)) == "Also nope")
        #expect(APIError.message(from: Data("plain".utf8)) == nil)
    }

    @Test func parsesDays() {
        #expect(Day("2026-02-28")?.adding(days: 1).description == "2026-03-01")
        #expect(Day("2026-13-01") == nil)
        #expect(Day("2026-01-05")! < Day("2026-01-06")!)
    }
}

struct AppRouteTests {
    @Test func mapsWebPaths() {
        #expect(AppRoute.parse(webPath: "/f/fam1")?.route == .module(.overview))
        #expect(AppRoute.parse(webPath: "/f/fam1/meals/recipes/r1")?.route == .recipe(id: "r1"))
        #expect(AppRoute.parse(webPath: "/f/fam1/meals/recipes/new")?.route == .newRecipe)
        #expect(AppRoute.parse(webPath: "/f/fam1/meals/cook/r1")?.route == .cook(recipeID: "r1"))
        // The shopping list lives in Reminders: its old links and the reminders' urls open the plan.
        #expect(AppRoute.parse(webPath: "/f/fam1/meals/shopping")?.route == .mealPlan)
        #expect(AppRoute.parse(webPath: "/f/fam1/meals/shopping/2026-11-07/12-3")?.route == .mealPlan)
        #expect(AppRoute.parse(webPath: "/f/fam1/calendar/2026-11-03")?.route == .calendarDay(Day(year: 2026, month: 11, day: 3)))
        #expect(AppRoute.parse(webPath: "/f/fam1/calendar")?.route == .module(.calendar))
        #expect(AppRoute.parse(webPath: "/f/fam1/appointments/s1/slots/x9")?.route == .appointmentSlot(searchID: "s1", resultID: "x9"))
        #expect(AppRoute.parse(webPath: "/f/fam1/appointments/s1/edit")?.route == .appointmentSearch(id: "s1"))
        #expect(AppRoute.parse(webPath: "/f/fam1/assistant")?.route == .assistantChat(id: nil))
        #expect(AppRoute.parse(webPath: "/f/fam1/assistant")?.familyID == "fam1")
        #expect(AppRoute.parse(webPath: "/account") == nil)
        #expect(AppRoute.recipe(id: "x").module == .meals)
        #expect(AppRoute.parse(webPath: "/f/fam1/settings", tab: "ai")?.route == .settings(.assistant))
        #expect(AppRoute.parse(webPath: "/f/fam1/settings", tab: "general")?.route == .module(.settings))
    }
}

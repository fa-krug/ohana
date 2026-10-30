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

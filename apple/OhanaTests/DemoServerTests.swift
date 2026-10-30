import Foundation
import Testing
@testable import Ohana

@MainActor
struct DemoServerTests {
    private static let today = Day(year: 2026, month: 10, day: 30)

    private func request(_ path: String, query: [String: String] = [:]) -> DemoServer.Request {
        DemoServer.Request(method: .get, path: path, query: query, familyPath: DemoServer.familyPath(of: path),
                           today: Self.today, now: Date(timeIntervalSince1970: 1_793_352_600))
    }

    @Test func templatesDaysMonthsYearsTimesAndQueries() {
        let req = request("/api/v1/families/demo", query: ["year": "2027"])
        let text = #"["{{day}}","{{day:3}}","{{day:-30}}","{{month:-1}}",{{year:1}},"{{time:-90}}","{{query:year}}","{{anniversary:10:1952}}","{{other}}"]"#
        #expect(DemoServer.template(text, for: req)
            == #"["2026-10-30","2026-11-02","2026-09-30","2026-09",2027,"2026-10-30T08:00:00.000Z","2027","1952-11-09","{{other}}"]"#)
    }

    @Test func namesTheFileOfAPath() {
        #expect(DemoServer.fixtureName(for: request("/api/v1/me")) == "me")
        #expect(DemoServer.fixtureName(for: request("/api/v1/families/demo")) == "family")
        #expect(DemoServer.fixtureName(for: request("/api/v1/families/demo/finance/summary")) == "finance-summary")
        #expect(DemoServer.fixtureName(for: request("/api/v1/families/demo/meals/recipes/recipe-soup")) == "meals-recipes-recipe-soup")
        #expect(DemoServer.fixtureName(for: request("/api/health")) == nil)
    }

    @Test func answersOnlyReads() async throws {
        let client = APIClient(demo: DemoServer())
        let me: MeResponse = try await client.get("/api/v1/me")
        #expect(me.families.map(\.id) == [DemoServer.familyID])
        #expect(me.families.first?.canEdit == false)

        await #expect(throws: APIError.self) {
            let _: JSONValue = try await client.send(.patch, "/api/v1/me/profile", body: ["name": "X"])
        }
        do {
            let _: JSONValue = try await client.send(.delete, "/api/v1/families/demo/meals/recipes/recipe-soup")
            Issue.record("a change must fail")
        } catch let APIError.http(status, message) {
            #expect(status == 403)
            #expect(message == DemoServer.readOnlyMessage)
        }
        do {
            let _: JSONValue = try await client.get("/api/v1/families/demo/nothing-here")
            Issue.record("an unknown route must fail")
        } catch let APIError.http(status, _) {
            #expect(status == 404)
        }
    }

    @Test func withoutAServerTheAppShowsTheDemo() async {
        let app = AppModel(signedOutPreview: ())
        #expect(app.isDemo)
        #expect(app.serverURL == nil)
        await app.refresh()
        #expect(app.phase == .ready)
        #expect(app.selectedFamily?.id == DemoServer.familyID)
        #expect(app.selectedFamily?.canEdit == false)
        #expect(app.switching == nil)
    }
}

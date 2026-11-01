import Foundation
import Testing
@testable import Ohana

/// The search tab over the demo family: `/search` answers what `FamilySearchView` decodes, every
/// hit opens somewhere, and the matching follows the server's (every word, case and accents
/// ignored, eight per kind).
struct DemoSearchTests {
    static let today = Day(year: 2026, month: 10, day: 30)
    static let server = DemoServer(today: { today }, now: { Date(timeIntervalSince1970: 1_793_354_400) })

    private func search(_ q: String) throws -> FamilySearchResult {
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo/search")
        url.append(queryItems: [URLQueryItem(name: "q", value: q)])
        let (data, response) = Self.server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200)
        return try APIClient.decoder.decode(FamilySearchResult.self, from: data)
    }

    @Test func findsTheRecipeAndItsChat() throws {
        let result = try search("Lasagne")
        let recipes = result.results.filter { $0.kind == .recipe }
        #expect(recipes.first?.route == .recipe(id: "recipe-lasagne"))
        #expect(result.groups.first?.kind == .recipe)
    }

    @Test func ignoresAccentsAndOpensTransactions() throws {
        let result = try search("backerei")
        let hits = result.results.filter { $0.kind == .transaction }
        #expect(!hits.isEmpty && hits.allSatisfy { $0.title == "Bäckerei Siebert" })
        #expect(result.currency == "EUR")
        let first = try #require(hits.first)
        #expect(first.amountCents != nil)
        #expect(first.route == .financeTransaction(id: first.itemID, day: try #require(first.day)))
    }

    @Test func limitsEachKindAndCountsTheRest() throws {
        let result = try search("parker")
        #expect(result.results.filter { $0.kind == .transaction }.count == 8)
        #expect(result.more["transaction"] == 3)
        let people = result.results.filter { $0.kind == .person }
        #expect(Set(people.map(\.title)) == ["Anna Parker", "Ben Parker"])
        #expect(people.allSatisfy { $0.account == true && $0.route == .settings(.members) })
    }

    @Test func everyWordHasToMatch() throws {
        let grandma = try search("grandma")
        #expect(grandma.results.contains { $0.kind == .note && $0.route != nil })
        #expect(grandma.results.contains { $0.kind == .person && $0.title == "Grandma Rose" && $0.account == false })
        #expect(try search("grandma hauptbahnhof").results.map(\.kind) == [.note])
        #expect(try search("mia check").results.contains { $0.kind == .chat && $0.route == .assistantChat(id: $0.itemID) })
        #expect(try search("   ").results.isEmpty)
        #expect(try search("zzzz nothing").groups.isEmpty)
    }
}

import Foundation
import Testing
@testable import Ohana

/// The placeholders of recipes being imported in the background (`RecipeImports`).
struct RecipeImportsTests {
    static func job(_ id: String, _ status: String, title: String = "", url: String = "https://example.com/r") -> RecipeImportJob {
        RecipeImportJob(id: id, url: url, title: title, imageUrl: nil, status: status, error: nil,
                        createdAt: "2026-11-02T10:00:00.000Z")
    }

    @Test func anImportUnderWayThatLeftTheListFinished() {
        let waiting = Self.job("a", "waiting"), running = Self.job("b", "running"), failed = Self.job("c", "failed")
        #expect(RecipeImports.finished(before: [waiting, running], after: [running]))
        #expect(!RecipeImports.finished(before: [waiting], after: [Self.job("a", "running")]))
        // Failing isn't finishing, nor is removing a failed one.
        #expect(!RecipeImports.finished(before: [waiting], after: [Self.job("a", "failed")]))
        #expect(!RecipeImports.finished(before: [failed], after: []))
        #expect(!RecipeImports.finished(before: [], after: [waiting]))
    }

    @Test func decodesTheList() throws {
        let data = Data("""
        {"imports":[{"id":"i1","url":"https://www.example.com/pasta","title":"","imageUrl":"https://example.com/p.jpg",\
        "status":"failed","error":"No recipe found","createdAt":"2026-11-02T10:00:00.000Z"}]}
        """.utf8)
        let answer = try APIClient.decoder.decode(RecipeImports.Answer.self, from: data)
        let job = try #require(answer.imports.first)
        #expect(job.isFailed && job.error == "No recipe found")
        #expect(job.displayTitle == "www.example.com")
        #expect(Self.job("x", "waiting", title: " Pasta ").displayTitle == "Pasta")
    }

    @Test func linksOpenTheRecipeOrWantToTry() throws {
        let recipe = try #require(AppRoute.parse(webPath: "/f/fam/meals/recipes/r1"))
        #expect(recipe.familyID == "fam" && recipe.route == .recipe(id: "r1"))
        let list = try #require(AppRoute.parse(webPath: "/f/fam/meals/recipes"))
        #expect(list.route == .recipeList(.toTry))
        let routing = try #require(MealsRouting(list.route))
        #expect(routing.segment == .recipes && routing.recipeList == .toTry && routing.destination == nil)
    }
}

import Foundation
import Testing
@testable import Ohana

/// What Meals does with the module's routes (`MealsRouting`), also from web links.
struct MealsRoutingTests {
    @Test func opensTheRightPart() throws {
        #expect(MealsRouting(.mealPlan)?.segment == .plan)
        #expect(MealsRouting(.mealTags)?.segment == .tags)
        let bare = try #require(MealsRouting(.module(.meals)))
        #expect(bare.segment == nil && bare.destination == nil && !bare.createsRecipe)
        #expect(MealsRouting(.module(.finance)) == nil)
        #expect(MealsRouting(.settings(.finance)) == nil)
    }

    @Test func pushesARecipeOrTheCookView() throws {
        let recipe = try #require(MealsRouting(.recipe(id: "r1")))
        #expect(recipe.segment == .recipes)
        #expect(recipe.destination == .recipe(id: "r1"))
        let cook = try #require(MealsRouting(.cook(recipeID: "r1")))
        #expect(cook.segment == nil) // stays where it is
        #expect(cook.destination == .cook(recipeID: "r1"))
    }

    @Test func opensTheNewRecipeEditor() throws {
        let route = try #require(MealsRouting(.newRecipe))
        #expect(route.segment == .recipes)
        #expect(route.createsRecipe)
        #expect(route.destination == nil)
    }

    @Test func followsWebLinks() throws {
        func routing(_ path: String) -> MealsRouting? {
            AppRoute.parse(webPath: path).flatMap { MealsRouting($0.route) }
        }
        #expect(routing("/f/fam/meals/recipes/r9")?.destination == .recipe(id: "r9"))
        #expect(routing("/f/fam/meals/recipes/new")?.createsRecipe == true)
        #expect(routing("/f/fam/meals/cook/r9")?.destination == .cook(recipeID: "r9"))
        #expect(routing("/f/fam/meals/shopping/l1")?.segment == .plan)
        #expect(routing("/f/fam/meals/plan")?.segment == .plan)
        #expect(routing("/f/fam/meals")?.segment == nil)
    }

    @Test func showsTheWelcomeToEditorsWithoutRecipes() throws {
        let none = try APIClient.decoder.decode(MealsAIStatus.self, from: Data(#"{"generate":true,"photos":false,"recipeCount":0}"#.utf8))
        #expect(none.showsWelcome(canEdit: true))
        #expect(!none.showsWelcome(canEdit: false))
        let some = try APIClient.decoder.decode(MealsAIStatus.self, from: Data(#"{"generate":true,"photos":false,"recipeCount":3}"#.utf8))
        #expect(!some.showsWelcome(canEdit: true))
        // An older server doesn't say: no welcome.
        let old = try APIClient.decoder.decode(MealsAIStatus.self, from: Data(#"{"generate":false,"photos":false}"#.utf8))
        #expect(old.recipeCount == nil)
        #expect(!old.showsWelcome(canEdit: true))
    }
}

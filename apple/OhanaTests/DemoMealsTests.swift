import Foundation
import Testing
@testable import Ohana

/// The demo's meals: what the recipe, plan and shopping screens GET, decoded into their models.
struct DemoMealsTests {
    private let today = Day("2026-10-30")!

    private static let recipeIDs = ["recipe-lasagne", "recipe-curry", "recipe-pancakes", "recipe-soup", "recipe-salmon",
                                    "recipe-risotto", "recipe-tacos", "recipe-salad"]

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], as type: T.Type) throws -> T {
        var server = DemoServer()
        let day = today
        server.today = { day }
        server.now = { day.date }
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo" + path)
        if !query.isEmpty {
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        let (data, response) = server.respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200, "\(path)")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    @Test func statusTagsAndCatalog() throws {
        let status = try get("/meals/status", as: MealsAIStatus.self)
        #expect(status.recipeCount == 8)
        #expect(!status.showsWelcome(canEdit: false))
        let tags = try get("/meals/tags", as: RecipeTagsResponse.self).tags
        #expect(Set(tags.map(\.category)) == Set(RecipeTagCategory.allCases.map(\.rawValue)))
        #expect(tags.contains { $0.id == "tag-vegetarian" && $0.nameDe == "Vegetarisch" })
        let catalog = try get("/meals/catalog", as: RecipeCatalog.self)
        #expect(catalog.units.map(\.abbreviation) == ["g", "kg", "ml", "l", "Stk", "EL", "TL", "Prise"])
        #expect(catalog.ingredients.contains { $0.nameEn == "lasagne sheets" })
        #expect(Set(catalog.ingredients.map(\.id)).count == catalog.ingredients.count)
    }

    @Test func theRecipeListFiltersSortsAndPages() throws {
        func page(_ query: [String: String]) throws -> RecipeListPage {
            try get("/meals/recipes", query.merging(["locale": "en"]) { a, _ in a }, as: RecipeListPage.self)
        }
        let known = try page(["list": "KNOWN", "sort": "name-asc", "offset": "0", "limit": "30"])
        #expect(known.items.map(\.title) == ["Chickpea curry", "Greek salad", "Lemon salmon with potatoes", "Pancakes",
                                             "Tomato soup", "Vegetable lasagne"])
        #expect(known.items.allSatisfy { $0.imagePath == nil && $0.listType == "KNOWN" })
        let toTry = try page(["list": "TO_TRY"])
        #expect(Set(toTry.items.map(\.id)) == ["recipe-risotto", "recipe-tacos"])

        #expect(try page(["list": "KNOWN", "q": "LASAG"]).items.map(\.id) == ["recipe-lasagne"])
        let vegan = try page(["list": "KNOWN", "tags": "tag-vegan"])
        #expect(Set(vegan.items.map(\.id)) == ["recipe-curry", "recipe-soup"])
        #expect(try page(["list": "KNOWN", "sort": "name-desc"]).items.first?.id == "recipe-lasagne")
        #expect(try page(["list": "TO_TRY", "sort": "newest"]).items.first?.id == "recipe-tacos")

        let first = try page(["list": "KNOWN", "offset": "0", "limit": "4"])
        let second = try page(["list": "KNOWN", "offset": "4", "limit": "4"])
        #expect(first.totalCount == 6 && second.totalCount == 6)
        #expect(first.items.count == 4 && second.items.count == 2)

        // The plan's swap sheet: every recipe, in the web's GET /recipes shape.
        let all = try get("/recipes", ["limit": "100", "offset": "0", "locale": "en"], as: MealPlanRecipePage.self)
        #expect(all.totalCount == 8)
        #expect(Set(all.items.map(\.id)) == Set(Self.recipeIDs))
    }

    @Test func everyRecipeHasItsIngredientsAndSteps() throws {
        for id in Self.recipeIDs {
            let response = try get("/meals/recipes/\(id)", as: RecipeDetailResponse.self)
            let recipe = RecipeResolved(response)
            #expect(response.recipe.id == id)
            #expect(response.recipe.imagePath == nil)
            #expect(response.recipe.ingredients.count >= 8, "\(id)")
            #expect(response.recipe.manualSteps.count >= 3, "\(id)")
            // Every ingredient and unit resolves to a name.
            #expect(recipe.lines(servings: 4).allSatisfy { $0.name != "?" && !$0.unit.isEmpty }, "\(id)")
            // Step ingredients point at the recipe's own and don't add up to more than it has.
            let ids = Set(response.recipe.ingredients.map(\.id))
            for step in response.recipe.manualSteps {
                #expect(step.ingredients.allSatisfy { ids.contains($0.recipeIngredientId) })
            }
            let orders = Dictionary(uniqueKeysWithValues: response.recipe.ingredients.map { ($0.id, $0.order) })
            let over = RecipeValidation.overAllocated(
                ingredients: response.recipe.ingredients.map { ($0.order, $0.quantity) },
                steps: response.recipe.manualSteps.flatMap(\.ingredients).map { (orders[$0.recipeIngredientId]!, $0.quantity) })
            #expect(over.isEmpty, "\(id)")
        }
        let lasagne = RecipeResolved(try get("/meals/recipes/recipe-lasagne", as: RecipeDetailResponse.self))
        #expect(lasagne.detail.title == "Vegetable lasagne")
        #expect(lasagne.lines(servings: 4).first.map { "\($0.quantity) \($0.unit) \($0.name)" } == "250 g lasagne sheets")
    }

    @Test func thePlanHasLasagneTodayAndTheShoppingDays() throws {
        let response = try get("/meals/plan", as: MealPlanResponse.self)
        let plan = try #require(response.plan)
        // Tomorrow (Saturday) and in 4 days (Tuesday).
        #expect(plan.shoppingDays == [1, 5])
        #expect(MealPlanWeekday.validShoppingDays(plan.shoppingDays))
        let active = try #require(plan.activeIteration)
        #expect(!plan.activeEnded(today: today))
        let rows = active.dayRows(away: response.away)
        #expect(rows.count == 7)
        #expect(rows.first { $0.day == today }?.entry?.recipeTitle == "Vegetable lasagne")
        #expect(rows.filter(\.isShoppingDay).map(\.day) == [today.adding(days: 1), today.adding(days: 4)])
        #expect(plan.pastIterations.map(\.id) == ["iteration-1"])
        let past = plan.pastIterations[0].dayRows(away: response.away)
        #expect(past.filter(\.isShoppingDay).map(\.day) == [today.adding(days: -3)])
        // Leftovers point at their cooking day.
        let entries = plan.iterations.flatMap(\.entries)
        for leftover in entries where leftover.isLeftover {
            #expect(entries.first { $0.id == leftover.sourceEntryId }?.recipeId == leftover.recipeId)
        }
        #expect(!response.tags.isEmpty)
    }

    @Test func whatThePlanNeedsByShoppingDay() throws {
        let needs = try get("/meals/shopping", ["lang": "en", "from": today.description], as: ShoppingNeeds.self)
        #expect(needs.days.map(\.date) == [today.adding(days: 1), today.adding(days: 4)])
        #expect(needs.days.map(\.items.count) == [12, 19])
        for day in needs.days {
            #expect(day.items.map(\.name) == day.items.map(\.name).sorted())
            #expect(Set(day.items.map(\.key)).count == day.items.count)
        }
        let cod = try #require(needs.days[0].items.first { $0.name == "Cod fillet" })
        #expect(cod.label(locale: Locale(identifier: "en")) == "500 g Cod fillet")

        let german = try get("/meals/shopping", ["lang": "de"], as: ShoppingNeeds.self)
        #expect(german.days[0].items.contains { $0.name == "Kabeljaufilet" })
        // From a later day on, the earlier ones are left out.
        let later = try get("/meals/shopping", ["from": today.adding(days: 2).description], as: ShoppingNeeds.self)
        #expect(later.days.map(\.date) == [today.adding(days: 4)])
    }
}

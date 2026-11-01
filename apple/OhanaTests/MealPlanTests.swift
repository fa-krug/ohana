import Foundation
import Testing
@testable import Ohana

struct MealPlanTests {
    /// GET /meals/plan as server/lib/meals/app-routes-plan.ts answers it (trimmed).
    static let planJSON = """
    {"plan":{"id":"3516752d","iterationWeeks":1,"shoppingDays":[0,3],"servings":2,"knownRatio":"1","defaultLeftoverDays":0,"excludedTagIds":[],"iterations":[{"id":"it-2","startDate":"2026-11-01","endDate":"2026-11-07","status":"ACTIVE","entries":[{"id":"e1","date":"2026-11-01","mealType":"LUNCH","recipeId":"r2","recipeTitle":"Recipe 2","servings":2,"isLeftover":false,"sourceEntryId":null,"isLocked":false},{"id":"e2","date":"2026-11-02","mealType":"LUNCH","recipeId":"r2","recipeTitle":"Recipe 2","servings":2,"isLeftover":true,"sourceEntryId":"e1","isLocked":false}],"shoppingDates":["2026-11-02","2026-11-05"],"createdAt":"2026-11-01T12:00:00.000Z"},{"id":"it-1","startDate":"2026-10-25","endDate":"2026-10-31","status":"ARCHIVED","entries":[],"shoppingDates":[],"createdAt":"2026-10-25T12:00:00.000Z"}],"createdAt":"2026-11-01T12:00:00.000Z"},"away":{"2026-11-05":["Vacation"]},"tags":[{"id":"t1","category":"CUISINE","nameEn":"American","nameDe":"Amerikanisch"}]}
    """

    static func decodePlan() throws -> MealPlanResponse {
        try JSONDecoder().decode(MealPlanResponse.self, from: Data(planJSON.utf8))
    }

    @Test func decodesThePlan() throws {
        let response = try Self.decodePlan()
        let plan = try #require(response.plan)
        #expect(plan.shoppingDays == [0, 3])
        #expect(plan.knownRatioValue == 1)
        #expect(plan.iterations.count == 2)
        #expect(plan.activeIteration?.id == "it-2")
        #expect(plan.pastIterations.map(\.id) == ["it-1"])
        let leftover = plan.iterations[0].entries[1]
        #expect(leftover.isLeftover && leftover.sourceEntryId == "e1" && leftover.date == Day("2026-11-02"))
        #expect(plan.iterations[0].shoppingDates == [Day("2026-11-02")!, Day("2026-11-05")!])
        #expect(response.away["2026-11-05"] == ["Vacation"])
        #expect(response.tags.first?.nameDe == "Amerikanisch")
        #expect(plan.recipeIDs(in: "it-2") == ["r2"])
    }

    @Test func decodesAFamilyWithoutPlan() throws {
        let json = #"{"plan":null,"away":{},"tags":[]}"#
        let response = try JSONDecoder().decode(MealPlanResponse.self, from: Data(json.utf8))
        #expect(response.plan == nil)
    }

    @Test func decodesAChangeWithItsUndo() throws {
        let json = #"{"iterationId":"it-2","undo":{"restore":[{"id":"it-2","entries":[]}],"remove":[]}}"#
        let result = try JSONDecoder().decode(MealPlanChangeResult.self, from: Data(json.utf8))
        #expect(result.iterationId == "it-2")
        #expect(result.undo?["restore"]?.arrayValue?.first?["id"]?.stringValue == "it-2")
        let setup = try JSONDecoder().decode(MealPlanChangeResult.self, from: Data(#"{"iterationId":"x"}"#.utf8))
        #expect(setup.undo == nil)
    }

    @Test func buildsTheDaysOfAnIteration() throws {
        let response = try Self.decodePlan()
        let plan = try #require(response.plan)
        let rows = plan.iterations[0].dayRows(away: response.away)
        #expect(rows.count == 7)
        #expect(rows.first?.day == Day("2026-11-01"))
        #expect(rows.last?.day == Day("2026-11-07"))
        // Monday 2 Nov and Thursday 5 Nov are the iteration's shopping days.
        #expect(rows.filter(\.isShoppingDay).map(\.day.description) == ["2026-11-02", "2026-11-05"])
        #expect(rows[0].entry?.id == "e1")
        #expect(rows[1].entry?.isLeftover == true)
        // Away and nothing planned.
        #expect(rows[4].isAway && rows[4].awayTypes == ["Vacation"])
        #expect(!rows[0].isAway)
    }

    @Test func countsWeekdaysFromMonday() {
        #expect(MealPlanWeekday.index(of: Day("2026-11-02")!) == 0) // Monday
        #expect(MealPlanWeekday.index(of: Day("2026-11-05")!) == 3) // Thursday
        #expect(MealPlanWeekday.index(of: Day("2026-11-01")!) == 6) // Sunday
        #expect(MealPlanWeekday.shortNames.count == 7)
    }

    @Test func checksShoppingDaysLikeTheServer() {
        #expect(MealPlanWeekday.validShoppingDays([5]))
        #expect(MealPlanWeekday.validShoppingDays([0, 3]))
        #expect(MealPlanWeekday.validShoppingDays([1, 5])) // 4 apart, 3 around the week
        #expect(!MealPlanWeekday.validShoppingDays([]))
        #expect(!MealPlanWeekday.validShoppingDays([0, 1]))
        #expect(!MealPlanWeekday.validShoppingDays([0, 6])) // Monday and Sunday are 1 day apart
        #expect(!MealPlanWeekday.validShoppingDays([0, 3, 5]))
    }

    @Test func knowsWhenTheActiveIterationEnded() throws {
        let plan = try #require(try Self.decodePlan().plan)
        #expect(!plan.activeEnded(today: Day("2026-11-07")!))
        #expect(plan.activeEnded(today: Day("2026-11-08")!))
    }

    @Test func setupStartsFromThePlan() throws {
        let plan = try #require(try Self.decodePlan().plan)
        let input = MealPlanSetupInput(plan: plan)
        #expect(input == MealPlanSetupInput(iterationWeeks: 1, shoppingDays: [0, 3], servings: 2, knownRatio: 1,
                                            defaultLeftoverDays: 0, excludedTagIds: []))
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MealPlanSetupInput.initial)) as? [String: Any]
        #expect(body?["shoppingDays"] as? [Int] == [5])
        #expect(body?["knownRatio"] as? Double == 0.7)
    }

    @Test func decidesWhatADropDoes() throws {
        let response = try Self.decodePlan()
        let plan = try #require(response.plan)
        let iteration = plan.iterations[0]
        let rows = iteration.dayRows(away: response.away)
        let recipe = MealDragItem(familyID: "f1", recipeID: "r9", title: "Soup")
        // A recipe onto a day with a lunch replaces it; onto an empty or away day adds it.
        #expect(MealPlanDrop(recipe, onto: rows[1], of: iteration, familyID: "f1")
            == .replace(entryID: "e2", recipeID: "r9", title: "Soup"))
        #expect(MealPlanDrop(recipe, onto: rows[2], of: iteration, familyID: "f1")
            == .add(iterationID: "it-2", date: Day("2026-11-03")!, recipeID: "r9", title: "Soup"))
        #expect(MealPlanDrop(recipe, onto: rows[4], of: iteration, familyID: "f1")
            == .add(iterationID: "it-2", date: Day("2026-11-05")!, recipeID: "r9", title: "Soup"))
        // The recipe the day has already, or another family's: nothing.
        let same = MealDragItem(familyID: "f1", recipeID: "r2", title: "Recipe 2")
        #expect(MealPlanDrop(same, onto: rows[0], of: iteration, familyID: "f1") == nil)
        #expect(MealPlanDrop(recipe, onto: rows[0], of: iteration, familyID: "f2") == nil)
    }

    @Test func movesAMealWithinItsIteration() throws {
        let response = try Self.decodePlan()
        let plan = try #require(response.plan)
        let iteration = plan.iterations[0]
        let rows = iteration.dayRows(away: response.away)
        let meal = MealDragItem(familyID: "f1", recipeID: "r2", title: "Recipe 2", entryID: "e1")
        // Onto a day with a lunch: the two swap; onto an empty day: it moves.
        #expect(MealPlanDrop(meal, onto: rows[1], of: iteration, familyID: "f1")
            == .move(entryID: "e1", date: Day("2026-11-02")!, title: "Recipe 2", swapped: true))
        #expect(MealPlanDrop(meal, onto: rows[3], of: iteration, familyID: "f1")
            == .move(entryID: "e1", date: Day("2026-11-04")!, title: "Recipe 2", swapped: false))
        // Its own day, or a day of another iteration: nothing.
        #expect(MealPlanDrop(meal, onto: rows[0], of: iteration, familyID: "f1") == nil)
        let past = plan.iterations[1]
        let pastRows = past.dayRows(away: response.away)
        #expect(MealPlanDrop(meal, onto: pastRows[0], of: past, familyID: "f1") == nil)
    }

    @Test func filtersRecipesByTitle() throws {
        let json = #"{"items":[{"id":"a","title":"Tomato Soup","listType":"KNOWN","image":"","leftoverDays":null},{"id":"b","title":"Pasta","listType":"TO_TRY","image":"b.webp","leftoverDays":1}],"totalCount":2}"#
        let page = try JSONDecoder().decode(MealPlanRecipePage.self, from: Data(json.utf8))
        #expect(page.items.matching(" ").map(\.id) == ["a", "b"])
        #expect(page.items.matching("soup").map(\.id) == ["a"])
        #expect(page.items[0].isFavourite && !page.items[1].isFavourite)
        #expect(page.items[1].imagePath == "/api/images/b.webp")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            MealPlanAddInput(date: Day("2026-11-03")!, recipeId: "a"))) as? [String: String]
        #expect(body == ["date": "2026-11-03", "recipeId": "a"])
    }
}

import Foundation
import Testing
@testable import Ohana

struct MealPlanTests {
    /// GET /meals/plan as web/lib/meals/app-routes-plan.ts answers it (trimmed).
    static let planJSON = """
    {"plan":{"id":"3516752d","iterationWeeks":1,"shoppingDays":[0,3],"servings":2,"knownRatio":"1","defaultLeftoverDays":0,"excludedTagIds":[],"iterations":[{"id":"it-2","startDate":"2026-11-01","endDate":"2026-11-07","status":"ACTIVE","entries":[{"id":"e1","date":"2026-11-01","mealType":"LUNCH","recipeId":"r2","recipeTitle":"Recipe 2","servings":2,"isLeftover":false,"sourceEntryId":null,"isLocked":false},{"id":"e2","date":"2026-11-02","mealType":"LUNCH","recipeId":"r2","recipeTitle":"Recipe 2","servings":2,"isLeftover":true,"sourceEntryId":"e1","isLocked":false}],"shoppingLists":[{"id":"l2","shoppingDate":"2026-11-05","itemCount":3},{"id":"l1","shoppingDate":"2026-11-02","itemCount":4}],"createdAt":"2026-11-01T12:00:00.000Z"},{"id":"it-1","startDate":"2026-10-25","endDate":"2026-10-31","status":"ARCHIVED","entries":[],"shoppingLists":[],"createdAt":"2026-10-25T12:00:00.000Z"}],"createdAt":"2026-11-01T12:00:00.000Z"},"away":{"2026-11-05":["Vacation"]},"tags":[{"id":"t1","category":"CUISINE","nameEn":"American","nameDe":"Amerikanisch"}]}
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
        #expect(plan.iterations[0].shoppingLists[1].shoppingDate == Day("2026-11-02"))
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
        let rows = plan.iterations[0].dayRows(shoppingDays: plan.shoppingDays, away: response.away)
        #expect(rows.count == 7)
        #expect(rows.first?.day == Day("2026-11-01"))
        #expect(rows.last?.day == Day("2026-11-07"))
        // Monday 2 Nov and Thursday 5 Nov are the shopping days, with their lists.
        #expect(rows.filter(\.isShoppingDay).map(\.day.description) == ["2026-11-02", "2026-11-05"])
        #expect(rows[1].shoppingList?.id == "l1")
        #expect(rows[4].shoppingList?.id == "l2")
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
}

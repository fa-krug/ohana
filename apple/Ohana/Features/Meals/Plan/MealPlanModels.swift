import Foundation

// The meal plan as the server sends it: GET /meals/plan (server/lib/meals/app-routes-plan.ts,
// `getMealPlanView` in server/lib/meals/queries/meal-plan.ts, `awayDays`, `listTags`).

/// GET /meals/plan
struct MealPlanResponse: Codable {
    /// Null until the family sets up a plan.
    let plan: MealPlanDTO?
    /// Day ("YYYY-MM-DD") → the calendar types that make the whole family away that day.
    let away: [String: [String]]
    /// The family's meal tags, for "Exclude tags" in the setup form.
    let tags: [MealPlanTag]
}

/// `MealPlanView` (web): the family's one plan with its settings and iterations.
struct MealPlanDTO: Codable {
    let id: String
    let iterationWeeks: Int
    /// Weekdays, Monday = 0 … Sunday = 6.
    let shoppingDays: [Int]
    let servings: Int
    /// A decimal string, e.g. "0.7".
    let knownRatio: String
    let defaultLeftoverDays: Int
    let excludedTagIds: [String]
    /// The active iteration first, then by start day, newest first.
    let iterations: [MealPlanIteration]
    let createdAt: String?

    var knownRatioValue: Double { Double(knownRatio) ?? 0.7 }
}

struct MealPlanIteration: Codable, Identifiable, Hashable {
    let id: String
    let startDate: Day
    let endDate: Day
    /// ACTIVE | ARCHIVED
    let status: String
    let entries: [MealPlanEntry]
    /// The iteration's shopping days (what each needs: GET /meals/shopping, into Reminders).
    let shoppingDates: [Day]
    let createdAt: String?

    var isActive: Bool { status == "ACTIVE" }
}

struct MealPlanEntry: Codable, Identifiable, Hashable {
    let id: String
    let date: Day
    /// LUNCH (the plan only plans lunch; dinner is "something light").
    let mealType: String
    let recipeId: String
    let recipeTitle: String
    let servings: Int
    let isLeftover: Bool
    let sourceEntryId: String?
    let isLocked: Bool
}

struct MealPlanTag: Codable, Identifiable, Hashable {
    let id: String
    let category: String
    let nameEn: String
    let nameDe: String

    var name: String { MealPlanLanguage.current == "de" ? nameDe : nameEn }
}

/// POST /meals/plan/setup (the web's `setupPlanSchema`).
struct MealPlanSetupInput: Codable, Equatable {
    var iterationWeeks: Int
    var shoppingDays: [Int]
    var servings: Int
    var knownRatio: Double
    var defaultLeftoverDays: Int
    var excludedTagIds: [String]

    /// The web form's defaults for a new plan.
    static let initial = MealPlanSetupInput(iterationWeeks: 1, shoppingDays: [5], servings: 2, knownRatio: 0.7,
                                            defaultLeftoverDays: 1, excludedTagIds: [])

    init(iterationWeeks: Int, shoppingDays: [Int], servings: Int, knownRatio: Double, defaultLeftoverDays: Int,
         excludedTagIds: [String]) {
        self.iterationWeeks = iterationWeeks
        self.shoppingDays = shoppingDays
        self.servings = servings
        self.knownRatio = knownRatio
        self.defaultLeftoverDays = defaultLeftoverDays
        self.excludedTagIds = excludedTagIds
    }

    init(plan: MealPlanDTO) {
        self.init(iterationWeeks: plan.iterationWeeks, shoppingDays: plan.shoppingDays, servings: plan.servings,
                  knownRatio: plan.knownRatioValue, defaultLeftoverDays: plan.defaultLeftoverDays,
                  excludedTagIds: plan.excludedTagIds)
    }
}

/// POST /meals/plan/setup answers `{iterationId}`; next, renew, swap and remove add `undo`, the
/// body for POST /meals/plan/restore that puts the plan back.
struct MealPlanChangeResult: Codable {
    let iterationId: String
    let undo: JSONValue?
}

/// PATCH /meals/plan/entries/{id}
struct MealPlanSwapInput: Codable {
    let recipeId: String
}

/// POST /meals/plan/iterations/{id}/entries: a recipe on a day of the iteration without a lunch.
struct MealPlanAddInput: Codable {
    let date: Day
    let recipeId: String
}

/// POST /meals/plan/entries/{id}/move: the meal onto another day of its iteration (swapping).
struct MealPlanMoveInput: Codable {
    let date: Day
}

/// A page of GET /recipes (server/lib/meals/queries/recipes.ts `RecipeListResult`), for swapping.
struct MealPlanRecipePage: Codable {
    let items: [MealPlanRecipeOption]
    let totalCount: Int
}

struct MealPlanRecipeOption: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    /// KNOWN | TO_TRY
    let listType: String
    let image: String
    let leftoverDays: Int?

    /// The photo's server path, if there is one.
    var imagePath: String? { image.isEmpty ? nil : "/api/images/\(image)" }

    var isFavourite: Bool { listType == "KNOWN" }
}

extension [MealPlanRecipeOption] {
    /// The recipes whose title contains `query` (all of them for a blank one).
    func matching(_ query: String) -> [MealPlanRecipeOption] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? self : filter { $0.title.localizedStandardContains(q) }
    }
}

/// What dropping a `MealDragItem` onto a day of an iteration does.
enum MealPlanDrop: Equatable {
    /// A recipe onto a day with a lunch: PATCH /meals/plan/entries/{entryID}.
    case replace(entryID: String, recipeID: String, title: String)
    /// A recipe onto a day without one (empty or away): POST /meals/plan/iterations/{id}/entries.
    case add(iterationID: String, date: Day, recipeID: String, title: String)
    /// A planned meal onto another day of its iteration: POST /meals/plan/entries/{entryID}/move;
    /// `swapped`: that day has a lunch, which takes the meal's day.
    case move(entryID: String, date: Day, title: String, swapped: Bool)

    /// Nil when the drop changes nothing or isn't allowed: another family's item, a meal onto
    /// its own day or onto another iteration, a recipe onto a day that has it already.
    init?(_ item: MealDragItem, onto row: MealPlanDayRow, of iteration: MealPlanIteration, familyID: String) {
        guard item.familyID == familyID else { return nil }
        if let entryID = item.entryID {
            guard let entry = iteration.entries.first(where: { $0.id == entryID }), entry.date != row.day else {
                return nil
            }
            self = .move(entryID: entryID, date: row.day, title: item.title, swapped: row.entry != nil)
        } else if let target = row.entry {
            guard target.recipeId != item.recipeID else { return nil }
            self = .replace(entryID: target.id, recipeID: item.recipeID, title: item.title)
        } else {
            self = .add(iterationID: iteration.id, date: row.day, recipeID: item.recipeID, title: item.title)
        }
    }
}

/// The family's recipes for planning: GET /recipes, every page.
enum MealPlanRecipes {
    static func load(_ api: FamilyAPI) async throws -> [MealPlanRecipeOption] {
        var all: [MealPlanRecipeOption] = []
        var offset = 0
        while true {
            let page: MealPlanRecipePage = try await api.get("/recipes", query: [
                "limit": "100", "offset": "\(offset)", "locale": MealPlanLanguage.current,
            ])
            all += page.items
            offset += page.items.count
            if page.items.isEmpty || offset >= page.totalCount { break }
        }
        return all
    }
}

// MARK: Logic of the plan page

/// The language of names the server picks (tags, shopping items): the app's own.
enum MealPlanLanguage {
    static var current: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true ? "de" : "en"
    }
}

enum MealPlanWeekday {
    private static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The server's weekday of a day: Monday = 0 … Sunday = 6 (Python's `date.weekday()`).
    static func index(of day: Day) -> Int {
        let date = gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return (gregorian.component(.weekday, from: date) + 5) % 7
    }

    /// Short weekday names, Monday first (the user's language).
    static var shortNames: [String] {
        let symbols = Calendar.current.shortWeekdaySymbols // Sunday first
        return (0..<7).map { symbols[($0 + 1) % 7] }
    }

    /// The web's `validateShoppingDays`: one or two days, two at least 3 days apart (around the week).
    static func validShoppingDays(_ days: [Int]) -> Bool {
        guard (1...2).contains(days.count), days.allSatisfy({ (0...6).contains($0) }) else { return false }
        guard days.count == 2 else { return true }
        let gap = abs(days[0] - days[1])
        return min(gap, 7 - gap) >= 3
    }
}

/// One day of an iteration as the plan page shows it.
struct MealPlanDayRow: Identifiable, Hashable {
    let day: Day
    /// The day's lunch.
    let entry: MealPlanEntry?
    let isShoppingDay: Bool
    /// The calendar types that make the family away, if it is.
    let awayTypes: [String]?

    var id: Day { day }
    /// Away and nothing planned: shown instead of the meals.
    var isAway: Bool { awayTypes != nil && entry == nil }
}

extension MealPlanIteration {
    /// Every day from start to end with its lunch, whether it's one of the iteration's shopping
    /// days, and its away types.
    func dayRows(away: [String: [String]]) -> [MealPlanDayRow] {
        let lunches = Dictionary(entries.filter { $0.mealType == "LUNCH" }.map { ($0.date, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let dates = Set(shoppingDates)
        var rows: [MealPlanDayRow] = []
        var day = startDate
        while day <= endDate {
            let isShoppingDay = dates.contains(day)
            rows.append(MealPlanDayRow(
                day: day,
                entry: lunches[day],
                isShoppingDay: isShoppingDay,
                awayTypes: away[day.description]
            ))
            day = day.adding(days: 1)
        }
        return rows
    }
}

extension MealPlanDTO {
    var activeIteration: MealPlanIteration? { iterations.first(where: \.isActive) }

    /// Every iteration but the active one (newest first, as the server sorts them).
    var pastIterations: [MealPlanIteration] {
        let active = activeIteration?.id
        return iterations.filter { $0.id != active }
    }

    /// The active iteration is over: time for the next one.
    func activeEnded(today: Day) -> Bool {
        guard let active = activeIteration else { return false }
        return active.endDate < today
    }

    /// The recipes the iteration plans already (for swapping in something else).
    func recipeIDs(in iterationID: String) -> Set<String> {
        Set(iterations.first { $0.id == iterationID }?.entries.map(\.recipeId) ?? [])
    }
}

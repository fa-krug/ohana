import Foundation

extension DemoServer {
    /// The demo's meals routes that depend on the query; the rest are files
    /// (`demo-meals-status.json`, `-tags`, `-catalog`, `-recipes-recipe-<slug>`).
    static func meals(_ request: Request) -> JSONValue? {
        guard let path = request.familyPath else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        switch parts {
        case ["meals", "recipes"], ["recipes"]:
            // The recipe list (and the plan's swap sheet, the web's GET /recipes).
            return recipePage(request)
        case ["meals", "plan"]:
            return mealPlan(request)
        case ["meals", "shopping"]:
            return shoppingItems(request)
        default:
            return nil
        }
    }

    /// GET /meals/recipes `?list&q&sort&locale&tags&offset&limit` → {items, totalCount}, like
    /// server/lib/meals/queries/recipes.ts `listRecipes`.
    private static func recipePage(_ request: Request) -> JSONValue? {
        guard var items = request.json("meals-recipes")?["items"]?.arrayValue else { return nil }
        let q = request.query
        if let list = q["list"], !list.isEmpty {
            items = items.filter { $0["listType"]?.stringValue == list }
        }
        let tagIDs = Set((q["tags"] ?? "").split(separator: ",").map(String.init))
        if !tagIDs.isEmpty {
            items = items.filter { recipe in
                (recipe["tags"]?.arrayValue ?? []).contains { tagIDs.contains($0["id"]?.stringValue ?? "") }
            }
        }
        func field(_ recipe: JSONValue, _ key: String) -> String { recipe[key]?.stringValue ?? "" }
        let search = (q["q"] ?? "").trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            items = items.filter {
                field($0, "title").range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        switch q["sort"] ?? "name-asc" {
        case "name-desc": items.sort { field($0, "title").localizedCompare(field($1, "title")) == .orderedDescending }
        case "newest": items.sort { field($0, "createdAt") > field($1, "createdAt") }
        case "updated": items.sort { field($0, "updatedAt") > field($1, "updatedAt") }
        default: items.sort { field($0, "title").localizedCompare(field($1, "title")) == .orderedAscending }
        }
        let offset = max(0, Int(q["offset"] ?? "") ?? 0)
        let limit = min(100, max(1, Int(q["limit"] ?? "") ?? 20))
        let page = offset < items.count ? Array(items[offset..<min(items.count, offset + limit)]) : []
        return .object(["items": .array(page), "totalCount": .number(Double(items.count))])
    }

    /// GET /meals/plan with the shopping weekdays of the demo's lists (tomorrow and in 4 days;
    /// Monday = 0).
    private static func mealPlan(_ request: Request) -> JSONValue? {
        guard var response = request.json("meals-plan")?.objectValue,
              var plan = response["plan"]?.objectValue else { return nil }
        let days = [1, 4].map { MealPlanWeekday.index(of: request.today.adding(days: $0)) }.sorted()
        plan["shoppingDays"] = .array(days.map { .number(Double($0)) })
        response["plan"] = .object(plan)
        return .object(response)
    }

    /// GET /meals/shopping `?lang&from`: what the plan needs per shopping day from `from` (default
    /// today) on, the items' names in the asked language and in alphabetical order, like the
    /// server's (server/lib/meals/queries/shopping.ts).
    private static func shoppingItems(_ request: Request) -> JSONValue? {
        guard let days = request.json("meals-shopping")?["days"]?.arrayValue else { return nil }
        let german = (request.query["lang"] ?? "").lowercased().hasPrefix("de")
        let from = request.query["from"].flatMap { Day($0) } ?? request.today
        func name(_ item: JSONValue) -> String { item["name"]?.stringValue ?? "" }
        let shown: [JSONValue] = days.compactMap { day in
            guard var day = day.objectValue, let date = day["date"]?.stringValue.flatMap({ Day($0) }),
                  date >= from else { return nil }
            let items: [JSONValue] = (day["items"]?.arrayValue ?? []).compactMap { item in
                guard var item = item.objectValue else { return nil }
                if german, let name = item["nameDe"] { item["name"] = name }
                item["nameDe"] = nil
                return .object(item)
            }
            day["items"] = .array(items.sorted { name($0).localizedCompare(name($1)) == .orderedAscending })
            return .object(day)
        }
        return .object(["days": .array(shown)])
    }
}

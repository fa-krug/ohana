import Foundation

/// Where the app shows what a tool call was about: the recipe it saved or read, the calendar day
/// it changed, the appointment slot it booked, the meal plan, the finance category (the
/// result shapes of server/lib/assistant/tools/*). The chat makes such a call's row tappable.
enum AssistantToolLinks {
    /// The route of a successful tool call, or nil when there is nothing to show.
    static func route(_ tool: AssistantToolCall, familyID: String) -> AppRoute? {
        guard tool.status == "ok" else { return nil }
        let a = tool.args
        let r = object(tool.result)
        /// A string field of the result; a result cut short (the chat keeps 2,000 characters of
        /// it) is searched as text.
        func field(_ key: String) -> String? {
            if let r { return text(r[key]) }
            return raw(key, in: tool.result)
        }

        switch tool.name {
        case "save_recipe", "get_recipe":
            if let id = field("id") { return .recipe(id: id) }
        case "add_event":
            if let day = Day(field("date") ?? text(a["date"]) ?? "") { return .calendarDay(day) }
        case "change_entries", "set_notes":
            if let day = firstDay(ops: a["ops"]) { return .calendarDay(day) }
        case "book_appointment_slot":
            let event = r?["event"]?.objectValue
            if let search = text(event?["searchId"]) ?? raw("searchId", in: tool.result),
               let result = number(a["resultId"]) {
                return .appointmentSlot(searchID: search, resultID: result)
            }
            if let day = Day(text(event?["date"]) ?? "") { return .calendarDay(day) }
        case "create_appointment_search", "change_appointment_search":
            if let id = field("id") { return .appointmentSearch(id: id) }
        case "get_appointment_slot":
            if let search = field("searchId"), let result = number(a["resultId"]) {
                return .appointmentSlot(searchID: search, resultID: result)
            }
        case "get_meal_plan", "plan_meals", "get_shopping_items":
            return .mealPlan
        case "manage_categories":
            // Added or changed (a deleted one is gone).
            if r?["deleted"] == nil, let id = field("id") { return .financeTransactions(categoryID: id) }
            return nil
        default:
            break
        }
        // A page the result names (`page` / `url`: /f/{family}/…).
        for key in ["page", "url"] {
            if let path = field(key), let (family, route) = AppRoute.parse(webPath: path), family == familyID,
               route != .module(.overview) {
                return route
            }
        }
        return nil
    }

    // MARK: Reading results

    /// The result as a JSON object, if it is one (and wasn't cut short).
    static func object(_ result: String?) -> [String: JSONValue]? {
        guard let data = result?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }

    /// The first `"key": "value"` in a result's text.
    static func raw(_ key: String, in result: String?) -> String? {
        guard let result else { return nil }
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"([^\"\\\\]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(m.range(at: 1), in: result) else { return nil }
        return String(result[range])
    }

    private static func text(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func number(_ v: JSONValue?) -> String? {
        switch v {
        case let .number(n): n == n.rounded() ? String(Int(n)) : nil
        case let .string(s): Int(s).map(String.init)
        default: nil
        }
    }

    /// The first day a list of calendar ops touches.
    private static func firstDay(ops: JSONValue?) -> Day? {
        let days = (ops?.arrayValue ?? []).compactMap(\.objectValue).flatMap { o in
            (o["dates"]?.arrayValue ?? []) + [o["from"], o["to"]].compactMap { $0 }
        }.compactMap { $0.stringValue }.filter { $0.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil }.sorted()
        return days.first.flatMap { Day($0) }
    }
}

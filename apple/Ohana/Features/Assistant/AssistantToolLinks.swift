import Foundation

/// Where the app shows what a tool call was about: the recipe it saved or read, the calendar day
/// it changed, the appointment slot it booked, the meal plan, the finance category (the
/// result shapes of server/lib/assistant/tools/*). The chat makes such a call's row tappable.
enum AssistantToolLinks {
    /// One tool call read as JSON: its arguments and its result, which the chat may have cut short.
    private struct Call {
        let arguments: [String: JSONValue]
        let resultText: String?
        let resultObject: [String: JSONValue]?

        init(_ tool: AssistantToolCall) {
            arguments = tool.args
            resultText = tool.result
            resultObject = AssistantToolLinks.object(tool.result)
        }

        /// A string field of the result; a result cut short (the chat keeps 2,000 characters of
        /// it) is searched as text.
        func field(_ key: String) -> String? {
            if let resultObject { return AssistantToolLinks.text(resultObject[key]) }
            return AssistantToolLinks.raw(key, in: resultText)
        }

        /// A string field of the arguments the model was given.
        func argument(_ key: String) -> String? { AssistantToolLinks.text(arguments[key]) }

        /// A string field of the result's "event" object, then of the cut-short result.
        func event(_ key: String) -> String? {
            AssistantToolLinks.text(resultObject?["event"]?.objectValue?[key])
                ?? AssistantToolLinks.raw(key, in: resultText)
        }

        /// The day named in a result or argument field, e.g. "date".
        func day(named key: String) -> Day? {
            (field(key) ?? argument(key)).flatMap { Day($0) }
        }
    }

    /// The route of a successful tool call, or nil when there is nothing to show.
    static func route(_ tool: AssistantToolCall, familyID: String) -> AppRoute? {
        guard tool.status == "ok" else { return nil }
        let call = Call(tool)
        // A deleted category is gone; its result's link is no reason to open anything.
        if tool.name == "manage_categories" { return categories(call) }
        return route(named: tool.name, call: call) ?? route(linkedIn: call, familyID: familyID)
    }

    /// The place a tool of a known name points to, nil when its name is one of the generic ones.
    private static func route(named name: String, call: Call) -> AppRoute? {
        switch name {
        case "save_recipe", "get_recipe":
            return recipe(call)
        case "add_event":
            return call.day(named: "date").map { .calendarDay($0) }
        case "change_entries", "set_notes":
            return firstDay(ops: call.arguments["ops"]).map { .calendarDay($0) }
        case "book_appointment_slot", "create_appointment_search", "change_appointment_search",
             "get_appointment_slot":
            return appointments(name: name, call: call)
        case "get_meal_plan", "plan_meals", "get_shopping_items":
            return .mealPlan
        case "read_knowledge", "knowledge_values", "view_knowledge_pages":
            return knowledge(name: name, call: call)
        case "edit_memories":
            return .settings(.assistantMemory)
        case "manage_categories":
            return categories(call)
        default:
            return nil
        }
    }

    // MARK: One module's tools

    /// The recipe a call saved or read.
    private static func recipe(_ call: Call) -> AppRoute? {
        call.field("id").map { .recipe(id: $0) }
    }

    /// The slot it booked, the search it made or changed, the slot it read.
    private static func appointments(name: String, call: Call) -> AppRoute? {
        switch name {
        case "book_appointment_slot": return bookedSlot(call) ?? bookedDay(call)
        case "get_appointment_slot": return readSlot(call)
        default: return call.field("id").map { .appointmentSearch(id: $0) }
        }
    }

    /// The slot a booking call booked.
    private static func bookedSlot(_ call: Call) -> AppRoute? {
        guard let search = call.event("searchId"), let resultID = number(call.arguments["resultId"]) else {
            return nil
        }
        return .appointmentSlot(searchID: search, resultID: resultID)
    }

    /// Or the calendar day a booking call landed on, when no slot came out of it.
    private static func bookedDay(_ call: Call) -> AppRoute? {
        call.event("date").flatMap { Day($0) }.map { .calendarDay($0) }
    }

    /// The slot a `get_appointment_slot` call read.
    private static func readSlot(_ call: Call) -> AppRoute? {
        guard let search = call.field("searchId"), let resultID = number(call.arguments["resultId"]) else {
            return nil
        }
        return .appointmentSlot(searchID: search, resultID: resultID)
    }

    /// The document a knowledge tool read; only `read_knowledge` names a page of it.
    private static func knowledge(name: String, call: Call) -> AppRoute? {
        guard let id = call.argument("documentId") else { return nil }
        let page = name == "read_knowledge" ? pageNumber(call.arguments["page"]) : nil
        return .knowledgeDocument(id: id, page: page)
    }

    /// The page number of a `read_knowledge` call; pages start at 1.
    private static func pageNumber(_ jsonValue: JSONValue?) -> Int? {
        jsonValue?.doubleValue.flatMap { $0 >= 1 ? Int($0) : nil }
    }

    /// The finance category a call added or changed.
    private static func categories(_ call: Call) -> AppRoute? {
        guard call.resultObject?["deleted"] == nil, let id = call.field("id") else { return nil }
        return .financeTransactions(categoryID: id)
    }

    /// A page the result names (`page` / `url`: /f/{family}/…).
    private static func route(linkedIn call: Call, familyID: String) -> AppRoute? {
        for key in ["page", "url"] {
            if let path = call.field(key), let (family, linked) = AppRoute.parse(link: path),
               family == familyID, linked != .module(.overview) {
                return linked
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
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
              let range = Range(match.range(at: 1), in: result) else { return nil }
        return String(result[range])
    }

    private static func text(_ jsonValue: JSONValue?) -> String? {
        let raw = jsonValue?.stringValue ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func number(_ jsonValue: JSONValue?) -> String? {
        switch jsonValue {
        case let .number(numeric): numeric == numeric.rounded() ? String(Int(numeric)) : nil
        case let .string(textValue): Int(textValue).map(String.init)
        default: nil
        }
    }

    /// The first day a list of calendar ops touches.
    private static func firstDay(ops: JSONValue?) -> Day? {
        let days = (ops?.arrayValue ?? []).compactMap(\.objectValue).flatMap { operation in
            (operation["dates"]?.arrayValue ?? []) + [operation["from"], operation["to"]].compactMap { $0 }
        }.compactMap { $0.stringValue }.filter { $0.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil }.sorted()
        return days.first.flatMap { Day($0) }
    }
}

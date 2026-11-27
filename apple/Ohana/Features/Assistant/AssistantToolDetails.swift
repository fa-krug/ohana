// AssistantToolDetails.swift
// Ohana
//
// What a tool call is about, in a few words: the parts of its arguments that read well next to
// the tool's name ("March 2026 · “Amazon”"). AssistantToolLabels.swift holds the names and the
// small readers the parts below share.

import Foundation

extension AssistantToolLabels {
    /// A tool call's arguments, read the way the parts below want them.
    struct Call {
        let tool: AssistantToolCall

        init(_ tool: AssistantToolCall) { self.tool = tool }

        var args: [String: JSONValue] { tool.args }

        /// The ops an edit tool was given.
        var ops: [[String: JSONValue]] { (args["ops"]?.arrayValue ?? []).compactMap(\.objectValue) }

        /// A text argument ("" when the call has none).
        func text(_ key: String) -> String { AssistantToolLabels.str(args[key]) }

        /// A day argument ("" unless it reads as one).
        func day(_ key: String) -> String { AssistantToolLabels.date(args[key]) }

        /// A name argument; ids (uuids) aren't worth reading.
        func name(_ key: String) -> String { AssistantToolLabels.named(args[key]) }

        /// A name the call mentions, in quotes ("" when it has none).
        func quotedName(_ key: String) -> String {
            let nameText = name(key)
            return nameText.isEmpty ? "" : AssistantToolLabels.quoted(nameText)
        }

        /// A text the call mentions, in quotes ("" when it has none).
        func quotedText(_ key: String) -> String {
            let textValue = text(key)
            return textValue.isEmpty ? "" : AssistantToolLabels.quoted(textValue)
        }
    }

    /// What the call is about, in a few words ("" when there is nothing to add).
    static func detail(_ tool: AssistantToolCall) -> String {
        let call = Call(tool)
        return parts(call).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The words of a call, by the kind of tool it is ([] when it adds nothing).
    private static func parts(_ call: Call) -> [String] {
        calendarParts(call) ?? financeParts(call) ?? kitchenParts(call) ?? deviceParts(call)
            ?? appointmentParts(call) ?? documentParts(call) ?? []
    }

    // MARK: The tools by domain

    /// The tools that read or change calendar entries.
    private static func calendarParts(_ call: Call) -> [String]? {
        switch call.tool.name {
        case "get_calendar", "list_events": period(call)
        case "analyze_calendar": calendarCount(call)
        case "change_entries": entryChanges(call)
        case "set_notes": noteChanges(call)
        case "manage_entry_types": entryTypes(call)
        case "add_event": eventAdded(call)
        default: nil
        }
    }

    /// The tools that read or change the finances.
    private static func financeParts(_ call: Call) -> [String]? {
        switch call.tool.name {
        case "finance_summary", "combine_transfers": period(call)
        case "analyze_transactions", "list_transactions": transactions(call)
        case "change_transactions": transactionChanges(call)
        case "manage_categories": category(call)
        case "calculate": calculation(call)
        default: nil
        }
    }

    /// The tools that read or plan the kitchen.
    private static func kitchenParts(_ call: Call) -> [String]? {
        switch call.tool.name {
        case "get_meal_plan": period(call)
        case "list_recipes": recipeList(call)
        case "get_recipe": recipeOne(call)
        case "save_recipe": recipeSaved(call)
        case "plan_meals": mealPlan(call)
        case "get_shopping_items": shopping(call)
        default: nil
        }
    }

    /// The tools that read or change what is on the device.
    private static func deviceParts(_ call: Call) -> [String]? {
        switch call.tool.name {
        case "get_reminders": remindersList(call)
        case "edit_reminders": editCard(call)
        case "get_apple_calendar": appleCalendar(call)
        case "edit_apple_calendar": editCard(call)
        default: nil
        }
    }

    /// The tools that look for an appointment.
    private static func appointmentParts(_ call: Call) -> [String]? {
        switch call.tool.name {
        case "suggest_items": suggestions(call)
        case "find_doctor_specialities": specialities(call)
        case "create_appointment_search": searchCreated(call)
        case "change_appointment_search", "run_appointment_search", "get_appointment_slot",
             "book_appointment_slot":
            searchOne(call)
        default: nil
        }
    }

    /// The tools that read or note down what the documents know.
    private static func documentParts(_ call: Call) -> [String]? {
        switch call.tool.name {
        case "search_knowledge": knowledgeSearch(call)
        case "knowledge_values": knowledgeValues(call)
        case "edit_knowledge_notes": knowledgeNotes(call)
        case "edit_memories": memories(call)
        case "read_knowledge": knowledgePage(call)
        default: nil
        }
    }

    // MARK: The parts of a call

    /// The days a call covers.
    private static func period(_ call: Call) -> [String] {
        [span(call.day("from"), call.day("to"))]
    }

    /// Calendar days counted: their range and the entry types.
    private static func calendarCount(_ call: Call) -> [String] {
        let rawTypes = call.args["types"]?.arrayValue ?? [call.args["types"] ?? .null]
        let types = rawTypes.map { named($0) }.filter { !$0.isEmpty }
        return [span(call.day("from"), call.day("to")), list(types)]
    }

    /// The expressions a calculate call works out.
    private static func calculation(_ call: Call) -> [String] {
        let single = call.args["expressions"] ?? call.args["expression"] ?? .null
        let all = call.args["expressions"]?.arrayValue ?? [single]
        var parts = [short(str(all.first))]
        if all.count > 1 { parts.append("+\(all.count - 1)") }
        return parts
    }

    /// Transactions read or analyzed: their days, text, account, category, kind and page.
    private static func transactions(_ call: Call) -> [String] {
        let queries = (call.args["queries"]?.arrayValue ?? []).compactMap(\.objectValue)
        var parts: [String] = []
        if queries.isEmpty {
            parts.append(span(call.day("from"), call.day("to")))
        } else {
            parts.append(querySpan(queries, call: call))
        }
        parts.append(call.quotedText("q"))
        parts.append(namedFilter(call, key: "account", none: "No account"))
        parts.append(namedFilter(call, key: "category", none: "Uncategorized"))
        parts.append(kind(call))
        parts.append(pageAfter(call))
        if !queries.isEmpty {
            let total = queries.count
            parts.append(counted("^[\(total) query](inflect: true)"))
        }
        return parts
    }

    /// The days the queries of a search cover; each falls back to the call's own range.
    private static func querySpan(_ queries: [[String: JSONValue]], call: Call) -> String {
        opsSpan(queries.map { oneQuery in
            [
                "from": oneQuery["from"] ?? call.args["from"] ?? .null,
                "to": oneQuery["to"] ?? call.args["to"] ?? .null
            ]
        })
    }

    /// A filter the call names, or the word for "nothing of it".
    private static func namedFilter(_ call: Call, key: String, none: String.LocalizationValue) -> String {
        call.text(key) == "none" ? String(localized: none) : call.name(key)
    }

    /// The kind of transactions asked for ("" for all of them).
    private static func kind(_ call: Call) -> String {
        switch call.text("kind") {
        case "income": String(localized: "Income")
        case "expense": String(localized: "Expenses")
        case "transfer": String(localized: "Transfers")
        default: ""
        }
    }

    /// The row a list call starts at ("" when it starts at the top).
    private static func pageAfter(_ call: Call) -> String {
        let offset = Int(call.args["offset"]?.doubleValue ?? 0)
        guard offset > 0 else { return "" }
        let row = offset + 1
        return String(localized: "from row \(row)")
    }

    /// Calendar entries an op changes: the days and the entry types.
    private static func entryChanges(_ call: Call) -> [String] {
        let types = unique(call.ops.flatMap { operation in
            ([operation["type"]] + (operation["types"]?.arrayValue ?? []).map { Optional($0) }).map { named($0) }
        })
        return [opsSpan(call.ops), list(types)]
    }

    /// The days the notes of an op fall on.
    private static func noteChanges(_ call: Call) -> [String] { [opsSpan(call.ops)] }

    /// Transactions an op changes; a delete op can name many.
    private static func transactionChanges(_ call: Call) -> [String] {
        let total = call.ops.reduce(0) { sum, operation in
            sum + (str(operation["action"]) == "delete" ? (operation["ids"]?.arrayValue?.count ?? 1) : 1)
        }
        return total > 0 ? [counted("^[\(total) change](inflect: true)")] : []
    }

    /// An entry type: the years a copy runs from and to, or the type's name.
    private static func entryTypes(_ call: Call) -> [String] {
        guard call.text("action") != "copy_year" else {
            return ["\(number(call.args["from"])) → \(number(call.args["to"]))"]
        }
        let nameText = call.name("name").isEmpty ? call.name("type") : call.name("name")
        var parts = nameText.isEmpty ? [] : [quoted(nameText)]
        if call.args["year"] != nil, call.args["year"] != .null { parts.append(number(call.args["year"])) }
        return parts
    }

    /// The event a call adds.
    private static func eventAdded(_ call: Call) -> [String] {
        [span(call.day("date"), call.day("date")), call.quotedText("title")]
    }

    /// Recipes listed: the search, an ingredient, the tags.
    private static func recipeList(_ call: Call) -> [String] {
        var parts = [call.quotedText("query"), call.text("ingredient")]
        if let tags = call.args["tags"]?.arrayValue {
            parts.append(tags.map { named($0) }.filter { !$0.isEmpty }.prefix(3).joined(separator: ", "))
        }
        return parts
    }

    /// The one recipe read.
    private static func recipeOne(_ call: Call) -> [String] { [call.quotedName("recipe")] }

    /// The recipe saved: its new title, or the recipe it came from.
    private static func recipeSaved(_ call: Call) -> [String] {
        let title = call.text("title").isEmpty ? call.name("recipe") : call.text("title")
        return title.isEmpty ? [] : [quoted(title)]
    }

    /// Meals planned: the tags they leave out.
    private static func mealPlan(_ call: Call) -> [String] {
        guard let tags = call.args["excludeTags"]?.arrayValue, !tags.isEmpty else { return [] }
        let names = tags.map { named($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return [String(localized: "without \(names)")]
    }

    /// What the meal plan needs from a day on.
    private static func shopping(_ call: Call) -> [String] { [span(call.day("from"), "")] }

    /// The Reminders list read.
    private static func remindersList(_ call: Call) -> [String] { [call.quotedName("list")] }

    /// An edit of the reminders or the Apple calendars: how many ops and what they touch.
    private static func editCard(_ call: Call) -> [String] { editParts(call.ops) }

    /// The Apple calendar read.
    private static func appleCalendar(_ call: Call) -> [String] {
        [span(call.day("from"), call.day("to")), call.quotedName("calendar")]
    }

    /// The suggestions found for a scanned letter: how many and their titles.
    private static func suggestions(_ call: Call) -> [String] {
        let items = (call.args["items"]?.arrayValue ?? []).compactMap(\.objectValue)
        let titles = items.map { str($0["title"]) }.filter { !$0.isEmpty }
        var parts: [String] = []
        if !items.isEmpty {
            let total = items.count
            parts.append(counted("^[\(total) suggestion](inflect: true)"))
        }
        parts.append(list(titles, max: 3))
        return parts
    }

    /// The doctor specialities looked up.
    private static func specialities(_ call: Call) -> [String] { [quoted(call.text("query"))] }

    /// The appointment search created: what, by when and where.
    private static func searchCreated(_ call: Call) -> [String] {
        [call.text("speciality"), span("", call.day("before")), call.text("place")]
    }

    /// The search a call changes, runs or reads a slot of.
    private static func searchOne(_ call: Call) -> [String] { [call.quotedName("search")] }

    /// The finance category added or changed, and the one under it.
    private static func category(_ call: Call) -> [String] {
        let nameText = call.name("name").isEmpty ? call.name("category") : call.name("name")
        var parts = nameText.isEmpty ? [] : [quoted(nameText)]
        let parent = call.name("parent")
        if !parent.isEmpty { parts.append("→ \(quoted(parent))") }
        return parts
    }

    /// The knowledge search: its text, tags and folder.
    private static func knowledgeSearch(_ call: Call) -> [String] {
        var parts = [call.quotedText("query")]
        if let tags = call.args["tags"]?.arrayValue {
            parts.append(list(tags.map { str($0) }.filter { !$0.isEmpty }, max: 3))
        }
        let folder = call.text("folder")
        if !folder.isEmpty { parts.append(KnowledgePath.breadcrumb(folder)) }
        return parts
    }

    /// Values read from the documents: the search and the person.
    private static func knowledgeValues(_ call: Call) -> [String] {
        [call.quotedText("query"), call.text("person")]
    }

    /// The notes offered for the documents: how many and which files.
    private static func knowledgeNotes(_ call: Call) -> [String] {
        let names = call.ops.map { KnowledgePath.parts(str($0["path"])).last ?? "" }.filter { !$0.isEmpty }
        var parts: [String] = []
        if !call.ops.isEmpty {
            let total = call.ops.count
            parts.append(counted("^[\(total) change](inflect: true)"))
        }
        parts.append(list(names, max: 3))
        return parts
    }

    /// The memories to keep: how many and what they say.
    private static func memories(_ call: Call) -> [String] {
        let texts = call.ops.map { str($0["text"]) }.filter { !$0.isEmpty }.map(short)
        var parts: [String] = []
        if !call.ops.isEmpty {
            let total = call.ops.count
            parts.append(counted("^[\(total) change](inflect: true)"))
        }
        parts.append(list(texts.map(quoted), max: 2))
        return parts
    }

    /// The page of the document read.
    private static func knowledgePage(_ call: Call) -> [String] {
        guard let page = call.args["page"]?.doubleValue, page >= 1 else { return [] }
        let pageNumber = Int(page)
        return [String(localized: "Page \(pageNumber)")]
    }
}

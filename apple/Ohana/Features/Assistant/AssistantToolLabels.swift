import Foundation

/// How the chat names a tool call (web: components/assistant/tools.ts): what it does
/// ("Reading transactions") and, in a few words, what it is about ("March 2026 · “Amazon”"),
/// from the arguments the model passed.
enum AssistantToolLabels {
    /// The app's language: German quotes and dates for "de".
    static var isGerman: Bool { (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("de") }

    /// What the tool is doing, e.g. "Reading transactions"; a tool the app doesn't know yet
    /// shows its name.
    static func label(_ tool: AssistantToolCall) -> String {
        let callArgs = tool.args
        switch tool.name {
        case "web_search":
            let searchQuery = callArgs["query"]?.stringValue ?? ""
            return String(localized: "Searching the web: \(searchQuery)")
        case "fetch_page":
            let raw = callArgs["url"]?.stringValue ?? ""
            let host = URL(string: raw)?.host() ?? raw
            return String(localized: "Reading \(host)")
        case "get_calendar": return String(localized: "Reading the calendar")
        case "change_entries": return String(localized: "Changing calendar entries")
        case "set_notes": return String(localized: "Changing day notes")
        case "manage_entry_types": return String(localized: "Changing entry types")
        case "list_transactions": return String(localized: "Reading transactions")
        case "finance_summary": return String(localized: "Summing up the finances")
        case "analyze_transactions": return String(localized: "Analyzing transactions")
        case "analyze_calendar": return String(localized: "Counting calendar days")
        case "calculate": return String(localized: "Calculating")
        case "manage_categories": return String(localized: "Changing categories")
        case "change_transactions": return String(localized: "Changing transactions")
        case "set_statistic_average": return String(localized: "Setting the statistic average")
        case "combine_transfers": return String(localized: "Combining transfers and split bookings")
        case "ask_user": return String(localized: "Asking a question")
        case "list_events": return String(localized: "Reading calendar events")
        case "add_event": return String(localized: "Adding a calendar event")
        case "remove_event": return String(localized: "Removing a calendar event")
        case "list_recipes": return String(localized: "Looking through the recipes")
        case "get_recipe": return String(localized: "Reading a recipe")
        case "save_recipe": return String(localized: "Saving a recipe")
        case "get_meal_plan": return String(localized: "Reading the meal plan")
        case "plan_meals": return String(localized: "Planning meals")
        case "get_shopping_items": return String(localized: "Reading what the meal plan needs")
        case "get_reminders": return String(localized: "Reading your reminders")
        case "edit_reminders": return String(localized: "Suggesting changes to your reminders")
        case "get_apple_calendar": return String(localized: "Reading your Apple calendars")
        case "edit_apple_calendar": return String(localized: "Suggesting changes to your Apple calendars")
        case "suggest_items": return String(localized: "Suggesting what to add")
        case "list_appointment_searches": return String(localized: "Reading the appointment searches")
        case "find_doctor_specialities": return String(localized: "Looking up specialities")
        case "create_appointment_search": return String(localized: "Creating an appointment search")
        case "change_appointment_search": return String(localized: "Changing an appointment search")
        case "run_appointment_search": return String(localized: "Starting an appointment search")
        case "get_appointment_slot": return String(localized: "Reading a slot")
        case "book_appointment_slot": return String(localized: "Marking a slot as booked")
        case "search_knowledge": return String(localized: "Searching the knowledge base")
        case "read_knowledge": return String(localized: "Reading a document")
        case "knowledge_values": return String(localized: "Reading values from the documents")
        case "edit_knowledge_notes": return String(localized: "Suggesting notes for the knowledge folder")
        case "view_knowledge_pages": return String(localized: "Looking at a document’s pages")
        case "edit_memories": return String(localized: "Suggesting what to remember")
        default: return tool.name
        }
    }

    /// The SF Symbol of a tool's row.
    static func icon(_ name: String) -> String {
        switch name {
        case "web_search": "magnifyingglass"
        case "fetch_page": "globe"
        case "calculate": "function"
        case "ask_user": "questionmark.bubble"
        case "get_calendar", "analyze_calendar", "change_entries", "set_notes", "manage_entry_types":
            "calendar"
        case "list_events", "add_event", "remove_event": "calendar.badge.clock"
        case "list_transactions", "finance_summary", "analyze_transactions", "manage_categories",
             "change_transactions", "combine_transfers", "set_statistic_average":
            "banknote"
        case "list_recipes", "get_recipe", "save_recipe", "get_meal_plan", "plan_meals": "fork.knife"
        case "get_shopping_items": "cart"
        case "get_reminders", "edit_reminders": "checklist"
        case "get_apple_calendar", "edit_apple_calendar": "calendar.badge.checkmark"
        case "suggest_items": "doc.text.viewfinder"
        case "list_appointment_searches", "find_doctor_specialities", "create_appointment_search",
             "change_appointment_search", "run_appointment_search", "get_appointment_slot",
             "book_appointment_slot":
            "stethoscope"
        case "search_knowledge", "read_knowledge", "knowledge_values": "books.vertical"
        case "edit_knowledge_notes": "note.text"
        case "view_knowledge_pages": "doc.viewfinder"
        case "edit_memories": "brain"
        default: "sparkles"
        }
    }

    // MARK: Details

    private static let uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
    private static let dayPattern = /^\d{4}-\d{2}-\d{2}$/

    private static func str(_ value: JSONValue?) -> String {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func date(_ value: JSONValue?) -> String {
        guard let dayText = value?.stringValue, dayText.wholeMatch(of: dayPattern) != nil else { return "" }
        return dayText
    }

    /// An id or name the model passed: names are shown, ids (uuids) aren't worth reading.
    private static func named(_ value: JSONValue?) -> String {
        let nameText = str(value)
        return nameText.isEmpty || nameText.wholeMatch(of: uuid) != nil ? "" : nameText
    }

    static func quoted(_ value: String) -> String { isGerman ? "„\(value)“" : "“\(value)”" }

    private static func noon(_ day: String) -> Date? {
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: dayParts[0], month: dayParts[1], day: dayParts[2], hour: 12))
    }

    private static func formatted(_ day: String, template: String) -> String {
        guard let dayDate = noon(day) else { return day }
        return formatter(template).string(from: dayDate)
    }

    /// Formatters by template (and the locale they were made for): making one takes long, and a
    /// chat's tool rows ask for them every time they're drawn.
    private static var formatters: [String: DateFormatter] = [:]
    private static var intervalFormatters: [String: DateIntervalFormatter] = [:]

    private static func formatter(_ template: String) -> DateFormatter {
        let key = Locale.current.identifier + "|" + template
        if let cached = formatters[key] { return cached }
        let newFormatter = DateFormatter()
        newFormatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = newFormatter
        return newFormatter
    }

    private static func interval() -> DateIntervalFormatter {
        let key = Locale.current.identifier
        if let cached = intervalFormatters[key] { return cached }
        let newFormatter = DateIntervalFormatter()
        newFormatter.dateTemplate = "dMMMy"
        intervalFormatters[key] = newFormatter
        return newFormatter
    }

    private static func lastOfMonth(_ day: String) -> Int {
        guard let dayDate = noon(day) else { return 31 }
        return Calendar.current.range(of: .day, in: .month, for: dayDate)?.count ?? 31
    }

    /// A day range in short: "2026", "March 2026", "3 – 7 Aug 2026", "from 1 Mar 2026".
    static func span(_ from: String, _ to: String) -> String {
        var from = from, to = to
        if !from.isEmpty, !to.isEmpty {
            if from > to { swap(&from, &to) }
            if from.hasSuffix("-01-01"), to.hasSuffix("-12-31") {
                let fromYear = String(from.prefix(4)), toYear = String(to.prefix(4))
                return fromYear == toYear ? fromYear : "\(fromYear) – \(toYear)"
            }
            if from.prefix(7) == to.prefix(7), from.hasSuffix("-01"), Int(to.suffix(2)) == lastOfMonth(to) {
                return formatted(from, template: "MMMMy")
            }
            if from == to { return formatted(from, template: "dMMMy") }
            guard let fromDate = noon(from), let toDate = noon(to) else { return "\(from) – \(to)" }
            return interval().string(from: fromDate, to: toDate)
        }
        if !from.isEmpty {
            let dayLabel = formatted(from, template: "dMMMy")
            return String(localized: "from \(dayLabel)")
        }
        if !to.isEmpty {
            let dayLabel = formatted(to, template: "dMMMy")
            return String(localized: "until \(dayLabel)")
        }
        return ""
    }

    /// The days a list of ops touches, as one range.
    private static func opsSpan(_ ops: [[String: JSONValue]]) -> String {
        let days = ops.flatMap { operation in
            (operation["dates"]?.arrayValue?.map { date($0) } ?? []) + [date(operation["from"]), date(operation["to"])]
        }.filter { !$0.isEmpty }.sorted()
        guard let first = days.first, let last = days.last else { return "" }
        return span(first, last)
    }

    private static func list(_ names: [String], max: Int = 2) -> String {
        names.prefix(max).joined(separator: ", ") + (names.count > max ? " …" : "")
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What the call is about, in a few words ("" when there is nothing to add).
    static func detail(_ tool: AssistantToolCall) -> String {
        let callArgs = tool.args
        let ops = (callArgs["ops"]?.arrayValue ?? []).compactMap(\.objectValue)
        var parts: [String] = []
        switch tool.name {
        case "get_calendar", "finance_summary", "combine_transfers", "list_events", "get_meal_plan":
            parts.append(span(date(callArgs["from"]), date(callArgs["to"])))
        case "analyze_calendar":
            parts.append(span(date(callArgs["from"]), date(callArgs["to"])))
            let types = (callArgs["types"]?.arrayValue ?? [callArgs["types"] ?? .null]).map { named($0) }.filter { !$0.isEmpty }
            parts.append(list(types))
        case "calculate":
            let all = callArgs["expressions"]?.arrayValue ?? [callArgs["expressions"] ?? callArgs["expression"] ?? .null]
            let first = str(all.first)
            parts.append(first.count > 40 ? String(first.prefix(40)) + "…" : first)
            if all.count > 1 { parts.append("+\(all.count - 1)") }
        case "analyze_transactions", "list_transactions":
            let queries = (callArgs["queries"]?.arrayValue ?? []).compactMap(\.objectValue)
            if !queries.isEmpty {
                parts.append(opsSpan(queries.map { oneQuery in
                    ["from": oneQuery["from"] ?? callArgs["from"] ?? .null, "to": oneQuery["to"] ?? callArgs["to"] ?? .null]
                }))
            } else {
                parts.append(span(date(callArgs["from"]), date(callArgs["to"])))
            }
            if !str(callArgs["q"]).isEmpty { parts.append(quoted(str(callArgs["q"]))) }
            if str(callArgs["account"]) == "none" { parts.append(String(localized: "No account")) } else { parts.append(named(callArgs["account"])) }
            if str(callArgs["category"]) == "none" { parts.append(String(localized: "Uncategorized")) } else { parts.append(named(callArgs["category"])) }
            switch str(callArgs["kind"]) {
            case "income": parts.append(String(localized: "Income"))
            case "expense": parts.append(String(localized: "Expenses"))
            case "transfer": parts.append(String(localized: "Transfers"))
            default: break
            }
            let offset = Int(callArgs["offset"]?.doubleValue ?? 0)
            if offset > 0 {
                let row = offset + 1
                parts.append(String(localized: "from row \(row)"))
            }
            if !queries.isEmpty {
                let total = queries.count
                parts.append(String(AttributedString(localized: "^[\(total) query](inflect: true)").characters))
            }
        case "change_entries":
            let types = unique(ops.flatMap { operation in
                ([operation["type"]] + (operation["types"]?.arrayValue ?? []).map { Optional($0) }).map { named($0) }
            })
            parts.append(opsSpan(ops))
            parts.append(list(types))
        case "set_notes":
            parts.append(opsSpan(ops))
        case "change_transactions":
            // A delete op can name many transactions.
            let total = ops.reduce(0) { sum, operation in
                sum + (str(operation["action"]) == "delete" ? (operation["ids"]?.arrayValue?.count ?? 1) : 1)
            }
            if total > 0 { parts.append(String(AttributedString(localized: "^[\(total) change](inflect: true)").characters)) }
        case "manage_entry_types":
            if str(callArgs["action"]) == "copy_year" {
                parts.append("\(number(callArgs["from"])) → \(number(callArgs["to"]))")
            } else {
                let name = named(callArgs["name"]).isEmpty ? named(callArgs["type"]) : named(callArgs["name"])
                if !name.isEmpty { parts.append(quoted(name)) }
                if callArgs["year"] != nil, callArgs["year"] != .null { parts.append(number(callArgs["year"])) }
            }
        case "add_event":
            parts.append(span(date(callArgs["date"]), date(callArgs["date"])))
            if !str(callArgs["title"]).isEmpty { parts.append(quoted(str(callArgs["title"]))) }
        case "list_recipes":
            if !str(callArgs["query"]).isEmpty { parts.append(quoted(str(callArgs["query"]))) }
            if !str(callArgs["ingredient"]).isEmpty { parts.append(str(callArgs["ingredient"])) }
            if let tags = callArgs["tags"]?.arrayValue {
                parts.append(tags.map { named($0) }.filter { !$0.isEmpty }.prefix(3).joined(separator: ", "))
            }
        case "get_recipe":
            if !named(callArgs["recipe"]).isEmpty { parts.append(quoted(named(callArgs["recipe"]))) }
        case "save_recipe":
            let title = str(callArgs["title"]).isEmpty ? named(callArgs["recipe"]) : str(callArgs["title"])
            if !title.isEmpty { parts.append(quoted(title)) }
        case "plan_meals":
            if let tags = callArgs["excludeTags"]?.arrayValue, !tags.isEmpty {
                let names = tags.map { named($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
                parts.append(String(localized: "without \(names)"))
            }
        case "get_shopping_items":
            parts.append(span(date(callArgs["from"]), ""))
        case "get_reminders":
            if !named(callArgs["list"]).isEmpty { parts.append(quoted(named(callArgs["list"]))) }
        case "edit_reminders":
            let titles = ops.map { str($0["title"]) }.filter { !$0.isEmpty }
            if !ops.isEmpty {
                let total = ops.count
                parts.append(String(AttributedString(localized: "^[\(total) change](inflect: true)").characters))
            }
            parts.append(list(titles, max: 3))
        case "get_apple_calendar":
            parts.append(span(date(callArgs["from"]), date(callArgs["to"])))
            if !named(callArgs["calendar"]).isEmpty { parts.append(quoted(named(callArgs["calendar"]))) }
        case "edit_apple_calendar":
            let titles = ops.map { str($0["title"]) }.filter { !$0.isEmpty }
            if !ops.isEmpty {
                let total = ops.count
                parts.append(String(AttributedString(localized: "^[\(total) change](inflect: true)").characters))
            }
            parts.append(list(titles, max: 3))
        case "suggest_items":
            let items = (callArgs["items"]?.arrayValue ?? []).compactMap(\.objectValue)
            let titles = items.map { str($0["title"]) }.filter { !$0.isEmpty }
            if !items.isEmpty {
                let total = items.count
                parts.append(String(AttributedString(localized: "^[\(total) suggestion](inflect: true)").characters))
            }
            parts.append(list(titles, max: 3))
        case "find_doctor_specialities":
            parts.append(quoted(str(callArgs["query"])))
        case "create_appointment_search":
            if !str(callArgs["speciality"]).isEmpty { parts.append(str(callArgs["speciality"])) }
            if !date(callArgs["before"]).isEmpty { parts.append(span("", date(callArgs["before"]))) }
            if !str(callArgs["place"]).isEmpty { parts.append(str(callArgs["place"])) }
        case "change_appointment_search", "run_appointment_search", "get_appointment_slot", "book_appointment_slot":
            if !named(callArgs["search"]).isEmpty { parts.append(quoted(named(callArgs["search"]))) }
        case "manage_categories":
            let name = named(callArgs["name"]).isEmpty ? named(callArgs["category"]) : named(callArgs["name"])
            if !name.isEmpty { parts.append(quoted(name)) }
            if !named(callArgs["parent"]).isEmpty { parts.append("→ \(quoted(named(callArgs["parent"])))") }
        case "search_knowledge":
            if !str(callArgs["query"]).isEmpty { parts.append(quoted(str(callArgs["query"]))) }
            if let tags = callArgs["tags"]?.arrayValue { parts.append(list(tags.map { str($0) }.filter { !$0.isEmpty }, max: 3)) }
            if !str(callArgs["folder"]).isEmpty { parts.append(KnowledgePath.breadcrumb(str(callArgs["folder"]))) }
        case "knowledge_values":
            if !str(callArgs["query"]).isEmpty { parts.append(quoted(str(callArgs["query"]))) }
            if !str(callArgs["person"]).isEmpty { parts.append(str(callArgs["person"])) }
        case "edit_knowledge_notes":
            let names = ops.map { KnowledgePath.parts(str($0["path"])).last ?? "" }.filter { !$0.isEmpty }
            if !ops.isEmpty {
                let total = ops.count
                parts.append(String(AttributedString(localized: "^[\(total) change](inflect: true)").characters))
            }
            parts.append(list(names, max: 3))
        case "edit_memories":
            let texts = ops.map { str($0["text"]) }.filter { !$0.isEmpty }
                .map { $0.count > 40 ? String($0.prefix(40)) + "…" : $0 }
            if !ops.isEmpty {
                let total = ops.count
                parts.append(String(AttributedString(localized: "^[\(total) change](inflect: true)").characters))
            }
            parts.append(list(texts.map(quoted), max: 2))
        case "read_knowledge":
            if let page = callArgs["page"]?.doubleValue, page >= 1 {
                let pageNumber = Int(page)
                parts.append(String(localized: "Page \(pageNumber)"))
            }
        default:
            break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func number(_ value: JSONValue?) -> String {
        switch value {
        case let .number(numeric): numeric == numeric.rounded() ? String(Int(numeric)) : String(numeric)
        case let .string(textValue): textValue
        default: ""
        }
    }
}

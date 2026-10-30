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
        let a = tool.args
        switch tool.name {
        case "web_search":
            let q = a["query"]?.stringValue ?? ""
            return String(localized: "Searching the web: \(q)")
        case "fetch_page":
            let raw = a["url"]?.stringValue ?? ""
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
        case "get_shopping_list": return String(localized: "Reading the shopping list")
        case "tick_shopping_items": return String(localized: "Ticking off the shopping list")
        case "add_shopping_items": return String(localized: "Adding to the shopping list")
        case "list_appointment_searches": return String(localized: "Reading the appointment searches")
        case "find_doctor_specialities": return String(localized: "Looking up specialities")
        case "create_appointment_search": return String(localized: "Creating an appointment search")
        case "change_appointment_search": return String(localized: "Changing an appointment search")
        case "run_appointment_search": return String(localized: "Starting an appointment search")
        case "get_appointment_slot": return String(localized: "Reading a slot")
        case "book_appointment_slot": return String(localized: "Marking a slot as booked")
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
        case "get_shopping_list", "tick_shopping_items", "add_shopping_items": "cart"
        case "list_appointment_searches", "find_doctor_specialities", "create_appointment_search",
             "change_appointment_search", "run_appointment_search", "get_appointment_slot",
             "book_appointment_slot":
            "stethoscope"
        default: "sparkles"
        }
    }

    // MARK: Details

    private static let uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
    private static let dayPattern = /^\d{4}-\d{2}-\d{2}$/

    private static func str(_ v: JSONValue?) -> String {
        v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func date(_ v: JSONValue?) -> String {
        guard let s = v?.stringValue, s.wholeMatch(of: dayPattern) != nil else { return "" }
        return s
    }

    /// An id or name the model passed: names are shown, ids (uuids) aren't worth reading.
    private static func named(_ v: JSONValue?) -> String {
        let s = str(v)
        return s.isEmpty || s.wholeMatch(of: uuid) != nil ? "" : s
    }

    static func quoted(_ v: String) -> String { isGerman ? "„\(v)“" : "“\(v)”" }

    private static func noon(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    private static func formatted(_ day: String, template: String) -> String {
        guard let d = noon(day) else { return day }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    private static func lastOfMonth(_ day: String) -> Int {
        guard let d = noon(day) else { return 31 }
        return Calendar.current.range(of: .day, in: .month, for: d)?.count ?? 31
    }

    /// A day range in short: "2026", "March 2026", "3 – 7 Aug 2026", "from 1 Mar 2026".
    static func span(_ from: String, _ to: String) -> String {
        var from = from, to = to
        if !from.isEmpty, !to.isEmpty {
            if from > to { swap(&from, &to) }
            if from.hasSuffix("-01-01"), to.hasSuffix("-12-31") {
                let a = String(from.prefix(4)), b = String(to.prefix(4))
                return a == b ? a : "\(a) – \(b)"
            }
            if from.prefix(7) == to.prefix(7), from.hasSuffix("-01"), Int(to.suffix(2)) == lastOfMonth(to) {
                return formatted(from, template: "MMMMy")
            }
            if from == to { return formatted(from, template: "dMMMy") }
            guard let a = noon(from), let b = noon(to) else { return "\(from) – \(to)" }
            let f = DateIntervalFormatter()
            f.dateTemplate = "dMMMy"
            return f.string(from: a, to: b)
        }
        if !from.isEmpty {
            let d = formatted(from, template: "dMMMy")
            return String(localized: "from \(d)")
        }
        if !to.isEmpty {
            let d = formatted(to, template: "dMMMy")
            return String(localized: "until \(d)")
        }
        return ""
    }

    /// The days a list of ops touches, as one range.
    private static func opsSpan(_ ops: [[String: JSONValue]]) -> String {
        let days = ops.flatMap { o in
            (o["dates"]?.arrayValue?.map { date($0) } ?? []) + [date(o["from"]), date(o["to"])]
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
        let a = tool.args
        let ops = (a["ops"]?.arrayValue ?? []).compactMap(\.objectValue)
        var parts: [String] = []
        switch tool.name {
        case "get_calendar", "finance_summary", "combine_transfers", "list_events", "get_meal_plan":
            parts.append(span(date(a["from"]), date(a["to"])))
        case "analyze_calendar":
            parts.append(span(date(a["from"]), date(a["to"])))
            let types = (a["types"]?.arrayValue ?? [a["types"] ?? .null]).map { named($0) }.filter { !$0.isEmpty }
            parts.append(list(types))
        case "calculate":
            let all = a["expressions"]?.arrayValue ?? [a["expressions"] ?? a["expression"] ?? .null]
            let first = str(all.first)
            parts.append(first.count > 40 ? String(first.prefix(40)) + "…" : first)
            if all.count > 1 { parts.append("+\(all.count - 1)") }
        case "analyze_transactions", "list_transactions":
            let queries = (a["queries"]?.arrayValue ?? []).compactMap(\.objectValue)
            if !queries.isEmpty {
                parts.append(opsSpan(queries.map { q in
                    ["from": q["from"] ?? a["from"] ?? .null, "to": q["to"] ?? a["to"] ?? .null]
                }))
            } else {
                parts.append(span(date(a["from"]), date(a["to"])))
            }
            if !str(a["q"]).isEmpty { parts.append(quoted(str(a["q"]))) }
            if str(a["account"]) == "none" { parts.append(String(localized: "No account")) } else { parts.append(named(a["account"])) }
            if str(a["category"]) == "none" { parts.append(String(localized: "Uncategorized")) } else { parts.append(named(a["category"])) }
            switch str(a["kind"]) {
            case "income": parts.append(String(localized: "Income"))
            case "expense": parts.append(String(localized: "Expenses"))
            case "transfer": parts.append(String(localized: "Transfers"))
            default: break
            }
            let offset = Int(a["offset"]?.doubleValue ?? 0)
            if offset > 0 {
                let row = offset + 1
                parts.append(String(localized: "from row \(row)"))
            }
            if !queries.isEmpty {
                let n = queries.count
                parts.append(String(AttributedString(localized: "^[\(n) query](inflect: true)").characters))
            }
        case "change_entries":
            let types = unique(ops.flatMap { o in
                ([o["type"]] + (o["types"]?.arrayValue ?? []).map { Optional($0) }).map { named($0) }
            })
            parts.append(opsSpan(ops))
            parts.append(list(types))
        case "set_notes":
            parts.append(opsSpan(ops))
        case "change_transactions":
            // A delete op can name many transactions.
            let n = ops.reduce(0) { sum, o in
                sum + (str(o["action"]) == "delete" ? (o["ids"]?.arrayValue?.count ?? 1) : 1)
            }
            if n > 0 { parts.append(String(AttributedString(localized: "^[\(n) change](inflect: true)").characters)) }
        case "manage_entry_types":
            if str(a["action"]) == "copy_year" {
                parts.append("\(number(a["from"])) → \(number(a["to"]))")
            } else {
                let name = named(a["name"]).isEmpty ? named(a["type"]) : named(a["name"])
                if !name.isEmpty { parts.append(quoted(name)) }
                if a["year"] != nil, a["year"] != .null { parts.append(number(a["year"])) }
            }
        case "add_event":
            parts.append(span(date(a["date"]), date(a["date"])))
            if !str(a["title"]).isEmpty { parts.append(quoted(str(a["title"]))) }
        case "list_recipes":
            if !str(a["query"]).isEmpty { parts.append(quoted(str(a["query"]))) }
            if !str(a["ingredient"]).isEmpty { parts.append(str(a["ingredient"])) }
            if let tags = a["tags"]?.arrayValue {
                parts.append(tags.map { named($0) }.filter { !$0.isEmpty }.prefix(3).joined(separator: ", "))
            }
        case "get_recipe":
            if !named(a["recipe"]).isEmpty { parts.append(quoted(named(a["recipe"]))) }
        case "save_recipe":
            let title = str(a["title"]).isEmpty ? named(a["recipe"]) : str(a["title"])
            if !title.isEmpty { parts.append(quoted(title)) }
        case "plan_meals":
            if let tags = a["excludeTags"]?.arrayValue, !tags.isEmpty {
                let names = tags.map { named($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
                parts.append(String(localized: "without \(names)"))
            }
        case "tick_shopping_items", "add_shopping_items":
            let items = (a["items"]?.arrayValue ?? []).map { i in
                i.stringValue != nil ? named(i) : str(i["name"])
            }.filter { !$0.isEmpty }
            parts.append(list(items, max: 3))
        case "find_doctor_specialities":
            parts.append(quoted(str(a["query"])))
        case "create_appointment_search":
            if !str(a["speciality"]).isEmpty { parts.append(str(a["speciality"])) }
            if !date(a["before"]).isEmpty { parts.append(span("", date(a["before"]))) }
            if !str(a["place"]).isEmpty { parts.append(str(a["place"])) }
        case "change_appointment_search", "run_appointment_search", "get_appointment_slot", "book_appointment_slot":
            if !named(a["search"]).isEmpty { parts.append(quoted(named(a["search"]))) }
        case "manage_categories":
            let name = named(a["name"]).isEmpty ? named(a["category"]) : named(a["name"])
            if !name.isEmpty { parts.append(quoted(name)) }
            if !named(a["parent"]).isEmpty { parts.append("→ \(quoted(named(a["parent"])))") }
        default:
            break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func number(_ v: JSONValue?) -> String {
        switch v {
        case let .number(n): n == n.rounded() ? String(Int(n)) : String(n)
        case let .string(s): s
        default: ""
        }
    }
}

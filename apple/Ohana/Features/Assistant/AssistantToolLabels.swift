import Foundation

/// How the chat names a tool call (web: components/assistant/tools.ts): what it does
/// ("Reading transactions") and, in a few words, what it is about ("March 2026 · “Amazon”"),
/// from the arguments the model passed. The parts of a call live in AssistantToolDetails.swift.
enum AssistantToolLabels {
    /// What the tool is doing, e.g. "Reading transactions"; a tool the app doesn't know yet
    /// shows its name.
    static func label(_ tool: AssistantToolCall) -> String {
        chatLabel(tool) ?? calendarLabel(tool.name) ?? financeLabel(tool.name) ?? mealsLabel(tool.name)
            ?? deviceLabel(tool.name) ?? appointmentsLabel(tool.name) ?? knowledgeLabel(tool.name) ?? tool.name
    }

    /// The tools the model talks to the family with.
    private static func chatLabel(_ tool: AssistantToolCall) -> String? {
        switch tool.name {
        case "web_search":
            let searchQuery = tool.args["query"]?.stringValue ?? ""
            String(localized: "Searching the web: \(searchQuery)")
        case "fetch_page":
            let raw = tool.args["url"]?.stringValue ?? ""
            let host = URL(string: raw)?.host() ?? raw
            String(localized: "Reading \(host)")
        case "ask_user": String(localized: "Asking a question")
        default: nil
        }
    }

    /// The tools that read or change calendar entries.
    private static func calendarLabel(_ name: String) -> String? {
        switch name {
        case "get_calendar": String(localized: "Reading the calendar")
        case "list_events": String(localized: "Reading calendar events")
        case "add_event": String(localized: "Adding a calendar event")
        case "remove_event": String(localized: "Removing a calendar event")
        case "change_entries": String(localized: "Changing calendar entries")
        case "set_notes": String(localized: "Changing day notes")
        case "manage_entry_types": String(localized: "Changing entry types")
        case "analyze_calendar": String(localized: "Counting calendar days")
        default: nil
        }
    }

    /// The tools that read or change the finances.
    private static func financeLabel(_ name: String) -> String? {
        switch name {
        case "finance_summary": String(localized: "Summing up the finances")
        case "list_transactions": String(localized: "Reading transactions")
        case "analyze_transactions": String(localized: "Analyzing transactions")
        case "change_transactions": String(localized: "Changing transactions")
        case "combine_transfers": String(localized: "Combining transfers and split bookings")
        case "manage_categories": String(localized: "Changing categories")
        case "set_statistic_average": String(localized: "Setting the statistic average")
        case "calculate": String(localized: "Calculating")
        default: nil
        }
    }

    /// The tools that read or plan the kitchen.
    private static func mealsLabel(_ name: String) -> String? {
        switch name {
        case "list_recipes": String(localized: "Looking through the recipes")
        case "get_recipe": String(localized: "Reading a recipe")
        case "save_recipe": String(localized: "Saving a recipe")
        case "get_meal_plan": String(localized: "Reading the meal plan")
        case "plan_meals": String(localized: "Planning meals")
        case "get_shopping_items": String(localized: "Reading what the meal plan needs")
        default: nil
        }
    }

    /// The tools that read or change what is on the device.
    private static func deviceLabel(_ name: String) -> String? {
        switch name {
        case "get_reminders": String(localized: "Reading your reminders")
        case "edit_reminders": String(localized: "Suggesting changes to your reminders")
        case "get_apple_calendar": String(localized: "Reading your Apple calendars")
        case "edit_apple_calendar": String(localized: "Suggesting changes to your Apple calendars")
        default: nil
        }
    }

    /// The tools that look for an appointment.
    private static func appointmentsLabel(_ name: String) -> String? {
        switch name {
        case "suggest_items": String(localized: "Suggesting what to add")
        case "list_appointment_searches": String(localized: "Reading the appointment searches")
        case "find_doctor_specialities": String(localized: "Looking up specialities")
        case "create_appointment_search": String(localized: "Creating an appointment search")
        case "change_appointment_search": String(localized: "Changing an appointment search")
        case "run_appointment_search": String(localized: "Starting an appointment search")
        case "get_appointment_slot": String(localized: "Reading a slot")
        case "book_appointment_slot": String(localized: "Marking a slot as booked")
        default: nil
        }
    }

    /// The tools that read or note down what the documents know.
    private static func knowledgeLabel(_ name: String) -> String? {
        switch name {
        case "search_knowledge": String(localized: "Searching the knowledge base")
        case "read_knowledge": String(localized: "Reading a document")
        case "knowledge_values": String(localized: "Reading values from the documents")
        case "view_knowledge_pages": String(localized: "Looking at a document’s pages")
        case "edit_knowledge_notes": String(localized: "Suggesting notes for the knowledge folder")
        case "edit_memories": String(localized: "Suggesting what to remember")
        default: nil
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

    // MARK: Reading arguments

    /// The app's language: German quotes and dates for "de".
    static var isGerman: Bool { (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("de") }

    // The caches and patterns live in the type itself: Swift allows stored properties only in a
    // type's own declaration, not in the extension that reads a call's parts.

    /// A uuid: an id the model passed, not a name worth reading.
    static let uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

    /// How a day is written in a tool call: "2026-03-04".
    static let dayPattern = /^\d{4}-\d{2}-\d{2}$/

    /// Formatters by template (and the locale they were made for): making one takes long, and a
    /// chat's tool rows ask for them every time they're drawn.
    static var formatters: [String: DateFormatter] = [:]
    static var intervalFormatters: [String: DateIntervalFormatter] = [:]

    static func str(_ value: JSONValue?) -> String {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A day the model passed ("" unless it reads as one).
    static func date(_ value: JSONValue?) -> String {
        guard let dayText = value?.stringValue, dayText.wholeMatch(of: dayPattern) != nil else { return "" }
        return dayText
    }

    /// An id or name the model passed: names are shown, ids (uuids) aren't worth reading.
    static func named(_ value: JSONValue?) -> String {
        let nameText = str(value)
        return nameText.isEmpty || nameText.wholeMatch(of: uuid) != nil ? "" : nameText
    }

    static func quoted(_ value: String) -> String { isGerman ? "„\(value)“" : "“\(value)”" }

    /// A number the model passed, as text: whole numbers without their decimals.
    static func number(_ value: JSONValue?) -> String {
        switch value {
        case let .number(numeric): numeric == numeric.rounded() ? String(Int(numeric)) : String(numeric)
        case let .string(textValue): textValue
        default: ""
        }
    }

    /// A text that would read too long: its start and an ellipsis.
    static func short(_ value: String) -> String {
        value.count > 40 ? String(value.prefix(40)) + "…" : value
    }

    /// A counted phrase: "^[\(total) change](inflect: true)" in the app's language.
    static func counted(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value).characters)
    }

    /// The parts of an edit tool (reminders, calendars): how many ops, and the titles they touch.
    static func editParts(_ operations: [[String: JSONValue]]) -> [String] {
        let titles = operations.map { str($0["title"]) }.filter { !$0.isEmpty }
        var parts: [String] = []
        if !operations.isEmpty {
            let total = operations.count
            parts.append(counted("^[\(total) change](inflect: true)"))
        }
        parts.append(list(titles, max: 3))
        return parts
    }

    // MARK: Days

    static func noon(_ day: String) -> Date? {
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        guard dayParts.count == 3 else { return nil }
        let noon = DateComponents(year: dayParts[0], month: dayParts[1], day: dayParts[2], hour: 12)
        return Calendar.current.date(from: noon)
    }

    static func formatted(_ day: String, template: String) -> String {
        guard let dayDate = noon(day) else { return day }
        return formatter(template).string(from: dayDate)
    }

    static func formatter(_ template: String) -> DateFormatter {
        let key = Locale.current.identifier + "|" + template
        if let cached = formatters[key] { return cached }
        let newFormatter = DateFormatter()
        newFormatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = newFormatter
        return newFormatter
    }

    static func interval() -> DateIntervalFormatter {
        let key = Locale.current.identifier
        if let cached = intervalFormatters[key] { return cached }
        let newFormatter = DateIntervalFormatter()
        newFormatter.dateTemplate = "dMMMy"
        intervalFormatters[key] = newFormatter
        return newFormatter
    }

    static func lastOfMonth(_ day: String) -> Int {
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
    static func opsSpan(_ ops: [[String: JSONValue]]) -> String {
        let days = ops.flatMap { operation in
            (operation["dates"]?.arrayValue?.map { date($0) } ?? [])
                + [date(operation["from"]), date(operation["to"])]
        }.filter { !$0.isEmpty }.sorted()
        guard let first = days.first, let last = days.last else { return "" }
        return span(first, last)
    }

    // MARK: Words

    /// A few names in one line, with an ellipsis when there are more.
    static func list(_ names: [String], max: Int = 2) -> String {
        names.prefix(max).joined(separator: ", ") + (names.count > max ? " …" : "")
    }

    /// The names in order, each once and none empty.
    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

import Foundation

/// A place in a family the app can send the user to: a module, or something inside one (a
/// recipe, the meal plan, an appointment slot, a page of the settings). Screens open one with
/// `family.open(_:)`; the shell switches to its module, and the module's root takes it with
/// `family.takeRoute(for:)` and pushes what it names. Web links (`/f/{id}/…`, also as
/// `ohana://f/{id}/…`) map onto routes with `AppRoute(webPath:)`.
enum AppRoute: Hashable {
    case module(Module)

    // Overview
    /// The next two weeks' clashes (`/f/{id}/digest`, the weekly notification's link).
    case weekAhead
    // Calendar
    case calendarDay(Day)
    // Finance
    /// The transactions, optionally of one category.
    case financeTransactions(categoryID: String?)
    /// One transaction (its editor), over its month's transactions.
    case financeTransaction(id: String, day: Day)
    // Meals
    case recipe(id: String)
    /// The recipes on one list (`/f/{id}/meals/recipes`, a failed import's notification: "Want
    /// to try", where the import waits).
    case recipeList(RecipeListType)
    case cook(recipeID: String)
    case newRecipe
    case mealPlan
    case mealTags
    // Appointments
    case appointmentSearch(id: String)
    case appointmentSlot(searchID: String, resultID: String)
    case newAppointmentSearch
    // Chores
    /// One chore (its editor; read-only for viewers), over the chores of `day` (its occurrence, a
    /// notification's `?day=`; nil: today).
    case chore(id: String, day: Day? = nil)
    case newChore
    // Knowledge
    /// One document of the knowledge base (`/f/{id}/knowledge/{documentId}?page=`): `page` (from 1)
    /// shows that page's text, with `quote` marked in it (an assistant's source).
    case knowledgeDocument(id: String, page: Int? = nil, quote: String? = nil)
    // Assistant
    /// The assistant's page, optionally on one chat.
    case assistantChat(id: String?)
    // Settings
    case settings(SettingsPage)

    /// The module that shows the route.
    var module: Module {
        switch self {
        case let .module(module): module
        case .weekAhead: .overview
        case .calendarDay: .calendar
        case .financeTransactions, .financeTransaction: .finance
        case .recipe, .recipeList, .cook, .newRecipe, .mealPlan, .mealTags: .meals
        case .appointmentSearch, .appointmentSlot, .newAppointmentSearch: .appointments
        case .chore, .newChore: .chores
        case .knowledgeDocument: .knowledge
        case .assistantChat: .assistant
        case .settings: .settings
        }
    }

    /// The module the server must have on for the route: its own, or for a module's settings
    /// page that module.
    var requiredModule: Module {
        if case let .settings(page) = self, let owner = page.module { return owner }
        return module
    }
}

/// The pages of the family's settings a route can open.
enum SettingsPage: String, Hashable, CaseIterable {
    case members, home, notifications, calendar, finance, shopping, assistant, knowledge, data

    /// The module whose settings the page holds; nil for the family's own pages.
    var module: Module? {
        switch self {
        case .calendar: .calendar
        case .finance: .finance
        case .shopping: .meals
        case .assistant: .assistant
        case .knowledge: .knowledge
        case .members, .home, .notifications, .data: nil
        }
    }
}

extension AppRoute {
    /// The route of a web app path inside a family: `/f/{familyId}/meals/recipes/{id}` → `.recipe`.
    /// Returns the family's id too. Nil for paths outside a family.
    /// `tab`: the settings page's `?tab=` (the web's settings tabs); `day`: the `?day=` of a
    /// chore's link (its notification's); `page`: the `?page=` of a knowledge document's.
    static func parse(webPath path: String, tab: String? = nil, day: String? = nil,
                      page: String? = nil) -> (familyID: String, route: AppRoute)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "f" else { return nil }
        let familyID = parts[1]
        let rest = Array(parts.dropFirst(2))
        if rest.first == "settings", let page = settingsPage(tab: tab) { return (familyID, .settings(page)) }
        let pageNumber = page.flatMap { Int($0) }.flatMap { $0 >= 1 ? $0 : nil }
        return (familyID, route(rest, day: day.flatMap(Day.init), page: pageNumber))
    }

    /// A link's route with its query (`?tab=`, `?day=`, `?page=`): a path as an answer or a tool
    /// result names it ("/f/{id}/knowledge/{doc}?page=2"; a "#…" left out). Nil outside a family.
    static func parse(link: String) -> (familyID: String, route: AppRoute)? {
        var text = link
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        guard let mark = text.firstIndex(of: "?") else { return parse(webPath: text) }
        let items = URLComponents(string: "x:/?" + text[text.index(after: mark)...])?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        return parse(webPath: String(text[..<mark]), tab: value("tab"), day: value("day"), page: value("page"))
    }

    /// A URL's route with its query (a relative link in an answer).
    static func parse(url: URL) -> (familyID: String, route: AppRoute)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        return parse(webPath: components.path, tab: value("tab"), day: value("day"), page: value("page"))
    }

    /// The web's settings tabs (components/families/settings-tabs.tsx) as the app's pages.
    private static func settingsPage(tab: String?) -> SettingsPage? {
        switch tab {
        case "household": .members
        case "calendar", "feed": .calendar
        case "finance": .finance
        case "ai": .assistant
        case "knowledge": .knowledge
        case "data": .data
        default: nil
        }
    }

    private static func route(_ rest: [String], day: Day?, page: Int?) -> AppRoute {
        guard let first = rest.first else { return .module(.overview) }
        let at = { (i: Int) in rest.count > i ? rest[i] : nil }
        switch first {
        case "calendar":
            // `/calendar/{YYYY-MM-DD}`: a day (the widgets' links).
            return at(1).flatMap { Day($0) }.map { .calendarDay($0) } ?? .module(.calendar)
        case "finance":
            return .module(.finance)
        case "meals":
            switch at(1) {
            case "recipes":
                if let id = at(2), id != "new", id != "generate" { return .recipe(id: id) }
                return at(2) == "new" ? .newRecipe : .recipeList(.toTry)
            case "cook": return at(2).map { .cook(recipeID: $0) } ?? .module(.meals)
            // The shopping list lives in Reminders now: old links (and the reminders' own) open
            // the plan it comes from.
            case "plan", "shopping": return .mealPlan
            case "tags": return .mealTags
            default: return .module(.meals)
            }
        case "appointments":
            guard let search = at(1) else { return .module(.appointments) }
            if search == "new" { return .newAppointmentSearch }
            if at(2) == "slots", let result = at(3) { return .appointmentSlot(searchID: search, resultID: result) }
            return .appointmentSearch(id: search)
        case "chores":
            // `/chores/{id}?day=`: a chore on a day (its notification's link).
            guard let chore = at(1) else { return .module(.chores) }
            return chore == "new" ? .newChore : .chore(id: chore, day: day)
        case "knowledge":
            // `/knowledge/{documentId}?page=`: a document, at a page of its text.
            guard let document = at(1) else { return .module(.knowledge) }
            return .knowledgeDocument(id: document, page: page)
        case "assistant":
            return .assistantChat(id: nil)
        case "settings":
            return .module(.settings)
        case "digest":
            return .weekAhead
        default:
            return .module(.overview)
        }
    }
}

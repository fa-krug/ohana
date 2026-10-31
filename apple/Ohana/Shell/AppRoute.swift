import Foundation

/// A place in a family the app can send the user to: a module, or something inside one (a
/// recipe, a shopping list, an appointment slot, a page of the settings). Screens open one with
/// `family.open(_:)`; the shell switches to its module, and the module's root takes it with
/// `family.takeRoute(for:)` and pushes what it names. Web links (`/f/{id}/…`, also as
/// `ohana://f/{id}/…`) map onto routes with `AppRoute(webPath:)`.
enum AppRoute: Hashable {
    case module(Module)

    // Calendar
    case calendarDay(Day)
    // Finance
    /// The transactions, optionally of one category.
    case financeTransactions(categoryID: String?)
    // Meals
    case recipe(id: String)
    case cook(recipeID: String)
    case newRecipe
    case mealPlan
    /// A shopping list; nil: the latest one.
    case shoppingList(id: String?)
    case mealTags
    // Appointments
    case appointmentSearch(id: String)
    case appointmentSlot(searchID: String, resultID: String)
    case newAppointmentSearch
    // Assistant
    /// The assistant's page, optionally on one chat.
    case assistantChat(id: String?)
    // Settings
    case settings(SettingsPage)

    /// The module that shows the route.
    var module: Module {
        switch self {
        case let .module(module): module
        case .calendarDay: .calendar
        case .financeTransactions: .finance
        case .recipe, .cook, .newRecipe, .mealPlan, .shoppingList, .mealTags: .meals
        case .appointmentSearch, .appointmentSlot, .newAppointmentSearch: .appointments
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
    case members, home, notifications, calendar, finance, assistant, data

    /// The module whose settings the page holds; nil for the family's own pages.
    var module: Module? {
        switch self {
        case .calendar: .calendar
        case .finance: .finance
        case .assistant: .assistant
        case .members, .home, .notifications, .data: nil
        }
    }
}

extension AppRoute {
    /// The route of a web app path inside a family: `/f/{familyId}/meals/recipes/{id}` → `.recipe`.
    /// Returns the family's id too. Nil for paths outside a family.
    /// `tab`: the settings page's `?tab=` (the web's settings tabs).
    static func parse(webPath path: String, tab: String? = nil) -> (familyID: String, route: AppRoute)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "f" else { return nil }
        let familyID = parts[1]
        let rest = Array(parts.dropFirst(2))
        if rest.first == "settings", let page = settingsPage(tab: tab) { return (familyID, .settings(page)) }
        return (familyID, route(rest))
    }

    /// The web's settings tabs (components/families/settings-tabs.tsx) as the app's pages.
    private static func settingsPage(tab: String?) -> SettingsPage? {
        switch tab {
        case "household": .members
        case "calendar", "feed": .calendar
        case "finance": .finance
        case "ai": .assistant
        case "data": .data
        default: nil
        }
    }

    private static func route(_ rest: [String]) -> AppRoute {
        guard let first = rest.first else { return .module(.overview) }
        let at = { (i: Int) in rest.count > i ? rest[i] : nil }
        switch first {
        case "calendar":
            return .module(.calendar)
        case "finance":
            return .module(.finance)
        case "meals":
            switch at(1) {
            case "recipes":
                if let id = at(2), id != "new", id != "generate" { return .recipe(id: id) }
                return at(2) == "new" ? .newRecipe : .module(.meals)
            case "cook": return at(2).map { .cook(recipeID: $0) } ?? .module(.meals)
            case "plan": return .mealPlan
            case "shopping": return .shoppingList(id: at(2))
            case "tags": return .mealTags
            default: return .module(.meals)
            }
        case "appointments":
            guard let search = at(1) else { return .module(.appointments) }
            if search == "new" { return .newAppointmentSearch }
            if at(2) == "slots", let result = at(3) { return .appointmentSlot(searchID: search, resultID: result) }
            return .appointmentSearch(id: search)
        case "assistant":
            return .assistantChat(id: nil)
        case "settings":
            return .module(.settings)
        default:
            return .module(.overview)
        }
    }
}

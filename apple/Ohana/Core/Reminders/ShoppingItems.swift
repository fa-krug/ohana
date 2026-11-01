import Foundation

// What the meal plan needs from the shops (server/lib/meals/queries/shopping.ts): computed live
// per shopping day, never kept on the server. The app writes it into a Reminders list
// (`ShoppingReminders`); there is no shopping list in the app.

/// GET /meals/shopping?from=&lang=: every shopping day from `from` on with what it needs.
struct ShoppingNeeds: Codable, Hashable {
    let days: [ShoppingDay]
}

struct ShoppingDay: Codable, Hashable {
    let date: Day
    /// By name in the asked language.
    let items: [ShoppingItem]
}

/// One ingredient in one unit, summed over the day's meals.
struct ShoppingItem: Codable, Hashable {
    /// "{ingredientId}-{unitId}": the same for the ingredient and unit on that day whatever the
    /// plan's changes.
    let key: String
    let ingredientId: Int
    let name: String
    /// PRODUCE | DAIRY | MEAT | PANTRY | FROZEN | OTHER
    let category: String
    /// A decimal string, e.g. "150" or "2.5".
    let quantity: String
    /// The unit's abbreviation ("g", "Stk").
    let unit: String

    /// "150 g Tomato": the reminder's title.
    func label(locale: Locale = .current) -> String {
        Self.label(quantity: quantity, unit: unit, name: name, locale: locale)
    }

    static func label(quantity: String, unit: String, name: String, locale: Locale = .current) -> String {
        [ShoppingQuantity.format(quantity, locale: locale), unit, name].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func with(quantity: String) -> ShoppingItem {
        ShoppingItem(key: key, ingredientId: ingredientId, name: name, category: category, quantity: quantity, unit: unit)
    }
}

nonisolated enum ShoppingQuantity {
    /// At most two decimals, no trailing zeros, in the user's number format ("2,5" in German).
    static func format(_ quantity: String, locale: Locale = .current) -> String {
        guard let value = Double(quantity) else { return quantity }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
    }
}

/// What marks a reminder as one the shopping sync wrote: its url,
/// `ohana://f/{familyId}/meals/shopping/{date}/{key}?q={quantity}&t={title}`. The path names the
/// item (`path`: "{date}/{key}"), `q` the quantity it was written with and `t` the title it was
/// given, so the sync can tell whether the user changed it since (then it's theirs). Opening the
/// url shows the meal plan (`AppRoute.parse`).
struct ShoppingReminderMarker: Hashable {
    var familyID: String
    var date: Day
    var key: String
    var quantity: String
    /// The title Ohana gave it.
    var title: String

    /// "{date}/{key}": the item, whatever its quantity.
    var path: String { Self.path(date: date, key: key) }

    static func path(date: Day, key: String) -> String { "\(date)/\(key)" }

    var url: URL {
        var components = URLComponents()
        components.scheme = "ohana"
        components.host = "f"
        components.path = "/\(familyID)/meals/shopping/\(date)/\(key)"
        components.queryItems = [URLQueryItem(name: "q", value: quantity), URLQueryItem(name: "t", value: title)]
        return components.url!
    }

    init(familyID: String, date: Day, key: String, quantity: String, title: String) {
        self.familyID = familyID
        self.date = date
        self.key = key
        self.quantity = quantity
        self.title = title
    }

    /// The marker of a reminder's url; nil for any other url.
    init?(url: URL?) {
        guard let url, url.scheme == "ohana", url.host() == "f",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard parts.count == 5, parts[1] == "meals", parts[2] == "shopping", let date = Day(parts[3]),
              parts[3].count == 10, !parts[4].isEmpty else { return nil }
        let query = components.queryItems ?? []
        guard let quantity = query.first(where: { $0.name == "q" })?.value,
              let title = query.first(where: { $0.name == "t" })?.value else { return nil }
        self.init(familyID: parts[0], date: date, key: parts[4], quantity: quantity, title: title)
    }
}

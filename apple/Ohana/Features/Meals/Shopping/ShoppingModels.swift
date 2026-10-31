import Foundation

// The shopping lists as the server sends them (server/lib/meals/app-routes-plan.ts and
// server/lib/meals/queries/shopping.ts, server/lib/finance/groceries.ts for the spend).

/// GET /meals/shopping
struct ShoppingOverview: Codable {
    /// Every list of the family, latest shopping day first.
    let lists: [ShoppingListSummary]
    /// The list the web's shopping page shows: of the newest iteration, its first shopping day.
    let latest: ShoppingList?
}

struct ShoppingListSummary: Codable, Identifiable, Hashable {
    let id: String
    let iterationId: String
    /// ACTIVE | ARCHIVED
    let iterationStatus: String
    let shoppingDate: Day?
    let itemCount: Int
    let checkedCount: Int
}

/// GET /meals/shopping/lists/{id}
struct ShoppingListResponse: Codable {
    let list: ShoppingList
}

/// `ShoppingListView` (web).
struct ShoppingList: Codable, Identifiable, Hashable {
    let id: String
    let shoppingDate: Day?
    let createdAt: String?
    var items: [ShoppingItem]
}

/// `ShoppingItemDto` (web).
struct ShoppingItem: Codable, Identifiable, Hashable {
    let id: String
    let ingredientName: String
    /// PRODUCE | DAIRY | MEAT | PANTRY | FROZEN | OTHER
    let category: String
    /// A decimal string, e.g. "150" or "2.5".
    let quantity: String
    let unitAbbreviation: String
    var isChecked: Bool

    /// "150 g Tomato"
    func label(locale: Locale = .current) -> String {
        "\(ShoppingQuantity.format(quantity, locale: locale)) \(unitAbbreviation) \(ingredientName)"
    }
}

/// GET /meals/shopping/lists/{id}/spent (`ShoppingSpend`).
struct ShoppingSpend: Codable {
    struct Category: Codable, Hashable {
        let id: String
        let name: String
        let icon: String
        let color: String
    }

    struct Transaction: Codable, Identifiable, Hashable {
        let id: String
        let date: Day
        let payee: String
        let description: String
        let amountCents: Int
    }

    let currency: String
    /// Null when the finances have no groceries category.
    let category: Category?
    let from: Day
    let to: Day
    let transactions: [Transaction]
    /// What was spent (expenses minus refunds); positive.
    let totalCents: Int
}

/// GET /meals/shopping/units
struct ShoppingUnitsResponse: Codable {
    let units: [ShoppingUnit]
}

struct ShoppingUnit: Codable, Identifiable, Hashable {
    let id: Int
    let abbreviation: String
    let nameEn: String
    let nameDe: String

    var name: String { MealPlanLanguage.current == "de" ? nameDe : nameEn }
}

/// POST /meals/shopping/lists/{id}/items
struct ShoppingAddItemInput: Codable {
    let name: String
    let quantity: String
    let unitId: Int
    let category: String?
}

struct ShoppingAddItemResult: Codable {
    let id: String
    let merged: Bool
    let previousQuantity: String?
}

/// POST /meals/shopping/check
struct ShoppingCheckInput: Codable {
    let ids: [String]
    let checked: Bool
}

/// POST /shopping/toggle (the route the web's offline queue replays; idempotent).
struct ShoppingSetInput: Codable {
    var kind = "set"
    let itemId: String
    let checked: Bool
}

/// PATCH /meals/shopping/items/{id}
struct ShoppingQuantityInput: Codable {
    let quantity: String
}

// MARK: Grouping and formatting

/// The web's `CATEGORY_ORDER`: the aisles in shopping order.
enum ShoppingCategory: String, CaseIterable, Identifiable {
    case produce = "PRODUCE", dairy = "DAIRY", meat = "MEAT", pantry = "PANTRY", frozen = "FROZEN", other = "OTHER"

    var id: String { rawValue }

    init(server: String) {
        self = ShoppingCategory(rawValue: server) ?? .other
    }

    var title: String {
        switch self {
        case .produce: String(localized: "Fruit & Veg")
        case .dairy: String(localized: "Dairy")
        case .meat: String(localized: "Meat & Fish")
        case .pantry: String(localized: "Pantry")
        case .frozen: String(localized: "Frozen")
        case .other: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .produce: "carrot"
        case .dairy: "cup.and.saucer"
        case .meat: "fish"
        case .pantry: "takeoutbag.and.cup.and.straw"
        case .frozen: "snowflake"
        case .other: "basket"
        }
    }
}

struct ShoppingCategoryGroup: Identifiable, Hashable {
    let category: ShoppingCategory
    /// Open items first, then ticked ones, each in the server's (alphabetical) order.
    let items: [ShoppingItem]

    var id: ShoppingCategory { category }
    var checkedCount: Int { items.filter(\.isChecked).count }
}

enum ShoppingGrouping {
    /// The items by aisle in the web's order; empty aisles left out.
    static func groups(_ items: [ShoppingItem]) -> [ShoppingCategoryGroup] {
        let byCategory = Dictionary(grouping: items) { ShoppingCategory(server: $0.category) }
        return ShoppingCategory.allCases.compactMap { category in
            guard let items = byCategory[category], !items.isEmpty else { return nil }
            return ShoppingCategoryGroup(category: category, items: items.filter { !$0.isChecked } + items.filter(\.isChecked))
        }
    }
}

enum ShoppingQuantity {
    /// At most two decimals, no trailing zeros, in the user's number format ("2,5" in German).
    static func format(_ quantity: String, locale: Locale = .current) -> String {
        guard let value = Double(quantity) else { return quantity }
        return value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
    }
}

enum ShoppingExport {
    /// The list as plain text for sharing: what is still to buy, by aisle.
    static func text(for list: ShoppingList, locale: Locale = .current) -> String {
        var lines: [String] = []
        if let day = list.shoppingDate {
            lines.append(String(localized: "Shopping for \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))"))
        } else {
            lines.append(String(localized: "Shopping list"))
        }
        let open = list.items.filter { !$0.isChecked }
        for group in ShoppingGrouping.groups(open.isEmpty ? list.items : open) {
            lines.append("")
            lines.append(group.category.title)
            for item in group.items { lines.append("• \(item.label(locale: locale))") }
        }
        return lines.joined(separator: "\n")
    }
}

import CoreTransferable
import UniformTypeIdentifiers

// What can be dragged inside the app (iPad and Mac): a recipe or a planned meal onto a day of
// the meal plan, a calendar event onto another day, a shopping item onto another list. Each has
// a type of its own, declared in the apps' Info.plists (project.yml, UTExportedTypeDeclarations),
// so other apps' text or files are never taken for one. Each payload names its family: a drop
// in a window showing another family is ignored.

extension UTType {
    nonisolated static let ohanaMeal = UTType(exportedAs: "de.fa-krug.ohana.meal")
    nonisolated static let ohanaCalendarEvent = UTType(exportedAs: "de.fa-krug.ohana.calendar-event")
    nonisolated static let ohanaShoppingItem = UTType(exportedAs: "de.fa-krug.ohana.shopping-item")
}

/// A recipe (from the meal plan's recipe list) or a planned meal (a day of the plan) dragged
/// onto a day of the meal plan.
nonisolated struct MealDragItem: Codable, Hashable, Sendable, Transferable {
    let familyID: String
    let recipeID: String
    let title: String
    /// The planned meal being dragged; nil for a recipe.
    var entryID: String?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ohanaMeal)
    }
}

/// A calendar event dragged onto another day.
nonisolated struct CalendarEventDragItem: Codable, Hashable, Sendable, Transferable {
    let familyID: String
    let eventID: String
    /// The day it was dragged from (one of the days it is on), "YYYY-MM-DD".
    let date: String
    /// The occurrence of a series it is (its original day, "YYYY-MM-DD"); nil for a single event.
    var occurrence: String? = nil

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ohanaCalendarEvent)
    }
}

/// A shopping item dragged onto another list.
nonisolated struct ShoppingItemDragItem: Codable, Hashable, Sendable, Transferable {
    let familyID: String
    let itemID: String
    /// The list it is on now.
    let listID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ohanaShoppingItem)
    }
}

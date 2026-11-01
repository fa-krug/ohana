import SwiftUI

/// GET /search: what matched the query across the modules (server lib/families/search.ts).
struct FamilySearchResult: Decodable, Hashable {
    var query: String
    var currency: String
    var results: [FamilySearchHit]
    /// How many more matched than are listed, by kind.
    var more: [String: Int]

    /// The hits by kind, in the server's order; kinds this app doesn't know are left out.
    var groups: [(kind: FamilySearchHit.Kind, hits: [FamilySearchHit])] {
        FamilySearchHit.Kind.allCases.compactMap { kind in
            let hits = results.filter { $0.kind == kind }
            return hits.isEmpty ? nil : (kind, hits)
        }
    }
}

struct FamilySearchHit: Decodable, Hashable, Identifiable {
    enum Kind: String, CaseIterable {
        case recipe, event, note, transaction, search, person, chat

        var title: LocalizedStringKey {
            switch self {
            case .recipe: "Recipes"
            case .event: "Events"
            case .note: "Notes"
            case .transaction: "Transactions"
            case .search: "Appointment searches"
            case .person: "People"
            case .chat: "Chats"
            }
        }

        var systemImage: String {
            switch self {
            case .recipe: "fork.knife"
            case .event: "calendar.badge.clock"
            case .note: "note.text"
            case .transaction: "banknote"
            case .search: "stethoscope"
            case .person: "person"
            case .chat: "bubble.left.and.text.bubble.right"
            }
        }

        /// The module the hit opens in.
        var module: Module {
            switch self {
            case .recipe: .meals
            case .event, .note: .calendar
            case .transaction: .finance
            case .search: .appointments
            case .person: .settings
            case .chat: .assistant
            }
        }
    }

    /// The server's kind; nil for one this app doesn't know yet.
    var kind: Kind? { Kind(rawValue: kindName) }
    let kindName: String
    /// The item's id (a note's is its day).
    let itemID: String
    let title: String
    let detail: String
    let day: Day?
    /// An event's start ("HH:MM"), nil all day.
    let time: String?
    let amountCents: Int?
    /// A person: a member with an account.
    let account: Bool?

    var id: String { "\(kindName)/\(itemID)" }

    enum CodingKeys: String, CodingKey {
        case kindName = "kind", itemID = "id", title, detail, day, time, amountCents, account
    }

    /// Where the hit opens (`FamilyContext.open`).
    var route: AppRoute? {
        switch kind {
        case .recipe: .recipe(id: itemID)
        case .event, .note: day.map { .calendarDay($0) }
        case .transaction: day.map { .financeTransaction(id: itemID, day: $0) }
        case .search: .appointmentSearch(id: itemID)
        case .person: .settings(.members)
        case .chat: .assistantChat(id: itemID)
        case nil: nil
        }
    }
}

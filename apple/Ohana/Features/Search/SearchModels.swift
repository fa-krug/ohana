import SwiftUI

/// GET /search: what matched the query across the modules (server lib/families/search.ts).
/// Decoded off the main thread (`OffMainDecodable`), its groups made once there too.
nonisolated struct FamilySearchResult: Decodable, Hashable, OffMainDecodable {
    let query: String
    let currency: String
    let results: [FamilySearchHit]
    /// How many more matched than are listed, by kind.
    let more: [String: Int]
    /// The hits by kind, in the server's order; kinds this app doesn't know are left out.
    let groups: [FamilySearchGroup]

    private enum CodingKeys: String, CodingKey { case query, currency, results, more }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        currency = try c.decode(String.self, forKey: .currency)
        results = try c.decode([FamilySearchHit].self, forKey: .results)
        more = try c.decode([String: Int].self, forKey: .more)
        groups = FamilySearchGroup.groups(results)
    }
}

/// The hits of one kind.
nonisolated struct FamilySearchGroup: Hashable, Sendable {
    let kind: FamilySearchHit.Kind
    let hits: [FamilySearchHit]

    static func groups(_ results: [FamilySearchHit]) -> [FamilySearchGroup] {
        let byKind = Dictionary(grouping: results.filter { $0.kind != nil }) { $0.kind! }
        return FamilySearchHit.Kind.allCases.compactMap { kind in
            byKind[kind].map { FamilySearchGroup(kind: kind, hits: $0) }
        }
    }
}

nonisolated struct FamilySearchHit: Decodable, Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case recipe, event, note, transaction, search, chore, person, chat, knowledge
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
    /// A note's icon (an SF Symbol's name), when it has one.
    let icon: String?
    /// A knowledge document found by its text: the page (from 1) of the best passage, and that
    /// passage's best part. (Its `detail` is its folder and tags, its `day` its date.)
    let page: Int?
    let snippet: String?

    var id: String { "\(kindName)/\(itemID)" }

    enum CodingKeys: String, CodingKey {
        case kindName = "kind", itemID = "id", title, detail, day, time, amountCents, account, icon, page, snippet
    }
}

@MainActor
extension FamilySearchHit.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .recipe: "Recipes"
        case .event: "Events"
        case .note: "Notes"
        case .transaction: "Transactions"
        case .search: "Appointment searches"
        case .chore: "Chores"
        case .person: "People"
        case .knowledge: "Knowledge"
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
        case .chore: "checklist.checked"
        case .person: "person"
        case .knowledge: "books.vertical"
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
        case .chore: .chores
        case .person: .settings
        case .knowledge: .knowledge
        case .chat: .assistant
        }
    }
}

@MainActor
extension FamilySearchHit {
    /// A knowledge document's file kind, for its icon (by its name).
    var fileKind: KnowledgeFileKind { KnowledgeFileKind(path: title) }

    /// Where the hit opens (`FamilyContext.open`).
    var route: AppRoute? {
        switch kind {
        case .recipe: .recipe(id: itemID)
        case .event, .note: day.map { .calendarDay($0) }
        case .transaction: day.map { .financeTransaction(id: itemID, day: $0) }
        case .search: .appointmentSearch(id: itemID)
        case .chore: .chore(id: itemID)
        case .person: .settings(.members)
        case .knowledge: .knowledgeDocument(id: itemID, page: page.flatMap { $0 >= 1 ? $0 : nil })
        case .chat: .assistantChat(id: itemID)
        case nil: nil
        }
    }
}

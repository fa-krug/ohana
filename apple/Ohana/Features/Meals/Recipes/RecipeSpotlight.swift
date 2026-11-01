import CoreSpotlight
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers

// The connected server's recipes in Spotlight (iOS and macOS): every family of the account,
// one item per recipe (title, description, tags as keywords). Indexed once the account is loaded
// and again for a family whose recipes changed (`FamilyContext.revision(.recipes)`); emptied in
// the demo, after signing out and while the server has Meals off. A result opens the recipe
// (`ohana://f/{familyId}/meals/recipes/{id}`, `AppModel.open`).

/// The identifiers of a recipe's Spotlight item: `recipe/{familyId}/{recipeId}`, in the domain
/// `recipes/{familyId}` (a family's items are replaced together).
nonisolated enum RecipeSpotlightID {
    static func make(familyID: String, recipeID: String) -> String {
        "recipe/\(familyID)/\(recipeID)"
    }

    static func parse(_ identifier: String) -> (familyID: String, recipeID: String)? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "recipe", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }

    static func domain(familyID: String) -> String { "recipes/\(familyID)" }

    /// The app's link of an item: `ohana://f/{familyId}/meals/recipes/{recipeId}`.
    static func url(for identifier: String) -> URL? {
        guard let (family, recipe) = parse(identifier),
              let f = family.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let r = recipe.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        // `DevicePairing.callbackScheme`, the app's own links.
        return URL(string: "ohana://f/\(f)/meals/recipes/\(r)")
    }
}

/// What Spotlight learns about one recipe: plain values, so the index is written off the main
/// actor.
nonisolated struct RecipeSpotlightEntry: Sendable, Equatable {
    let familyID: String
    let recipeID: String
    let title: String
    let description: String
    /// The tags (in both languages), the family's name.
    let keywords: [String]

    var identifier: String { RecipeSpotlightID.make(familyID: familyID, recipeID: recipeID) }
    var domain: String { RecipeSpotlightID.domain(familyID: familyID) }

    /// The item's attributes: title, description (else the tags), keywords.
    var attributes: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.title = title
        set.displayName = title
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        set.contentDescription = text.isEmpty ? (keywords.isEmpty ? nil : keywords.joined(separator: ", ")) : text
        set.keywords = keywords
        return set
    }

    var item: CSSearchableItem {
        let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: domain, attributeSet: attributes)
        // Recipes stay until the next sync replaces them.
        item.expirationDate = .distantFuture
        return item
    }
}

extension RecipeSpotlightEntry {
    init(recipe: RecipeSummary, familyID: String, familyName: String) {
        var keywords: [String] = []
        for name in recipe.tags.flatMap({ [$0.nameEn, $0.nameDe] }) + [familyName]
        where !name.isEmpty && !keywords.contains(name) {
            keywords.append(name)
        }
        self.init(familyID: familyID, recipeID: recipe.id, title: recipe.title, description: recipe.description,
                  keywords: keywords)
    }
}

/// Keeps Spotlight in step with the account (see the top of this file). One per app; the
/// windows' triggers (`RecipeSpotlightUpdates`, `RecipeSpotlightFamilyUpdates`) call it, and it
/// does each piece of work once, one after the other. Failures are logged, never shown.
final class RecipeSpotlight {
    static let shared = RecipeSpotlight()
    nonisolated static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "spotlight")
    /// No family is indexed beyond this many recipes (both lists together).
    static let limit = 2000

    /// What the index was last brought in line with.
    struct State: Hashable {
        /// Nil in the demo.
        var server: URL?
        var ready: Bool
        var meals: Bool
        var families: [String]

        init(_ app: AppModel) {
            server = app.isDemo ? nil : app.serverURL
            ready = app.phase == .ready && app.switching == nil
            meals = app.isEnabled(.meals)
            families = app.families.map(\.id)
        }
    }

    private var synced: State?
    /// The recipes revision last seen per family: a change reindexes that family.
    private var revisions: [String: Int] = [:]
    /// Bumped by every sync and emptying: older work that is still fetching doesn't write.
    private var generation = 0
    private var queue: Task<Void, Never>?

    /// Brings the index in line with the account: everything of every family once the account
    /// is loaded (again for another server or other families), nothing in the demo or with Meals
    /// off.
    func sync(_ app: AppModel) {
        let state = State(app)
        guard state != synced, CSSearchableIndex.isIndexingAvailable() else { return }
        guard state.server != nil, state.meals else {
            // Only once per change: the demo's refreshes don't delete again.
            if let synced, synced.server == nil || !synced.meals { self.synced = state; return }
            synced = state
            enqueue { _ in await Self.write(.all, entries: []) }
            return
        }
        guard state.ready, let client = app.client else { return }
        synced = state
        let families = app.families.map { (api: FamilyAPI(client: client, familyID: $0.id), name: $0.name) }
        enqueue { isCurrent in
            var entries: [RecipeSpotlightEntry] = []
            var failed: [String] = []
            for family in families {
                if let found = await Self.fetch(family.api, name: family.name) {
                    entries += found
                } else {
                    failed.append(family.api.familyID)
                }
            }
            guard isCurrent() else { return }
            if failed.isEmpty {
                await Self.write(.all, entries: entries)
            } else {
                // Keep what the index has of the families that didn't answer.
                let fetched = families.map(\.api.familyID).filter { !failed.contains($0) }
                await Self.write(.families(fetched), entries: entries)
            }
            Self.log.info("Indexed \(entries.count) recipes of \(families.count - failed.count) families")
        }
    }

    /// A family's recipes changed (`revision(.recipes)`): its items are replaced. The first
    /// revision seen only counts as the starting point (`sync` indexed it).
    func recipesChanged(in family: FamilyContext, revision: Int, app: AppModel) {
        let id = family.family.id
        let previous = revisions[id]
        revisions[id] = revision
        guard let previous, previous != revision, !app.isDemo, app.isEnabled(.meals),
              CSSearchableIndex.isIndexingAvailable() else { return }
        let api = family.api, name = family.family.name
        enqueue(supersedes: false) { isCurrent in
            guard let entries = await Self.fetch(api, name: name), isCurrent() else { return }
            await Self.write(.families([api.familyID]), entries: entries)
        }
    }

    /// Runs `work` after the work before it; `isCurrent` says no newer work replaced it meanwhile.
    /// Work that `supersedes` (a sync of everything, emptying the index) replaces all work
    /// before it; a family's update replaces nothing (it runs after a sync already queued).
    private func enqueue(supersedes: Bool = true,
                         _ work: @escaping (_ isCurrent: @escaping () -> Bool) async -> Void) {
        if supersedes { generation += 1 }
        let mine = generation
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await work { self?.generation == mine }
        }
    }

    /// Both lists of a family, page by page; nil when the server didn't answer.
    private static func fetch(_ api: FamilyAPI, name: String) async -> [RecipeSpotlightEntry]? {
        var recipes: [RecipeSummary] = []
        do {
            for list in RecipeListType.allCases {
                let query = RecipeListModel.Query(list: list, query: "", sort: .nameAsc, tags: [])
                var offset = 0
                while recipes.count < limit {
                    let page: RecipeListPage = try await api.get(
                        "/meals/recipes", query: RecipeListModel.parameters(query, offset: offset, limit: 100))
                    recipes += page.items
                    offset += page.items.count
                    if page.items.isEmpty || offset >= page.totalCount { break }
                }
            }
        } catch {
            log.error("Can't load the recipes for Spotlight: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return recipes.prefix(limit).map { RecipeSpotlightEntry(recipe: $0, familyID: api.familyID, familyName: name) }
    }

    nonisolated enum Scope: Sendable {
        case all
        case families([String])
    }

    /// Replaces the items of `scope` with `entries`, off the main actor.
    @concurrent
    private nonisolated static func write(_ scope: Scope, entries: [RecipeSpotlightEntry]) async {
        let index = CSSearchableIndex.default()
        do {
            switch scope {
            case .all:
                try await index.deleteAllSearchableItems()
            case let .families(ids):
                guard !ids.isEmpty else { break }
                try await index.deleteSearchableItems(withDomainIdentifiers: ids.map { RecipeSpotlightID.domain(familyID: $0) })
            }
            if !entries.isEmpty {
                try await index.indexSearchableItems(entries.map(\.item))
            }
        } catch {
            log.error("Spotlight index failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: Triggers

/// The account's side (the app's root, every window): `RecipeSpotlight.sync` whenever the
/// server, the families, Meals or the loading state change.
struct RecipeSpotlightUpdates: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        content.task(id: RecipeSpotlight.State(app)) { RecipeSpotlight.shared.sync(app) }
    }
}

/// The family's side (inside the shell, with the family's context): its recipes changing
/// reindexes it, a moment later so a burst of changes counts once.
struct RecipeSpotlightFamilyUpdates: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(FamilyContext.self) private var family

    func body(content: Content) -> some View {
        content.task(id: family.revision(.recipes)) {
            let revision = family.revision(.recipes)
            // The first value is the starting point; later ones wait out a burst.
            if RecipeSpotlight.shared.hasSeen(family) {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
            }
            RecipeSpotlight.shared.recipesChanged(in: family, revision: revision, app: app)
        }
    }
}

extension RecipeSpotlight {
    fileprivate func hasSeen(_ family: FamilyContext) -> Bool { revisions[family.family.id] != nil }
}

// MARK: Opening a result

extension AppModel {
    /// Opens a Spotlight result (`CSSearchableItemActivityIdentifier`): the recipe, in its family.
    /// At launch it waits for the account to load first.
    func openSpotlightItem(_ identifier: String) async {
        guard let url = RecipeSpotlightID.url(for: identifier) else { return }
        var waited = 0
        while phase != .ready || switching != nil, waited < 150 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        if !open(url) {
            RecipeSpotlight.log.error("Can't open the Spotlight result \(identifier, privacy: .public)")
        }
    }
}

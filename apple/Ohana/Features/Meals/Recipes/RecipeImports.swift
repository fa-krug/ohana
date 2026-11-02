import SwiftUI

/// The recipe imports the server's worker is doing or failed at (GET /meals/recipes/imports): the
/// pages shared to Ohana, shown as placeholders on "Want to try" until their recipe is there. A
/// finished import leaves the list; then the recipes reload (`didChange(.recipes)`).
@Observable
final class RecipeImports {
    /// What the polling task waits on: it starts over for another family, a change of the
    /// recipes, the page coming on screen and a retried import.
    struct Load: Hashable {
        var familyID: String
        var revision: Int
        var active: Bool
        var restarts: Int
    }

    struct Answer: Decodable { let imports: [RecipeImportJob] }
    struct Started: Decodable { let `import`: RecipeImportJob }

    /// How often the list is asked again while an import is under way.
    static let pollInterval: Duration = .seconds(3)

    private(set) var items: [RecipeImportJob] = []
    /// Grows when an import is retried, so the polling starts again.
    private(set) var restarts = 0

    var pendingCount: Int { items.count(where: { !$0.isFailed }) }

    /// Some import that was under way is gone from the list: its recipe was saved.
    static func finished(before: [RecipeImportJob], after: [RecipeImportJob]) -> Bool {
        let now = Set(after.map(\.id))
        return before.contains { !$0.isFailed && !now.contains($0.id) }
    }

    /// Loads the list (a failure keeps what's shown: it's background work) and tells the family
    /// when an import finished.
    func reload(_ family: FamilyContext) async {
        guard let answer: Answer = try? await family.api.get("/meals/recipes/imports") else { return }
        let finished = Self.finished(before: items, after: answer.imports)
        items = answer.imports
        if finished { family.didChange(.recipes, .meals) }
    }

    /// Loads, then asks again every few seconds while an import is under way (until cancelled).
    func poll(_ family: FamilyContext) async {
        await reload(family)
        while pendingCount > 0, !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            if Task.isCancelled { return }
            await reload(family)
        }
    }

    /// A failed import again (editors).
    func retry(_ job: RecipeImportJob, _ family: FamilyContext) async {
        do {
            let started: Started = try await family.api.send(.post, "/meals/recipes/imports/\(job.id)/retry")
            if let index = items.firstIndex(where: { $0.id == job.id }) { items[index] = started.import }
            restarts += 1
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// Drops a failed import (editors).
    func remove(_ job: RecipeImportJob, _ family: FamilyContext) async {
        do {
            try await family.api.perform(.delete, "/meals/recipes/imports/\(job.id)")
            items.removeAll { $0.id == job.id }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }
}

extension RecipeImportJob {
    /// The page's title, else its host.
    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return URL(string: url)?.host() ?? url
    }
}

/// An import on "Want to try", the size of a `RecipeCard`: the page's photo dimmed with a
/// spinner while the server reads it; when it failed, why, and for editors Try Again / Remove.
struct RecipeImportCard: View {
    let job: RecipeImportJob
    let canEdit: Bool
    var retry: () -> Void = {}
    var remove: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let url = job.imageUrl.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill().blur(radius: 6) } placeholder: { RecipePhotoPlaceholder() }
                } else {
                    RecipePhotoPlaceholder()
                }
                Color.black.opacity(0.3)
                if job.isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: job.displayTitle)
                    .font(.headline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if job.isFailed {
                    Group {
                        if let error = job.error, !error.isEmpty {
                            Text(verbatim: error)
                        } else {
                            Text("Ohana couldn’t read a recipe from this page.")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if canEdit {
                        HStack {
                            Button("Try again", systemImage: "arrow.clockwise", action: retry)
                            Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                } else {
                    Text("Reading the recipe…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentCard(cornerRadius: 22, padding: 0)
        .clipShape(.rect(cornerRadius: 22))
        .contentShape(.rect(cornerRadius: 22))
        .contextMenu {
            if job.isFailed, canEdit {
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }
}

/// Above Favourites while imports are under way: how many, and a tap shows them on "Want to try".
struct RecipeImportsBanner: View {
    let count: Int
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Importing \(count) recipes into “Want to try”")
                    .font(.subheadline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentCard(cornerRadius: 14, padding: 12)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

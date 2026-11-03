import Foundation
import Observation
import SwiftUI

/// Saving a shared page as a recipe: reads what the share sheet handed over, finds the family (the
/// one the app shows) and whether the page is a recipe, asks, then hands the page to the server,
/// which imports it in the background (the app shows it as a placeholder meanwhile).
@Observable
final class ShareModel {
    /// What the page turned out to be.
    enum Recognition: Equatable {
        /// The page's schema.org Recipe: its name and photo, when it has them.
        case recipe(name: String?, imageUrl: String?)
        case notRecipe
        /// The page couldn't be looked at.
        case unknown
    }

    enum State: Equatable {
        case checking
        case asking(Recognition)
        case sending
        case failed(String)
    }

    private(set) var state: State = .checking
    private(set) var pageTitle: String?
    private(set) var pageHost: String?
    private(set) var familyName: String?
    private var page = SharedPage()
    private var target: (connection: SharedConnection, familyID: String)?
    /// The photo the preview found (macOS, other apps: Safari's script didn't run).
    private var previewImage: String?
    private var task: Task<Void, Never>?

    /// Called with true when the user is done, false when they cancel.
    var finish: (Bool) -> Void = { _ in }
    private var finished = false

    func start(_ items: [NSExtensionItem]) {
        guard task == nil else { return }
        task = Task { await check(items) }
    }

    private func check(_ items: [NSExtensionItem]) async {
        guard let connection = SharedConnection.load() else {
            state = .failed(SharedError.notConnected.localizedDescription)
            return
        }
        page = await SharedPage.read(items)
        pageTitle = page.title
        pageHost = page.url?.host()
        guard let url = page.url else {
            state = .failed(page.preprocessed
                ? String(localized: "Safari couldn’t hand over this page. Reload it and share it again.")
                : String(localized: "Ohana can only save web pages."))
            return
        }
        do {
            let family = try await connection.family()
            familyName = family.name
            target = (connection, family.id)
            async let status = connection.mealsStatus(familyID: family.id)
            async let recognition = recognize(url, connection: connection, familyID: family.id)
            guard try await status.generate else {
                state = .failed(String(localized: "Ohana’s assistant isn’t set up yet. Set it up in Ohana’s settings first."))
                return
            }
            state = .asking(await recognition)
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Safari's script read the page: decided here. Otherwise the server looks (a failing or slow
    /// look leaves it unknown).
    private func recognize(_ url: URL, connection: SharedConnection, familyID: String) async -> Recognition {
        if let recipe = page.recipe {
            return recipe ? .recipe(name: page.recipeName, imageUrl: page.recipeImage ?? page.imageUrl) : .notRecipe
        }
        guard let preview = try? await connection.previewRecipe(familyID: familyID,
                                                                RecipePreviewRequest(url: url, title: page.title)) else {
            return .unknown
        }
        previewImage = preview.imageUrl
        let title = preview.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if pageTitle == nil, !title.isEmpty { pageTitle = title }
        return preview.recipe ? .recipe(name: title.isEmpty ? nil : title, imageUrl: preview.imageUrl) : .notRecipe
    }

    /// Hands the page to the server, which imports it in the background, and closes.
    func save() {
        guard case let .asking(recognition) = state, let target, let url = page.url else { return }
        var name: String?
        var image: String?
        if case let .recipe(recipeName, recipeImage) = recognition { (name, image) = (recipeName, recipeImage) }
        let request = RecipeImportRequest(url: url, text: page.text, title: name ?? pageTitle,
                                          imageUrl: image ?? page.imageUrl ?? previewImage, background: true)
        state = .sending
        task = Task {
            do {
                _ = try await target.connection.startImport(familyID: target.familyID, request)
                done()
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        close(false)
    }

    func done() { close(true) }

    private func close(_ done: Bool) {
        guard !finished else { return }
        finished = true
        finish(done)
    }
}

/// The extension's sheet: the page, the family, the question, and how the handing over goes.
struct ShareView: View {
    let model: ShareModel

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle("Save to Ohana")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    switch model.state {
                    case .checking, .asking, .sending:
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", role: .cancel) { model.cancel() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if case let .asking(recognition) = model.state {
                                saveButton(recognition)
                            } else {
                                ProgressView()
                            }
                        }
                    case .failed:
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { model.cancel() }
                        }
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text("Save to Ohana")
                .font(.headline)
            content
            HStack {
                Spacer()
                switch model.state {
                case .checking, .asking, .sending:
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                    if case let .asking(recognition) = model.state { saveButton(recognition) }
                case .failed:
                    Button("Close") { model.cancel() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private func saveButton(_ recognition: ShareModel.Recognition) -> some View {
        Button(recognition == .notRecipe ? LocalizedStringKey("Try Anyway") : "Save", role: .confirm) { model.save() }
            .keyboardShortcut(.defaultAction)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case let .asking(recognition) = model.state {
                question(recognition)
            } else {
                pageLabel(name: nil, image: nil)
                family
                status
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The page (or its recipe): name, host, photo.
    @ViewBuilder
    private func pageLabel(name: String?, image: String?) -> some View {
        let title = name ?? model.pageTitle
        if title != nil || model.pageHost != nil {
            HStack(spacing: 12) {
                if let url = image.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { photo in
                        photo.resizable().scaledToFill()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(verbatim: title)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                    }
                    if let host = model.pageHost {
                        Text(verbatim: host)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var family: some View {
        if let family = model.familyName {
            Label {
                Text("For \(family)")
            } icon: {
                Image(systemName: "person.2")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func question(_ recognition: ShareModel.Recognition) -> some View {
        switch recognition {
        case let .recipe(name, image):
            Label("Recipe recognized", systemImage: "fork.knife")
                .font(.headline)
            pageLabel(name: name, image: image)
            family
            Text("Save it to Ohana?")
        case .notRecipe:
            Label("No recipe recognized", systemImage: "questionmark.circle")
                .font(.headline)
            pageLabel(name: nil, image: nil)
            family
            Text("Ohana’s AI can still try to read a recipe from this page.")
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            Text("Save this page as a recipe?")
                .font(.headline)
            pageLabel(name: nil, image: nil)
            family
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .checking:
            progress("Looking for a recipe…")
        case .sending:
            progress("Sending to Ohana…")
        case let .failed(message):
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .asking:
            EmptyView()
        }
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

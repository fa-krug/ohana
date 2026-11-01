import Foundation
import Observation
import SwiftUI

/// Saving a shared page as a recipe: reads what the share sheet handed over, asks the server for
/// the family (the one the app shows) and has the server import the page (its assistant reads it,
/// which can take a minute or two).
@Observable
final class ShareModel {
    enum State: Equatable {
        case working
        case saved(title: String)
        /// Taking the import back (the recipe is deleted).
        case undoing(title: String)
        case undone(title: String)
        case failed(String)
    }

    private(set) var state: State = .working
    private(set) var pageTitle: String?
    private(set) var pageHost: String?
    private(set) var familyName: String?
    /// The saved recipe and its family, for Undo.
    private var saved: (connection: SharedConnection, familyID: String, id: String)?
    private var task: Task<Void, Never>?

    /// Called with true when the user is done, false when they cancel.
    var finish: (Bool) -> Void = { _ in }

    var isFinished: Bool {
        switch state {
        case .working, .undoing: false
        case .saved, .undone, .failed: true
        }
    }

    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    func start(_ items: [NSExtensionItem]) {
        guard task == nil else { return }
        task = Task { await save(items) }
    }

    private func save(_ items: [NSExtensionItem]) async {
        guard let connection = SharedConnection.load() else {
            state = .failed(SharedError.notConnected.localizedDescription)
            return
        }
        let page = await SharedPage.read(items)
        pageTitle = page.title
        pageHost = page.url?.host()
        guard let url = page.url else {
            state = .failed(String(localized: "Ohana can only save web pages."))
            return
        }
        do {
            let family = try await connection.family()
            familyName = family.name
            let request = RecipeImportRequest(url: url, text: page.text, title: page.title, imageUrl: page.imageUrl)
            let recipe = try await connection.importRecipe(familyID: family.id, request)
            saved = (connection, family.id, recipe.id)
            state = .saved(title: recipe.title)
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Deletes the recipe just saved.
    func undo() {
        guard case let .saved(title) = state, let saved else { return }
        undoError = nil
        state = .undoing(title: title)
        task = Task {
            do {
                try await saved.connection.deleteRecipe(familyID: saved.familyID, id: saved.id)
                self.saved = nil
                state = .undone(title: title)
            } catch is CancellationError {
            } catch {
                // Still saved: back to it, with Undo to try again.
                state = .saved(title: title)
                undoError = error.localizedDescription
            }
        }
    }

    /// Why Undo didn't work (shown under the saved recipe).
    private(set) var undoError: String?

    func cancel() {
        task?.cancel()
        finish(false)
    }

    func done() { finish(true) }
}

/// The extension's sheet: the page, the family, and how the saving goes.
struct ShareView: View {
    let model: ShareModel

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Save to Ohana")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.isFinished {
                        ToolbarItem(placement: .confirmationAction) { finishButton }
                        if case .saved = model.state {
                            ToolbarItem(placement: .cancellationAction) { undoButton }
                        }
                    } else if case .undoing = model.state {
                        ToolbarItem(placement: .confirmationAction) { ProgressView() }
                    } else {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", role: .cancel) { model.cancel() }
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
                if case .saved = model.state { undoButton }
                Spacer()
                if model.isFinished {
                    finishButton
                } else if case .undoing = model.state {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private var undoButton: some View {
        Button("Undo", role: .destructive) { model.undo() }
    }

    @ViewBuilder
    private var finishButton: some View {
        if !model.isFailed {
            Button("Done") { model.done() }
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Close") { model.cancel() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.pageTitle != nil || model.pageHost != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = model.pageTitle {
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
            if let family = model.familyName {
                Label {
                    Text("For \(family)")
                } icon: {
                    Image(systemName: "person.2")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .working:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Ohana is reading the recipe. This can take a minute or two.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .saved(title):
            Label {
                Text("Saved “\(title)” to “Want to try”.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let error = model.undoError {
                Text(verbatim: error)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .undoing(title):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Removing “\(title)” …")
                    .foregroundStyle(.secondary)
            }
        case let .undone(title):
            Label {
                Text("“\(title)” was removed again.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label {
                Text(verbatim: message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Imports a recipe from a web page (POST /meals/recipes/import): the server fetches the page and
/// the family's AI turns it into a recipe, which the sheet then offers to open or to take back
/// (DELETE the recipe). Offered next to Generate, so only with the meals AI set up
/// (`MealsAIStatus.generate`) and to editors. Cancelling a running import cancels the request, and
/// the server saves nothing.
struct RecipeImportView: View {
    /// Called with the new recipe's id after the sheet closes.
    var onImported: (String) -> Void = { _ in }

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var importing = false
    /// The saved recipe: the sheet offers to open it or to undo the import.
    @State private var imported: ImportedRecipe?
    @State private var undoing = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var url: URL? { RecipeImportURL.parse(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Web address", text: $address, prompt: Text(verbatim: "https://…"))
                        .labelsHidden()
                        #if os(iOS)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { if url != nil { start() } }
                        .disabled(importing || imported != nil)
                } header: {
                    Text("Web address")
                } footer: {
                    Text("The page is read on your server and its AI turns it into a recipe. This can take a minute or two.")
                }
                if importing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Importing the recipe …").foregroundStyle(.secondary)
                        }
                    }
                }
                if let imported {
                    Section {
                        Label {
                            Text("Saved “\(imported.title)” to “Want to try”.")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        Button("Undo Import", systemImage: "arrow.uturn.backward", role: .destructive) { undo(imported) }
                            .disabled(undoing)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import from Web")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if imported != nil {
                        Button("Close") { dismiss() }
                            .disabled(undoing)
                    } else {
                        // A running import is cancelled: the server notices and saves nothing.
                        CancelButton(hasChanges: importing) { task?.cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if importing || undoing {
                        ProgressView()
                    } else if let imported {
                        Button("Open Recipe", role: .confirm) {
                            dismiss()
                            onImported(imported.id)
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Import", role: .confirm) { start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(url == nil)
                    }
                }
            }
        }
        .task {
            if address.isEmpty, let pasted = await RecipeImportURL.fromPasteboard() {
                address = pasted.absoluteString
            }
            focused = true
        }
        .onDisappear { task?.cancel() }
        .errorBanner()
        .discardGuard(hasChanges: importing)
        .presentationDetents([.medium, .large])
        .recipeSheetFrame(minWidth: 460, minHeight: 280)
    }

    private func start() {
        guard let url, !importing else { return }
        importing = true
        let api = family.api
        task = Task {
            defer { importing = false; task = nil }
            do {
                let client = api.client
                // The share extension's request (Shared/SharedConnection.swift), with just the
                // address: the server fetches the page.
                var req = client.request(.post, api.path("/meals/recipes/import"),
                                         body: try APIClient.encoder.encode(RecipeImportRequest(url: url)))
                // The server fetches the page and asks the model: this can take a while.
                req.timeoutInterval = SharedConnection.importTimeout
                let (data, _) = try await client.data(for: req)
                imported = try client.decode(ImportedRecipe.self, from: data)
                family.didChange(.recipes, .meals)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { ErrorBanner.shared.show(error) }
            }
        }
    }

    /// Takes the import back: deletes the recipe and closes the sheet.
    private func undo(_ recipe: ImportedRecipe) {
        guard !undoing else { return }
        undoing = true
        let api = family.api
        Task {
            defer { undoing = false }
            do {
                try await api.perform(.delete, "/meals/recipes/\(recipe.id)")
                family.didChange(.recipes, .meals, .mealPlan)
                ErrorBanner.shared.success(String(localized: "Import undone"))
                dismiss()
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }
}

/// The web address of the import sheet: typed, pasted or found on the pasteboard.
nonisolated enum RecipeImportURL {
    /// An http(s) address with a host; "example.com/recipe" gets https://. Nil for anything else.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        // Without a scheme, only something that looks like a domain.
        if !trimmed.contains("://"), !host.contains(".") { return nil }
        return url
    }

    /// The first http(s) link in a text (a copied address, or a message with one in it).
    static func firstWebURL(in text: String) -> URL? {
        if let url = parse(text) { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// A web address on the pasteboard. The pasteboard is read only when it holds one (asking
    /// that doesn't show the system's paste notice), so the notice comes only with a link.
    @MainActor
    static func fromPasteboard() async -> URL? {
        #if canImport(UIKit)
        let board = UIPasteboard.general
        if board.hasURLs, let url = board.url, let found = firstWebURL(in: url.absoluteString) { return found }
        guard board.hasStrings,
              let patterns = try? await board.detectedPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]),
              !patterns.isEmpty else { return nil }
        return board.string.flatMap(firstWebURL(in:))
        #else
        let board = NSPasteboard.general
        guard let patterns = try? await board.detectedPatterns(for: [\NSPasteboard.DetectedValues.probableWebURL]),
              !patterns.isEmpty else { return nil }
        return board.string(forType: .string).flatMap(firstWebURL(in:))
        #endif
    }
}

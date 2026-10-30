import SwiftUI
import UniformTypeIdentifiers

/// Settings → Data (the web's data-settings.tsx): the whole family as a JSON file (the calendar
/// of all years and the finances), and for editors importing such a file over it.
struct FamilyDataView: View {
    @Environment(FamilyContext.self) private var family
    let familyName: String
    let canEdit: Bool

    @State private var exporting = false
    @State private var exportDocument: FamilyExportDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: FamilyPendingImport?
    @State private var importing = false
    @State private var imported = false

    var body: some View {
        Form {
            Section {
                Button {
                    export()
                } label: {
                    HStack {
                        Label("Export", systemImage: "square.and.arrow.down")
                        Spacer()
                        if exporting { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(exporting)
            } header: {
                Text("Export")
            } footer: {
                Text("The whole family as a JSON file: the calendar of all years (entry types, entries, notes) and the finances (accounts, categories, transactions, settings). Viewers can export too.")
            }

            if canEdit {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        HStack {
                            Label("Import…", systemImage: "square.and.arrow.up")
                            Spacer()
                            if importing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(importing)
                } header: {
                    Text("Import")
                } footer: {
                    Text("Replaces the calendar (all years) and the finances of this family with those of an exported file; the name, the members and the links stay. Can’t be undone – export first to keep a copy.")
                }
            }
        }
        .formStyle(.grouped)
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("Data")
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: FamilyExportFile.fileName(familyName: familyName, today: .today)) { result in
            if case let .failure(error) = result { ErrorBanner.shared.show(error) }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): pick(url)
            case let .failure(error): ErrorBanner.shared.show(error)
            }
        }
        .confirmationDialog("Replace the family’s data?",
                            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                            titleVisibility: .visible, presenting: pendingImport) { pending in
            Button("Replace", role: .destructive) { runImport(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Replace the calendar and the finances of “\(familyName)” with the contents of “\(pending.fileName)”? All years, entry types, entries, notes and finances are overwritten; the name, the members and the links stay. This can’t be undone.")
        }
        .alert("Imported.", isPresented: $imported) {
            Button("OK", role: .cancel) {}
        }
    }

    private func export() {
        let api = family.api
        exporting = true
        Task {
            do {
                let (data, _) = try await api.client.data(for: api.client.request(.get, api.path("/export")))
                exportDocument = FamilyExportDocument(data: FamilyExportFile.pretty(data))
                showExporter = true
            } catch is CancellationError {
            } catch {
                ErrorBanner.shared.show(String(localized: "Couldn’t export the family: \(error.localizedDescription)"))
            }
            exporting = false
        }
    }

    private func pick(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), FamilyExportFile.isExportFile(data) else {
            ErrorBanner.shared.show(String(localized: "This isn’t a family export (a .json file from Settings → Data → Export)."))
            return
        }
        pendingImport = FamilyPendingImport(data: data, fileName: url.lastPathComponent)
    }

    private func runImport(_ pending: FamilyPendingImport) {
        let api = family.api
        importing = true
        Task {
            do {
                _ = try await api.client.data(for: api.client.request(.post, api.path("/import"), body: pending.data))
                family.didChange(.calendar, .events, .finance, .family)
                imported = true
            } catch is CancellationError {
            } catch {
                ErrorBanner.shared.show(String(localized: "Couldn’t import the file: \(error.localizedDescription)"))
            }
            importing = false
        }
    }
}

/// A picked export file waiting for the confirmation.
struct FamilyPendingImport {
    let data: Data
    let fileName: String
}

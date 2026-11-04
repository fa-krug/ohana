import SwiftUI

/// Settings → Knowledge: the family's knowledge folder on this device (choose, change, remove;
/// a marker of another family or a folder other than the family's asks first) and what's in the
/// index (GET /knowledge/status with the indexer's own state: running, waiting uploads, files this
/// device can't read), *Read Now*. Only where `FamilyContext.knowledgeAvailable` (module on, an
/// editor, not the demo).
struct KnowledgeSettingsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        Group {
            if family.knowledgeAvailable {
                KnowledgeSettingsForm(indexer: family.knowledge)
            } else {
                ContentUnavailableView("Not available", systemImage: "books.vertical")
            }
        }
        .ohanaBackground(ModuleTint.knowledge)
        .navigationTitle("Knowledge")
    }
}

/// A chosen folder that asks first (`KnowledgeFolderError`), and the folder to use anyway.
private struct KnowledgeLinkConflict {
    let url: URL
    let error: KnowledgeFolderError
}

private struct KnowledgeSettingsForm: View {
    @Environment(FamilyContext.self) private var family
    let indexer: KnowledgeIndexer

    @State private var folder: KnowledgeFolder.State = .none
    @State private var status: LoadState<KnowledgeStatusInfo> = .idle
    @State private var choosing = false
    @State private var linking = false
    @State private var conflict: KnowledgeLinkConflict?
    @State private var removing = false

    private var running: Bool {
        switch indexer.phase {
        case .scanning, .hashing, .uploading: true
        case .idle, .failed: false
        }
    }

    var body: some View {
        Form {
            folderSection
            if folder != .none || status.value?.folder != nil {
                indexSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .refreshable { await loadStatus() }
        .task { await loadStatus() }
        .onAppear { folder = indexer.folder.state() }
        .onChange(of: indexer.phase) { _, phase in
            // A run (or the uploads after it) finished: the server's counts changed.
            switch phase {
            case .idle, .failed:
                folder = indexer.folder.state()
                Task { await loadStatus() }
            case .scanning, .hashing, .uploading:
                break
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): link(url)
            case let .failure(error): ErrorBanner.shared.show(error)
            }
        }
        .alert(Text(verbatim: conflict?.error.localizedDescription ?? ""),
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
               presenting: conflict) { conflict in
            Button("Use This Folder") { link(conflict.url, accepted: conflict.error) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Stop reading this folder on this device?", isPresented: $removing,
                            titleVisibility: .visible) {
            Button("Remove from This Device", role: .destructive, action: unlink)
        }
    }

    // MARK: The folder

    private var folderSection: some View {
        Section {
            switch folder {
            case .none:
                Label("No folder chosen on this device", systemImage: "folder")
                    .foregroundStyle(.secondary)
                chooseButton("Choose Folder…")
            case .missing:
                Label("The folder can’t be found any more.", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
                chooseButton("Choose Again…")
                removeButton
            case .replaced:
                Label("Another device now reads a different folder.", systemImage: "folder.badge.minus")
                    .foregroundStyle(.orange)
                chooseButton("Choose Folder…")
                removeButton
            case let .linked(url, _):
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: FileManager.default.displayName(atPath: url.path))
                            .lineLimit(1)
                        if let place = KnowledgeFolderPlace.describe(url) {
                            Text(verbatim: place)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(ModuleTint.knowledge)
                }
                chooseButton("Change…")
                removeButton
            }
        } header: {
            Text("Folder")
        } footer: {
            Text("Only the files’ text goes to the family’s server, never the files.")
        }
    }

    private func chooseButton(_ title: LocalizedStringKey) -> some View {
        Button {
            choosing = true
        } label: {
            if linking {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .disabled(linking)
    }

    private var removeButton: some View {
        Button("Remove from This Device", role: .destructive) { removing = true }
            .disabled(linking)
    }

    /// Makes `url` the family's folder on this device (what the device kept of another goes),
    /// then reads it.
    private func link(_ url: URL, accepted: KnowledgeFolderError? = nil) {
        linking = true
        Task {
            defer { linking = false }
            do {
                try await indexer.link(url, accepted: accepted)
                folder = indexer.folder.state()
                family.indexKnowledge(force: true)
                await loadStatus()
            } catch let error as KnowledgeFolderError where error.asksFirst {
                conflict = KnowledgeLinkConflict(url: url, error: error)
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }

    private func unlink() {
        Task {
            await indexer.unlink()
            folder = indexer.folder.state()
        }
    }

    // MARK: The index

    @ViewBuilder
    private var indexSection: some View {
        Section("Index") {
            progress
            if case let .failed(message) = indexer.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !running, let run = indexer.lastRun {
                if run.files == 0 {
                    Label("The folder looks empty.", systemImage: "tray")
                        .foregroundStyle(.secondary)
                }
                if run.unhashable > 0 {
                    Label("\(run.unhashable) files couldn’t be loaded from iCloud.", systemImage: "icloud.slash")
                        .foregroundStyle(.orange)
                }
                if run.deferred > 0 {
                    Label("\(run.deferred) files wait to be loaded from iCloud.", systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
            }
            switch status {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case let .loaded(info), let .saved(info, _, _):
                counts(info)
            }
            if !indexer.unreadable.isEmpty {
                DisclosureGroup {
                    ForEach(indexer.unreadable.keys.sorted(), id: \.self) { path in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: path)
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let reason = indexer.unreadable[path]?.reason {
                                Text(verbatim: reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    Text("Files this device can’t read: \(indexer.unreadable.count)")
                }
            }
            if folder.url != nil {
                Button("Read Now", systemImage: "arrow.clockwise") { family.indexKnowledge(force: true) }
                    .disabled(running)
            }
        }
    }

    /// What the indexer is doing, while it runs.
    @ViewBuilder
    private var progress: some View {
        switch indexer.phase {
        case .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking through the folder…")
            }
        case let .hashing(done, total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Checking files")
            } currentValueLabel: {
                Text("\(done) of \(total)")
            }
        case let .uploading(done, total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Reading and sending")
            } currentValueLabel: {
                Text("\(done) of \(total)")
            }
        case .idle, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counts(_ info: KnowledgeStatusInfo) -> some View {
        LabeledContent("Documents") { Text(info.counts.ready, format: .number) }
        let waiting = info.counts.pending + indexer.waiting
        if waiting > 0 {
            LabeledContent("Waiting") { Text(waiting, format: .number) }
        }
        if info.counts.failed > 0 {
            LabeledContent("Failed") { Text(info.counts.failed, format: .number) }
        }
        if info.counts.missing > 0 {
            LabeledContent("Missing") { Text(info.counts.missing, format: .number) }
        }
        if let read = info.folder?.lastManifestAt.flatMap(Date.server) {
            LabeledContent("Last read") {
                Text(verbatim: lastRead(read, device: info.folder?.lastManifestDevice))
            }
        }
    }

    /// "2 hours ago · Anna’s iPhone"; this device by that name.
    private func lastRead(_ date: Date, device: String?) -> String {
        let when = date.formatted(.relative(presentation: .named))
        guard let device, !device.isEmpty else { return when }
        let name = KnowledgeDevice.isThisDevice(device, own: indexer.deviceName) ? String(localized: "This device") : device
        return "\(when) · \(name)"
    }

    private func loadStatus() async {
        await LoadState.run($status, family.api.knowledgeStatus())
    }
}

/// Settings → Knowledge's row: the folder on this device, or that there's none.
struct KnowledgeFolderStatus: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: KnowledgeFolder.State = .none

    var body: some View {
        Group {
            switch state {
            case let .linked(url, _): Text(verbatim: FileManager.default.displayName(atPath: url.path))
            case .missing: Text("Not found")
            case .replaced: Text("Replaced")
            case .none: Text("Off")
            }
        }
        .lineLimit(1)
        .task(id: family.knowledge.phase) { state = family.knowledge.folder.state() }
    }
}

private extension KnowledgeFolderError {
    /// Choosing the folder anyway is up to the user (`link(_:api:override:)`).
    var asksFirst: Bool {
        switch self {
        case .otherFamily, .otherFolder, .serverHasFolder: true
        case .unreadable, .missing, .notInFolder: false
        }
    }
}

/// Where a folder is, for people.
nonisolated enum KnowledgeFolderPlace {
    /// "iCloud Drive › Family" for a folder in iCloud Drive (its own name left out), else the name
    /// of the folder it's in; nil for iCloud Drive itself and the top of a disk.
    static func describe(_ folder: URL) -> String? {
        let parts = folder.standardizedFileURL.pathComponents
        if let drive = parts.lastIndex(of: "com~apple~CloudDocs"), drive > 0, parts[drive - 1] == "Mobile Documents" {
            guard drive < parts.count - 1 else { return nil }
            return (["iCloud Drive"] + parts[(drive + 1)..<(parts.count - 1)]).joined(separator: " › ")
        }
        let parent = folder.standardizedFileURL.deletingLastPathComponent()
        guard parent.path != "/", parent.path != folder.standardizedFileURL.path else { return nil }
        return FileManager.default.displayName(atPath: parent.path)
    }
}

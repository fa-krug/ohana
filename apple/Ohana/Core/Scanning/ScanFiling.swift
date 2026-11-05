import SwiftUI
import UniformTypeIdentifiers

/// "Save as PDF" for a scan, as the user sets it in `ScanFilingSection`: on or off (remembered per
/// kind), the name and tags (suggested, then the user's once edited) and the folder (remembered
/// for all scans; the family's knowledge folder instead while it's linked on this device:
/// `knowledge`). `save(_:)` writes the PDF.
@Observable
final class ScanFiling {
    let kind: ScanKind
    let settings: ScanFilingSettings
    /// The family's knowledge folder (`FamilyContext.scanKnowledge`); nil: the scan folder.
    @ObservationIgnored let knowledge: ScanKnowledge?

    var savesPDF: Bool {
        didSet { settings.setSavesPDF(savesPDF, for: kind) }
    }
    /// The file name without ".pdf".
    private(set) var name = ""
    private(set) var nameEdited = false
    private(set) var tags: [String] = []
    private(set) var tagsEdited = false
    private(set) var folder: ScanFolder
    private(set) var saving = false
    /// The PDF's file name once saved: saving again (a retry of what comes after) does nothing.
    private(set) var savedFile: String?
    /// The folder picker shows (from the section's button, or from saving without a folder).
    var choosingFolder = false
    /// What waits for a folder to be chosen (saving).
    private var afterFolder: (() -> Void)?

    init(kind: ScanKind, settings: ScanFilingSettings = ScanFilingSettings(), knowledge: ScanKnowledge? = nil) {
        self.kind = kind
        self.settings = settings
        self.knowledge = knowledge
        savesPDF = settings.savesPDF(kind)
        folder = knowledge?.folder ?? settings.folder()
    }

    /// Fills in what the user hasn't edited yet.
    func suggest(name: String? = nil, tags: [String]? = nil) {
        if let name, !nameEdited { self.name = name }
        if let tags, !tagsEdited { self.tags = ScanTags.cleaned(tags) }
    }

    func editName(_ value: String) {
        name = value
        nameEdited = true
    }

    /// Adds a tag (tidied; one that's there already isn't added again).
    func addTag(_ tag: String) {
        let added = ScanTags.cleaned(tags + [tag], limit: .max)
        guard added != tags else { return }
        tags = added
        tagsEdited = true
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        tagsEdited = true
    }

    /// The tags a scan may be suggested: those saved with a scan on this device, then those on the
    /// files in the folder (Finder / Files tags), then, in the knowledge folder, those of the
    /// family's documents on the server (its subfolders' too, other devices' files too).
    func existingTags() async -> [String] {
        let saved = settings.knownTags
        guard let folderURL = folder.url else { return saved }
        async let server = knowledgeTags()
        let inFolder = await Task.detached(priority: .userInitiated) { FolderTags.read(folderURL) }.value
        return ScanTags.cleaned(saved + inFolder + (await server), limit: .max)
    }

    private func knowledgeTags() async -> [String] {
        guard case .knowledge = folder, let knowledge else { return [] }
        return await knowledge.tags()
    }

    /// The tags used before that this scan hasn't got.
    var recentTags: [String] {
        let current = Set(tags.map { $0.lowercased() })
        return settings.recentTags.filter { !current.contains($0.lowercased()) }
    }

    // MARK: The folder

    var folderName: String? {
        folder.url.map { FileManager.default.displayName(atPath: $0.path) }
    }

    /// The scans go into the knowledge folder: no folder to choose.
    var inKnowledge: Bool {
        if case .knowledge = folder { true } else { false }
    }

    /// Saving needs a folder first.
    var needsFolder: Bool { savesPDF && savedFile == nil && folder.url == nil }

    /// Shows the folder picker; `then` runs once a folder is chosen.
    func chooseFolder(then: (() -> Void)? = nil) {
        afterFolder = then
        choosingFolder = true
    }

    func folderChosen(_ result: Result<URL, any Error>) {
        let next = afterFolder
        afterFolder = nil
        do {
            try settings.rememberFolder(result.get())
            folder = settings.folder()
            guard folder.url != nil else { throw ScanFilingError.folderMissing }
            next?()
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    // MARK: Saving

    /// Saves `pages` as a PDF when "Save as PDF" is on; returns its file name (nil when off or
    /// saved before). In the knowledge folder the file is queued for the index with the pages'
    /// text (`ScanKnowledge.enqueue`: on the device, the upload follows by itself).
    @discardableResult
    func save(_ pages: [ScanPage]) async throws -> String? {
        guard savesPDF, savedFile == nil else { return nil }
        guard let folderURL = folder.url else {
            throw folder == .missing ? ScanFilingError.folderMissing : ScanFilingError.noFolder
        }
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".pdf") { title = String(title.dropLast(4)) }
        let tags = tags, pdfTitle = title
        saving = true
        defer { saving = false }
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try ScanFiler.save(ScanPDF.make(pages: pages, title: pdfTitle, tags: tags), name: pdfTitle,
                                   tags: tags, in: folderURL)
            }.value
            settings.remember(tags: tags)
            savedFile = file.lastPathComponent
            if case .knowledge = folder, let knowledge { await knowledge.queue(file, pages: pages) }
            return file.lastPathComponent
        } catch ScanFilingError.folderMissing {
            folder = .missing
            throw ScanFilingError.folderMissing
        }
    }

    /// Saves (asking for a folder first when there's none), then runs `done`; errors go to the
    /// banner and `done` doesn't run.
    func saveThen(_ pages: @escaping () -> [ScanPage], done: @escaping () -> Void) {
        if needsFolder {
            chooseFolder { [weak self] in self?.saveThen(pages, done: done) }
            return
        }
        Task {
            do {
                try await save(pages())
                done()
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }
}

/// The family's knowledge folder as scans see it (`FamilyContext.scanKnowledge`): while it's linked
/// on this device, scans are saved in its root (no folder picker) and queued for the index with
/// the text read already (no second OCR); the family's tags there are suggested too.
struct ScanKnowledge {
    /// The folder as this device knows it now (`KnowledgeFolder.state`).
    var state: () -> KnowledgeFolder.State
    /// Queues a saved scan with its text, a string per page (`KnowledgeIndexer.enqueue`).
    var enqueue: (_ file: URL, _ pages: [String]) async throws -> Void
    /// The tags of the family's documents on the server, best effort (`serverTags`).
    var tags: () async -> [String] = { [] }
    /// Tells the user what went wrong (the tests keep it).
    var report: (any Error) -> Void = { ErrorBanner.shared.show($0) }

    /// Where scans go: the knowledge folder's root while it's linked here; nil when it isn't
    /// (none chosen on this device, missing, replaced by another device's): the scan folder.
    var folder: ScanFolder? {
        if case let .linked(url, _) = state() { .knowledge(url) } else { nil }
    }

    /// Queues `file` with the text of `pages`; a scan without any text isn't (the indexer reads
    /// the file itself when the server asks for it). A failure only costs that: the PDF is saved.
    /// The folder removed, replaced or chosen anew while the sheet was open is told (the file
    /// isn't in the knowledge base then); anything else is logged (the next run reads the file).
    func queue(_ file: URL, pages: [ScanPage]) async {
        let texts = Self.texts(pages)
        guard texts.contains(where: { !$0.isEmpty }) else { return }
        do {
            try await enqueue(file, texts)
        } catch KnowledgeFolderError.missing, KnowledgeFolderError.notInFolder {
            report(ScanKnowledgeError.folderChanged)
        } catch {
            KnowledgeFolder.log.error("Scan not queued: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Each page's text in reading order, as the letter's (`AssistantLetter.text`) and the PDF's
    /// text layer hold it.
    static func texts(_ pages: [ScanPage]) -> [String] {
        pages.map { ReceiptParser.lines($0.lines.map(\.piece)).joined(separator: "\n") }
    }

    /// `GET /knowledge/tags`, the most used first; the copy on the device when the server can't be
    /// reached or doesn't answer within `wait` (the sheet's suggestions wait for the tags).
    static func serverTags(_ request: CachedGet<KnowledgeTagsResponse>, wait: Duration = .seconds(3)) async -> [String] {
        let fetch = Task { try? await request.fetch() }
        let deadline = Task {
            try? await Task.sleep(for: wait)
            fetch.cancel()
        }
        let fetched = await fetch.value
        deadline.cancel()
        let tags = if let fetched { fetched } else { await request.savedOffMain()?.value }
        return tags?.tags.map(\.tag) ?? []
    }
}

nonisolated enum ScanKnowledgeError: LocalizedError, Equatable {
    case folderChanged

    var errorDescription: String? {
        String(localized: "Saved, but not added to the knowledge base: the knowledge folder changed.")
    }
}

/// Tags as the user keeps them.
nonisolated enum ScanTags {
    static let maxSuggested = 5
    static let maxLength = 30

    /// Trimmed, on one line, at most `maxLength` characters, without empties and duplicates (case
    /// ignored, the first kept), at most `limit`.
    static func cleaned(_ tags: [String], limit: Int = maxSuggested) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let clean = String(tag.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxLength))
                .trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
            if result.count == limit { break }
        }
        return result
    }

    /// Those of `tags` that are among `known` (case ignored), spelled as there. A tag that names
    /// someone of the family (`names`, `NameMatch`) and isn't known becomes the known variant of
    /// that name ("Michael" → "Michi").
    static func existing(_ tags: [String], known: [String], names: [String] = []) -> [String] {
        var spelling: [String: String] = [:]
        for tag in known where spelling[tag.lowercased()] == nil { spelling[tag.lowercased()] = tag }
        let family = NameMatch.firstNames(names)
        return cleaned(tags.compactMap { tag in
            let tag = tag.trimmingCharacters(in: .whitespaces)
            if let known = spelling[tag.lowercased()] { return known }
            let people = family.filter { NameMatch.isVariant(tag, of: $0, family: family) }
            guard !people.isEmpty else { return nil }
            return known.first { candidate in
                people.contains { NameMatch.isVariant(candidate, of: $0, family: family) }
            }
        })
    }
}

extension View {
    /// The folder picker of `filing` (none without one). On the form, not in `ScanFilingSection`:
    /// a row scrolled away (by the keyboard, editing the name) doesn't present it.
    func scanFolderPicker(_ filing: ScanFiling?) -> some View {
        fileImporter(isPresented: Binding(get: { filing?.choosingFolder ?? false },
                                          set: { filing?.choosingFolder = $0 }),
                     allowedContentTypes: [.folder]) { result in
            filing?.folderChosen(result)
        }
    }
}

/// The "Save as PDF" sections of a form (its folder picker: `scanFolderPicker`): the switch, and when it's on the name, the tags (chips
/// to remove, a field to add, the recently used ones) and the folder.
struct ScanFilingSection: View {
    @Bindable var filing: ScanFiling
    /// Apple's model is still working on the name and tags.
    var suggesting = false
    @State private var newTag = ""

    var body: some View {
        Section {
            Toggle("Save as PDF", isOn: $filing.savesPDF)
        } footer: {
            if filing.savesPDF {
                if filing.inKnowledge {
                    Text("A searchable PDF in the knowledge folder. Its text goes into the family’s knowledge base on your server.")
                } else {
                    Text("A searchable PDF in the folder you choose. It stays with you: it never goes to the server.")
                }
            }
        }
        if filing.savesPDF {
            nameSection
            tagsSection
            folderSection
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Name", text: Binding(get: { filing.name }, set: { filing.editName($0) }))
                .autocorrectionDisabled()
                .lineLimit(1)
        } header: {
            Text("Name")
        } footer: {
            if suggesting {
                Label { Text("Suggesting a name and tags…") } icon: { ProgressView().controlSize(.small) }
            }
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            if !filing.tags.isEmpty {
                RecipeFlowLayout(spacing: 6) {
                    ForEach(filing.tags, id: \.self) { tag in
                        Button {
                            filing.removeTag(tag)
                        } label: {
                            HStack(spacing: 4) {
                                Text(tag).lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .chip(tint: .accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove \(tag)"))
                    }
                }
            }
            TextField("Add Tag", text: $newTag)
                .autocorrectionDisabled()
                .onSubmit {
                    filing.addTag(newTag)
                    newTag = ""
                }
                #if os(iOS)
                .submitLabel(.done)
                #endif
            let recent = filing.recentTags
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recently used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RecipeFlowLayout(spacing: 6) {
                        ForEach(recent, id: \.self) { tag in
                            Button {
                                filing.addTag(tag)
                            } label: {
                                // Not a `Label`: in a form row it showed only the icon.
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    Text(tag).lineLimit(1)
                                }
                                .font(.callout)
                                .chip()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Add \(tag)"))
                        }
                    }
                }
            }
        }
    }

    private var folderSection: some View {
        Section("Folder") {
            switch filing.folder {
            case .knowledge:
                Label("Knowledge › \(filing.folderName ?? "")", systemImage: "books.vertical")
                    .lineLimit(1)
            case .folder:
                Label(filing.folderName ?? "", systemImage: "folder")
                    .lineLimit(1)
            case .missing:
                Label("The folder can’t be found any more.", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
            case .none:
                Label("No folder chosen yet", systemImage: "folder")
                    .foregroundStyle(.secondary)
            }
            if !filing.inKnowledge {
                Button("Choose Folder…") { filing.chooseFolder() }
            }
        }
    }
}

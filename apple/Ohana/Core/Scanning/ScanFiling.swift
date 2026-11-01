import SwiftUI
import UniformTypeIdentifiers

/// "Save as PDF" for a scan, as the user sets it in `ScanFilingSection`: on or off (remembered per
/// kind), the name and tags (suggested, then the user's once edited) and the folder (remembered
/// for all scans). `save(_:)` writes the PDF.
@Observable
final class ScanFiling {
    let kind: ScanKind
    let settings: ScanFilingSettings

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

    init(kind: ScanKind, settings: ScanFilingSettings = ScanFilingSettings()) {
        self.kind = kind
        self.settings = settings
        savesPDF = settings.savesPDF(kind)
        folder = settings.folder()
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

    /// The tags used before that this scan hasn't got.
    var recentTags: [String] {
        let current = Set(tags.map { $0.lowercased() })
        return settings.recentTags.filter { !current.contains($0.lowercased()) }
    }

    // MARK: The folder

    var folderName: String? {
        folder.url.map { FileManager.default.displayName(atPath: $0.path) }
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
    /// saved before).
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
            return file.lastPathComponent
        } catch ScanFilingError.folderMissing {
            folder = .missing
            throw ScanFilingError.folderMissing
        }
    }

    /// Saves (asking for a folder first when there's none), confirms with a banner, then runs
    /// `done`; errors go to the banner and `done` doesn't run.
    func saveThen(_ pages: @escaping () -> [ScanPage], done: @escaping () -> Void) {
        if needsFolder {
            chooseFolder { [weak self] in self?.saveThen(pages, done: done) }
            return
        }
        Task {
            do {
                if let file = try await save(pages()) {
                    ErrorBanner.shared.success(String(localized: "Saved “\(file)”"))
                }
                done()
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }
}

/// Tags as the user keeps them.
enum ScanTags {
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
                Text("A searchable PDF in the folder you choose. It stays with you: it never goes to the server.")
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
                                Label(tag, systemImage: "plus")
                                    .lineLimit(1)
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
            Button("Choose Folder…") { filing.chooseFolder() }
        }
    }
}

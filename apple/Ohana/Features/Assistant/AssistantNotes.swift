import CryptoKit
import Foundation

// The assistant's notes in the family's knowledge folder (server: lib/assistant/tools/notes.ts),
// like its Reminders tools (AssistantReminders.swift). The server never holds a file: every
// message names the folder linked on this device (`knowledgeFolder`), and the notes the assistant
// writes or changes (`AssistantNotesEdit`, Markdown files) are written here, once the user says
// so (`AssistantNotesApply`), queued for the index, then answered with each op's result.

/// The family's knowledge folder as the assistant's notes see it (`FamilyContext.assistantNotes`).
struct AssistantKnowledgeNotes {
    /// The folder as this device knows it now (`KnowledgeFolder.state`).
    var state: () -> KnowledgeFolder.State
    /// Queues a written note with its text, a string per page (`KnowledgeIndexer.enqueue`).
    var enqueue: (_ file: URL, _ pages: [String]) async throws -> Void
    /// Reads the folder again (a note whose tags alone changed: the next manifest has them).
    var reindex: () -> Void = {}

    /// The folder's id for the chat requests; nil unless it's linked here.
    var folderID: String? { state().folderID }
}

nonisolated enum AssistantNotesError: LocalizedError, Equatable, Sendable {
    /// No knowledge folder linked here, or another one than the requests named.
    case notLinked
    /// The path is empty, hidden or leaves the folder.
    case invalidPath
    /// create: something is at the path already.
    case exists
    /// update: the file isn't there any more.
    case notFound
    /// update: the file isn't the one the assistant read.
    case changed
    /// An op this app doesn't know.
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notLinked: String(localized: "The knowledge folder isn’t linked on this device any more.")
        case .invalidPath: String(localized: "This isn’t a valid path in the knowledge folder.")
        case .exists: String(localized: "A file with this name already exists.")
        case .notFound: String(localized: "The file isn’t in the folder any more.")
        case .changed: String(localized: "The note was changed since the assistant read it.")
        case .unsupported: String(localized: "This version of Ohana can’t make this change.")
        }
    }
}

/// Writes the notes of an edit into the knowledge folder, in order, and says how each went.
nonisolated enum AssistantNotesApply {
    /// How one op went on the disk.
    struct Outcome: Equatable, Sendable {
        var error: String?
        /// The file written, queued for the index with `text`.
        var file: URL?
        var text: String?
        /// Its tags were set without writing it.
        var retagged = false

        static func failed(_ error: any Error) -> Self { Outcome(error: error.localizedDescription) }
    }

    /// Every op is tried (one that fails doesn't stop the others), off the main actor, in the
    /// folder linked here; then the written files are queued for the index (a failure there is
    /// only logged). Without the folder, or with another one than `folderID` (the one the
    /// requests named, when known), every op fails.
    @MainActor
    static func perform(_ ops: [AssistantNoteOp], notes: AssistantKnowledgeNotes?,
                        folderID expected: String?) async -> [AssistantReminderResult] {
        guard let notes, case let .linked(root, folderID) = notes.state(), expected == nil || expected == folderID else {
            return ops.map { _ in .failed(AssistantNotesError.notLinked.localizedDescription) }
        }
        let outcomes = await Task.detached(priority: .userInitiated) { write(ops, in: root) }.value
        for outcome in outcomes {
            guard let file = outcome.file else { continue }
            do {
                try await notes.enqueue(file, [outcome.text ?? ""])
            } catch {
                KnowledgeFolder.log.error("Note not queued: \(error.localizedDescription, privacy: .public)")
            }
        }
        if outcomes.contains(where: \.retagged) { notes.reindex() }
        return zip(ops, outcomes).map { op, outcome -> AssistantReminderResult in
            outcome.error.map { .failed($0) } ?? .done(op.path)
        }
    }

    /// The ops written into `root` (security-scoped while it works).
    static func write(_ ops: [AssistantNoteOp], in root: URL) -> [Outcome] {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        return ops.map { op in
            do {
                return try apply(op, in: root)
            } catch {
                return .failed(error)
            }
        }
    }

    private static func apply(_ op: AssistantNoteOp, in root: URL) throws -> Outcome {
        let path = op.path.precomposedStringWithCanonicalMapping
        // No empty, hidden (".." among them) or control-character parts.
        guard KnowledgeWalker.isValidPath(path) else { throw AssistantNotesError.invalidPath }
        switch op.op {
        case "create":
            let file = try create(path, content: op.content, tags: op.tags, in: root)
            return Outcome(file: file, text: op.content)
        case "update":
            guard let base = op.baseHash, !base.isEmpty,
                  ["content", "append", "replace", "tags"].contains(op.change ?? "") else {
                throw AssistantNotesError.unsupported
            }
            guard let file = KnowledgeOriginal.locate(path, in: root) else { throw AssistantNotesError.notFound }
            try update(file, op: op, baseHash: base.lowercased())
            return op.tagsOnly ? Outcome(retagged: true) : Outcome(file: file, text: op.content)
        default:
            throw AssistantNotesError.unsupported
        }
    }

    /// A new note: its folders made as needed (existing ones found by their NFC name), the text
    /// written coordinated and atomically, then its tags.
    private static func create(_ path: String, content: String, tags: [String]?, in root: URL) throws -> URL {
        let parts = KnowledgePath.parts(path)
        guard let name = parts.last else { throw AssistantNotesError.invalidPath }
        var folder = root
        var missing = false
        for part in parts.dropLast() {
            let existing = missing ? nil : diskName(part, in: folder)
            missing = existing == nil
            folder = folder.appending(path: existing ?? part, directoryHint: .isDirectory)
        }
        if !missing, diskName(name, in: folder) != nil { throw AssistantNotesError.exists }
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        let data = Data(content.utf8)
        var failure: (any Error)?
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordination) { url in
            do {
                let manager = FileManager.default
                guard !manager.fileExists(atPath: url.path(percentEncoded: false)) else {
                    throw AssistantNotesError.exists
                }
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                if let tags, !tags.isEmpty { setTags(tags, on: url) }
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
        return file
    }

    /// A changed note: read coordinated, its hash checked, the new text written (unless only its
    /// tags change; tags it had stay unless new ones are given), then its tags.
    private static func update(_ file: URL, op: AssistantNoteOp, baseHash: String) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        let writing: NSFileCoordinator.WritingOptions = op.tagsOnly ? .contentIndependentMetadataOnly : .forReplacing
        var failure: (any Error)?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], writingItemAt: file, options: writing,
                                       error: &coordination) { readURL, writeURL in
            do {
                let current = try Data(contentsOf: readURL)
                guard hash(current) == baseHash else { throw AssistantNotesError.changed }
                if op.tagsOnly {
                    try FinderTags.write(KnowledgeTags.cleaned(op.tags ?? []), to: writeURL)
                    return
                }
                // An atomic write replaces the file, and its tags with it.
                let kept = op.tags == nil ? FinderTags.read(readURL) : []
                try Data(op.content.utf8).write(to: writeURL, options: .atomic)
                if let tags = op.tags {
                    setTags(tags, on: writeURL)
                } else if !kept.isEmpty {
                    setTags(kept, on: writeURL)
                }
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// Sets a written note's tags; a failure only costs the tags.
    private static func setTags(_ tags: [String], on url: URL) {
        do {
            try FinderTags.write(KnowledgeTags.cleaned(tags), to: url)
        } catch {
            KnowledgeFolder.log.error("Note tags not set: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The name in `folder` that is `name` compared NFC (an iCloud placeholder by its real name);
    /// nil when there's none.
    private static func diskName(_ name: String, in folder: URL) -> String? {
        let wanted = name.precomposedStringWithCanonicalMapping
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        if let found = names.first(where: { $0.precomposedStringWithCanonicalMapping == wanted }) { return found }
        return names.contains { KnowledgeOriginal.placeholderName($0) == wanted } ? name : nil
    }

    /// The SHA-256 in lowercase hex, as the server keeps it.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One op of a notes edit in plain words, e.g. "Create “Car.md” in Insurance" with its tags below
/// it, an icon, and the text to show with it.
struct AssistantNoteOpLine: Equatable {
    var icon: String
    var text: String
    var detail: String?
    var preview: Preview?

    /// What the op writes, for the card.
    enum Preview: Equatable {
        /// A new note's text, or a note's whole new text.
        case text(String)
        /// Added at the end.
        case added(String)
        /// Each `find` replaced by its `with`.
        case replacements([AssistantNoteOp.Replacement])

        /// Lines shown until it's expanded.
        static let collapsedLines = 4

        /// More than shows collapsed.
        var isLong: Bool {
            func long(_ text: String, lines: Int) -> Bool {
                text.count > lines * 70 || text.split(separator: "\n", omittingEmptySubsequences: false).count > lines
            }
            switch self {
            case let .text(text), let .added(text): return long(text, lines: Self.collapsedLines)
            case let .replacements(list): return list.contains { long($0.find, lines: 2) || long($0.with, lines: 2) }
            }
        }
    }

    static func make(_ op: AssistantNoteOp) -> Self {
        let place = op.folder.isEmpty ? String(localized: "Knowledge") : KnowledgePath.breadcrumb(op.folder)
        switch op.op {
        case "create":
            return Self(icon: "doc.badge.plus", text: String(localized: "Create “\(op.title)” in \(place)"),
                        detail: tagsText(op.tags, removes: false), preview: .text(op.content))
        case "update":
            var parts = [place]
            if op.change == "content" { parts.append(String(localized: "replaces the whole text")) }
            if let tags = tagsText(op.tags, removes: true) { parts.append(tags) }
            let preview: Preview? = switch op.change {
            case "content": .text(op.content)
            case "append": .added(op.added ?? "")
            case "replace": op.replacements.isEmpty ? nil : .replacements(op.replacements)
            default: nil
            }
            return Self(icon: "square.and.pencil", text: String(localized: "Change “\(op.title)”"),
                        detail: parts.joined(separator: " · "), preview: preview)
        default:
            return Self(icon: "questionmark.circle", text: op.title.isEmpty ? op.op : "\(op.op) “\(op.title)”")
        }
    }

    /// "Tags: Car, Insurance"; "remove the tags" for an update's empty list; nil without tags.
    private static func tagsText(_ tags: [String]?, removes: Bool) -> String? {
        guard let tags else { return nil }
        if tags.isEmpty { return removes ? String(localized: "remove the tags") : nil }
        let list = tags.joined(separator: ", ")
        return String(localized: "Tags: \(list)")
    }
}

extension AssistantNotesEdit {
    /// How it ended, in a few words; nil while it waits.
    var outcome: String? {
        AssistantRemindersEdit.outcome(answer: answer, skipped: skipped, count: ops.count)
    }
}

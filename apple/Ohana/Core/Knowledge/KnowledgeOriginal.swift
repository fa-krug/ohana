import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// *Open original*: a document's file in the family's knowledge folder on this device (its
// bookmark + the document's path), loaded from iCloud when it isn't on the device, and copied out
// of the folder for the viewer, so the folder's security scope ends at once (the copy goes when the
// viewer closes). The server never has the file.

/// Why the original can't be opened.
nonisolated enum KnowledgeOriginalError: LocalizedError, Equatable, Sendable {
    /// No knowledge folder chosen on this device.
    case noFolder
    /// The folder chosen here can't be found any more.
    case folderMissing
    /// Another device chose a different folder for the family since.
    case folderReplaced
    /// The file isn't in the folder any more.
    case notFound
    /// The file couldn't be loaded (iCloud, permissions).
    case unreadable
    /// The file isn't on the device and there's no connection to load it.
    case offline
    /// Loading it from iCloud took too long.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noFolder:
            String(localized: "The original is in the knowledge folder, which isn’t chosen on this device.")
        case .folderMissing:
            String(localized: "The knowledge folder can’t be found any more. Choose it again.")
        case .folderReplaced:
            String(localized: "Another device now reads a different folder. Choose the knowledge folder again.")
        case .notFound:
            String(localized: "The file isn’t in the folder any more.")
        case .unreadable:
            String(localized: "The file couldn’t be loaded.")
        case .offline:
            String(localized: "The file isn’t on this device, and without a connection iCloud can’t load it.")
        case .timedOut:
            String(localized: "Loading the file from iCloud took too long. Try again later.")
        }
    }

    /// Choosing the folder (Settings → Knowledge) helps.
    var offersSettings: Bool {
        switch self {
        case .noFolder, .folderMissing, .folderReplaced: true
        case .notFound, .unreadable, .offline, .timedOut: false
        }
    }
}

/// A copy of an original for the viewer, in a folder of its own under the temporary directory.
nonisolated struct KnowledgeOriginalFile: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    var isPDF: Bool { KnowledgeOriginal.isPDF(url) }

    /// Deletes the copy (when the viewer closes).
    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

nonisolated enum KnowledgeOriginal {
    /// Where the copies go (each in a folder of its own).
    static var copies: URL {
        FileManager.default.temporaryDirectory.appending(path: "KnowledgeOriginals", directoryHint: .isDirectory)
    }

    static func isPDF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .pdf) == true
    }

    /// The file of `path` (relative to `root`, NFC as the server keeps it) as the disk spells it:
    /// each part compared NFC, so a name written NFD (another device, a file provider) is found too.
    /// A file iCloud keeps off the device (a hidden ".Name.icloud" in its place) is its real URL,
    /// which a coordinated read loads. Nil when it isn't there, or for a path leaving the folder.
    static func locate(_ path: String, in root: URL) -> URL? {
        let parts = KnowledgePath.parts(path)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let manager = FileManager.default
        var current = root
        for (index, part) in parts.enumerated() {
            let wanted = part.precomposedStringWithCanonicalMapping
            let last = index == parts.count - 1
            let names = (try? manager.contentsOfDirectory(atPath: current.path(percentEncoded: false))) ?? []
            if let name = names.first(where: { $0.precomposedStringWithCanonicalMapping == wanted }) {
                current = current.appending(path: name, directoryHint: last ? .notDirectory : .isDirectory)
                continue
            }
            // Not on the device: its iCloud placeholder.
            if last, names.contains(where: { placeholderName($0) == wanted }) {
                return current.appending(path: part, directoryHint: .notDirectory)
            }
            return nil
        }
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: current.path(percentEncoded: false), isDirectory: &isFolder),
              !isFolder.boolValue else { return nil }
        return current
    }

    /// The real name (NFC) behind an iCloud placeholder's ".Name.icloud"; nil for other names.
    static func placeholderName(_ name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count)).precomposedStringWithCanonicalMapping
    }

    /// Deletes the copies left behind (the app quit while a viewer was open): at launch.
    static func sweepCopies(in folder: URL = copies) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copies `url` (read coordinated: iCloud loads it first; `coordinator.cancel()` stops the
    /// wait) into a folder of its own under `copies`, named `name`.
    static func copy(_ url: URL, name: String, coordinator: NSFileCoordinator = NSFileCoordinator()) throws -> KnowledgeOriginalFile {
        let folder = copies.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appending(path: name.isEmpty ? url.lastPathComponent : name, directoryHint: .notDirectory)
        var coordination: NSError?
        var failure: (any Error)?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordination) { readable in
            do { try FileManager.default.copyItem(at: readable, to: target) } catch { failure = error }
        }
        if let error = coordination ?? failure {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return KnowledgeOriginalFile(url: target)
    }

    /// The linked folder of `state`, or why there's none.
    static func linkedRoot(_ state: KnowledgeFolder.State) throws(KnowledgeOriginalError) -> URL {
        switch state {
        case .none: throw .noFolder
        case .missing: throw .folderMissing
        case .replaced: throw .folderReplaced
        case let .linked(url, _): return url
        }
    }

    #if os(macOS)
    /// Shows the document's file in the Finder.
    @MainActor
    static func showInFinder(path: String, folder: KnowledgeFolder) throws {
        let root = try linkedRoot(folder.state())
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        guard let url = locate(path, in: root) else { throw KnowledgeOriginalError.notFound }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}

/// Where a fact's quote is in a page's text: the words in order, whatever the whitespace between
/// them (line breaks in a PDF), case, accents and the punctuation around a word; then the quote's
/// first words when the whole isn't there (a hyphenated line end, a quote the model shortened).
nonisolated enum KnowledgeQuoteMatch {
    /// The quote's word counts tried after the whole one.
    static let fallbackLengths = [8, 5, 3]

    /// The range of `quote` in `text`; nil when not even its first words are there.
    static func range(of quote: String, in text: String) -> Range<String.Index>? {
        let wanted = words(quote).map(\.folded)
        guard !wanted.isEmpty else { return nil }
        let have = words(text)
        let lengths = [wanted.count] + fallbackLengths.filter { $0 < wanted.count }
        for length in lengths {
            if let found = find(Array(wanted.prefix(length)), in: have) { return found }
        }
        return nil
    }

    /// `range(of:in:)` as an NSRange of `text` (PDFKit's selections).
    static func nsRange(of quote: String, in text: String) -> NSRange? {
        range(of: quote, in: text).map { NSRange($0, in: text) }
    }

    private struct Word {
        var folded: String
        var range: Range<String.Index>
    }

    private static func find(_ wanted: [String], in have: [Word]) -> Range<String.Index>? {
        guard !wanted.isEmpty, have.count >= wanted.count else { return nil }
        for start in 0...(have.count - wanted.count) {
            var matches = true
            for offset in wanted.indices where have[start + offset].folded != wanted[offset] {
                matches = false
                break
            }
            if matches { return have[start].range.lowerBound..<have[start + wanted.count - 1].range.upperBound }
        }
        return nil
    }

    /// The words of `text` (runs without whitespace), folded, with their ranges (punctuation and
    /// symbols around a word left out); words of punctuation only are skipped.
    private static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var index = text.startIndex
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            var lower = index, upper = end
            while lower < upper, text[lower].unicodeScalars.allSatisfy({ trim.contains($0) }) {
                lower = text.index(after: lower)
            }
            while upper > lower, text[text.index(before: upper)].unicodeScalars.allSatisfy({ trim.contains($0) }) {
                upper = text.index(before: upper)
            }
            if lower < upper {
                let folded = text[lower..<upper].folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                         locale: nil)
                result.append(Word(folded: folded, range: lower..<upper))
            }
            index = end
        }
        return result
    }
}

/// Loads one original (`KnowledgeOriginal`): finds the file, then copies it for the viewer, which
/// waits while iCloud loads it. `cancel()` (the user's) and the timeout stop that wait
/// (`NSFileCoordinator.cancel()`); a file that isn't on the device fails at once while offline.
nonisolated final class KnowledgeOriginalLoader: @unchecked Sendable {
    private enum Stop { case cancelled, timedOut }

    /// How long iCloud may take to load a file.
    static let defaultTimeout = Duration.seconds(120)

    private let coordinator = NSFileCoordinator()
    private let lock = NSLock()
    private var stop: Stop?

    init() {}

    /// Stops the load (Cancel).
    func cancel() { halt(.cancelled) }

    private func halt(_ reason: Stop) {
        lock.withLock { if stop == nil { stop = reason } }
        coordinator.cancel()
    }

    private var stopped: Stop? { lock.withLock { stop } }

    /// The original of the document at `path`, copied for the viewer. `online`: there's a
    /// connection (else a file iCloud keeps off the device isn't waited for). Throws
    /// `KnowledgeOriginalError`, or `CancellationError` after `cancel()`.
    func fetch(path: String, folder: KnowledgeFolder, online: Bool,
               timeout: Duration = KnowledgeOriginalLoader.defaultTimeout) async throws -> KnowledgeOriginalFile {
        let root = try KnowledgeOriginal.linkedRoot(folder.state())
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let found = await Task.detached(priority: .userInitiated) { () -> (url: URL, onDevice: Bool)? in
            KnowledgeOriginal.locate(path, in: root).map { ($0, KnowledgeICloud.isOnDevice($0)) }
        }.value
        guard let found else { throw KnowledgeOriginalError.notFound }
        if stopped == .cancelled { throw CancellationError() }
        if !found.onDevice {
            guard online else { throw KnowledgeOriginalError.offline }
            try? FileManager.default.startDownloadingUbiquitousItem(at: found.url)
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.halt(.timedOut) }
        }
        defer { timer.cancel() }
        let name = KnowledgePath.parts(path).last ?? found.url.lastPathComponent
        let coordinator = coordinator
        do {
            return try await Task.detached(priority: .userInitiated) {
                try KnowledgeOriginal.copy(found.url, name: name, coordinator: coordinator)
            }.value
        } catch {
            switch stopped {
            case .cancelled: throw CancellationError()
            case .timedOut: throw KnowledgeOriginalError.timedOut
            case nil:
                KnowledgeFolder.log.error("Original not copied: \(error.localizedDescription, privacy: .public)")
                throw KnowledgeOriginalError.unreadable
            }
        }
    }
}

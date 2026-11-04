import CryptoKit
import Foundation

/// A file of the knowledge folder as the device sees it.
nonisolated struct KnowledgeLocalFile: Equatable, Sendable {
    /// Relative to the folder, "/"-separated, NFC (the server's form).
    var path: String
    /// Where the file is (for an iCloud placeholder: where it will be once downloaded).
    var url: URL
    var size: Int64
    /// The modification date in ms since 1970.
    var mtime: Int64
    /// Finder / Files tags (none known for a file that isn't on the device).
    var tags: [String]
    /// Its content is on the device; else iCloud loads it when it's read (coordinated).
    var downloaded: Bool = true
}

/// What the walk found.
nonisolated struct KnowledgeListing: Sendable {
    var files: [KnowledgeLocalFile] = []
    /// Files left out for their size (`KnowledgeLimits.maxFileSize`).
    var tooLarge = 0
    /// More files than a manifest may hold: the listing is incomplete and mustn't be sent.
    var truncated = false
    /// Folders that couldn't be listed (relative to the folder, "" the folder itself): the listing
    /// is incomplete (their files would count as missing) and mustn't be sent.
    var unlistable: [String] = []
}

/// Lists the knowledge folder: every file in it and its subfolders, except hidden ones (a name
/// starting with "."; the marker too), packages (an app, a Pages or RTFD document: folders, not
/// files), symbolic links (files and folders: a link could loop or lead out of the folder), files
/// over `KnowledgeLimits.maxFileSize` and names the server doesn't take. An iCloud file that isn't on the device shows under its real name (iOS keeps a
/// hidden ".Name.icloud" in its place), marked not downloaded.
nonisolated enum KnowledgeWalker {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]
    /// Deeper than this is a loop, or nothing anyone files by hand.
    static let maxDepth = 32

    static func walk(_ root: URL, maxFiles: Int = KnowledgeLimits.maxFiles,
                     maxFileSize: Int64 = KnowledgeLimits.maxFileSize) -> KnowledgeListing {
        var listing = KnowledgeListing()
        visit(root, parts: [], maxFiles: maxFiles, maxFileSize: maxFileSize, into: &listing)
        listing.files.sort { $0.path < $1.path }
        return listing
    }

    private static func visit(_ folder: URL, parts: [String], maxFiles: Int, maxFileSize: Int64,
                              into listing: inout KnowledgeListing) {
        guard parts.count < maxDepth, !listing.truncated else { return }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        } catch {
            listing.unlistable.append(path(parts))
            return
        }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !listing.truncated else { return }
            let name = item.lastPathComponent
            var file: KnowledgeLocalFile?
            if name.hasPrefix(".") {
                // Hidden, unless it's the placeholder of an iCloud file not on the device.
                guard let placeholder = placeholder(item) else { continue }
                file = KnowledgeLocalFile(path: path(parts + [placeholder.name]),
                                          url: folder.appending(path: placeholder.name, directoryHint: .notDirectory),
                                          size: placeholder.size, mtime: placeholder.mtime, tags: [], downloaded: false)
            } else {
                guard let values = try? item.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    guard values.isPackage != true else { continue }
                    visit(item, parts: parts + [name], maxFiles: maxFiles, maxFileSize: maxFileSize, into: &listing)
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let status = values.ubiquitousItemDownloadingStatus
                let downloaded = values.isUbiquitousItem != true || status == nil || status != .notDownloaded
                file = KnowledgeLocalFile(path: path(parts + [name]), url: item, size: Int64(values.fileSize ?? 0),
                                          mtime: milliseconds(values.contentModificationDate),
                                          tags: downloaded ? KnowledgeTags.cleaned(FinderTags.read(item)) : [],
                                          downloaded: downloaded)
            }
            guard let file, isValidPath(file.path) else { continue }
            if file.size > maxFileSize {
                listing.tooLarge += 1
                continue
            }
            if listing.files.count >= maxFiles {
                listing.truncated = true
                return
            }
            listing.files.append(file)
        }
    }

    /// The parts as the server's path: "/"-joined, NFC.
    static func path(_ parts: [String]) -> String {
        parts.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    /// A path the server takes (server/lib/knowledge/input.ts `normalizePath`): no empty or hidden
    /// part, no control character or "\", at most `maxPathLength` characters (UTF-16, as
    /// JavaScript counts).
    static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf16.count <= KnowledgeLimits.maxPathLength else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\\" }) { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0.hasPrefix(".") }
    }

    static func milliseconds(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    // MARK: iCloud placeholders

    /// An iCloud file that isn't on the device, as iOS shows it: a hidden ".Name.icloud" whose
    /// content is a property list naming the file and its size.
    struct Placeholder: Equatable {
        var name: String
        var size: Int64
        var mtime: Int64
    }

    static func placeholder(_ item: URL) -> Placeholder? {
        let name = item.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true else { return nil }
        let info = (try? Data(contentsOf: item))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        if let type = info?["NSURLFileResourceTypeKey"] as? String, type != "NSURLFileResourceTypeRegular" { return nil }
        let real = (info?["NSURLNameKey"] as? String) ?? String(name.dropFirst().dropLast(".icloud".count))
        guard !real.isEmpty, !real.hasPrefix("."), !real.contains("/") else { return nil }
        let size = (info?["NSURLFileSizeKey"] as? NSNumber)?.int64Value ?? 0
        return Placeholder(name: real, size: size, mtime: milliseconds(values?.contentModificationDate))
    }
}

/// Tags as the server takes them (input.ts `cleanTags`): trimmed, NFC, no empty ones or
/// duplicates, at most `maxTags` of at most `maxTagLength` characters.
nonisolated enum KnowledgeTags {
    static func cleaned(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let clean = tag.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.utf16.count <= KnowledgeLimits.maxTagLength,
                  seen.insert(clean).inserted else { continue }
            result.append(clean)
            if result.count == KnowledgeLimits.maxTags { break }
        }
        return result
    }
}

// MARK: - Hashes

/// The files' hashes as last worked out on this device (Application Support,
/// `Ohana/Knowledge/<server>/<family>/hashes.json`): a file whose size and modification date are
/// unchanged isn't read again (one iCloud keeps off the device: its size alone, the date of its
/// placeholder isn't the file's). The tags are kept too, for files iCloud has taken off the device,
/// and whether the text of a file with that hash couldn't be read (a locked PDF, OCR failing), so
/// it isn't read again until it changes.
nonisolated struct KnowledgeHashCache: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var size: Int64
        var mtime: Int64
        var hash: String
        var tags: [String] = []
        /// Reading this hash's text failed on this device.
        var readFailed: Bool?
    }

    var entries: [String: Entry] = [:]

    /// The entry of `file` when it hasn't changed since it was worked out: size and date, for a
    /// file not on the device its size.
    func entry(for file: KnowledgeLocalFile) -> Entry? {
        guard let entry = entries[file.path], entry.size == file.size,
              !file.downloaded || entry.mtime == file.mtime else { return nil }
        return entry
    }

    /// The hash of `file` when it hasn't changed since it was worked out.
    func hash(for file: KnowledgeLocalFile) -> String? {
        entry(for: file)?.hash
    }

    /// The last hash of the file at `path` if its size is still `size` (its date may differ): for a
    /// file that couldn't be hashed this time.
    func lastHash(path: String, size: Int64) -> String? {
        guard let entry = entries[path], entry.size == size else { return nil }
        return entry.hash
    }

    /// The tags last seen on the file at `path`.
    func tags(for path: String) -> [String] {
        entries[path]?.tags ?? []
    }

    mutating func set(_ file: KnowledgeLocalFile, hash: String) {
        // A failed read stays known while the content is the same.
        let failed = entries[file.path].flatMap { $0.hash == hash ? $0.readFailed : nil }
        entries[file.path] = Entry(size: file.size, mtime: file.mtime, hash: hash, tags: file.tags, readFailed: failed)
    }

    /// Whether reading the text of `path` with `hash` failed before.
    func readFailed(path: String, hash: String) -> Bool {
        guard let entry = entries[path], entry.hash == hash else { return false }
        return entry.readFailed == true
    }

    /// Notes that reading `path` with `hash` failed (or, `failed` false, worked).
    mutating func setReadFailed(path: String, hash: String, _ failed: Bool = true) {
        guard var entry = entries[path], entry.hash == hash else { return }
        entry.readFailed = failed ? true : nil
        entries[path] = entry
    }

    /// Forgets the files that aren't there any more.
    mutating func keep(only paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }

    static func load(_ file: URL) -> KnowledgeHashCache {
        guard let data = try? Data(contentsOf: file),
              let cache = try? JSONDecoder().decode(KnowledgeHashCache.self, from: data) else { return KnowledgeHashCache() }
        return cache
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

// MARK: - iCloud

/// When this device may have iCloud load files that aren't on it: the Mac always; iOS not in Low
/// Data Mode nor on an expensive network (cellular, a hotspot), and up to `budget` bytes a run;
/// the rest wait for a later run (listed with the hash known, else none).
nonisolated struct KnowledgeDownloads: Equatable, Sendable {
    var allowed: Bool
    /// Bytes a run may load; nil: no limit.
    var budget: Int64?

    static let unlimited = KnowledgeDownloads(allowed: true, budget: nil)
    static let none = KnowledgeDownloads(allowed: false, budget: 0)
    static let iOSBudget: Int64 = 300_000_000

    @MainActor
    static func current() -> KnowledgeDownloads {
        #if os(macOS)
        .unlimited
        #else
        KnowledgeDownloads(allowed: !Connectivity.shared.isConstrained && !Connectivity.shared.isExpensive,
                           budget: iOSBudget)
        #endif
    }
}

/// How a run gets each file's hash.
nonisolated enum KnowledgeHashStep: Equatable, Sendable {
    /// Unchanged since last time: the cache's.
    case cached(KnowledgeHashCache.Entry)
    /// On the device: read it.
    case hash
    /// Not on the device: iCloud loads it (counted against the budget), and it's taken off again.
    case download
    /// Not on the device, and not loaded this run: listed with its last hash (same size), else
    /// with none.
    case later

    /// The step for each file, in order; the budget goes to the files in their order.
    static func plan(_ files: [KnowledgeLocalFile], cache: KnowledgeHashCache,
                     downloads: KnowledgeDownloads) -> [KnowledgeHashStep] {
        var left = downloads.budget
        return files.map { file in
            if let entry = cache.entry(for: file) { return .cached(entry) }
            if file.downloaded { return .hash }
            guard downloads.allowed else { return .later }
            if let budget = left {
                guard file.size <= budget else { return .later }
                left = budget - file.size
            }
            return .download
        }
    }
}

nonisolated enum KnowledgeICloud {
    /// Whether the file's content is on the device (not an iCloud placeholder: a hidden
    /// ".Name.icloud" in its place, or a file whose content iCloud keeps).
    static func isOnDevice(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let stub = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
            return !FileManager.default.fileExists(atPath: stub.path)
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus != .notDownloaded
    }

    /// Takes files iCloud loaded for a run off the device again (their content stays in iCloud).
    @concurrent
    static func evict(_ urls: [URL]) async {
        for url in urls {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
            } catch {
                KnowledgeFolder.log.debug("Not evicted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// SHA-256 of a file, read coordinated: iCloud loads a file that isn't on the device first.
nonisolated enum KnowledgeHasher {
    static let chunkSize = 1 << 20

    /// The hash in lowercase hex; also the file's size and date as they are once it's on the
    /// device (a placeholder's may differ).
    static func sha256(_ url: URL) throws -> (hash: String, size: Int64, mtime: Int64) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var result: (String, Int64, Int64)?
        var failure: (any Error)?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
                    hasher.update(data: data)
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                result = (hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                          Int64(values?.fileSize ?? 0), KnowledgeWalker.milliseconds(values?.contentModificationDate))
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }
}

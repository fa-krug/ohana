import Foundation

// What a run of the indexer works with (`KnowledgeIndexer`): the phases it reports, what the last
// run did, why a file wasn't sent, a listed file with its hash, and the plain look-ups that need
// neither the queue, the cache nor the server.

extension KnowledgeIndexer {

    enum Phase: Equatable {
        case idle
        /// Listing the folder.
        case scanning
        /// Hashing the files that changed (and loading those iCloud keeps off the device).
        case hashing(done: Int, of: Int)
        /// Reading and uploading what the server asked for.
        case uploading(done: Int, of: Int)
        case failed(String)
    }

    /// What the last finished run did.
    struct Run: Equatable {
        var finished: Date
        /// Files in the folder (in the manifest); 0: the folder looked empty and nothing was sent.
        var files: Int
        /// Uploaded by this run's flush (scans queued meanwhile among them; what a flush already
        /// under way when the run got there sent counts there, not here).
        var uploaded: Int = 0
        /// Left out for their size.
        var tooLarge: Int = 0
        /// Couldn't be hashed (iCloud couldn't load them): listed with their last hash, else none.
        var unhashable: Int = 0
        /// Not on the device and not loaded this run (iOS: Low Data Mode, a cellular network, the
        /// run's budget): listed with their last hash, else none; a later run loads them.
        var deferred: Int = 0
    }

    /// Why a file the server asked for wasn't sent from this device.
    enum Unreadable: Equatable {
        /// A format this device doesn't read (another device may).
        case format
        /// Its text couldn't be read (a locked PDF, OCR failing): not tried again until it changes.
        case failed

        var reason: String {
            switch self {
            case .format: String(localized: "This device can’t read this format.")
            case .failed: String(localized: "Its text couldn’t be read (a locked PDF, or text recognition failed).")
            }
        }
    }

    /// Automatic runs (launch, active, the Mac's timer) at most this often; *Read now* and scans
    /// run at once.
    static var minimumInterval: TimeInterval = 5 * 60

    /// Files hashed at a time (each may first be loaded from iCloud, off the main actor).
    static let hashingWidth = 3

    static let maxRetryDelay: Double = 120

    /// The queue is written at most this often while it changes (and when a flush ends).
    static var queueSaveDelay = Duration.seconds(2)

    /// Whether the server takes page images is asked again after this long.
    static var scanStatusAge: TimeInterval = 5 * 60

    @concurrent
    static func walk(_ root: URL) async -> KnowledgeListing {
        KnowledgeWalker.walk(root)
    }

    /// A listed file with its hash: what the manifest says of it, and where it is on the disk.
    struct Hashed {
        /// Its size, date and tags as the manifest gives them.
        var local: KnowledgeLocalFile
        /// nil: present, but no hash known (the server keeps its document as it is).
        var hash: String?
        /// iCloud loaded it for this run: taken off the device again.
        var evict: Bool

        var entry: KnowledgeManifestFile {
            KnowledgeManifestFile(path: local.path, size: local.size, mtime: local.mtime, hash: hash, tags: local.tags,
                                  reader: KnowledgeText.reader(forPath: local.path))
        }

        var info: KnowledgeFileInfo? {
            guard let hash else { return nil }
            KnowledgeFileInfo(path: local.path, size: local.size, mtime: local.mtime, hash: hash, tags: local.tags)
        }
    }

    @concurrent
    static func hash(_ url: URL) async -> (hash: String, size: Int64, mtime: Int64)? {
        do {
            return try KnowledgeHasher.sha256(url)
        } catch {
            KnowledgeFolder.log.error("Can't hash \(url.lastPathComponent, privacy: .private):"
                                      + " \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A file the server asked for, and where it is on the disk.
    struct Match: Equatable {
        var path: String
        var diskPath: String
    }

    /// The local files of the server's paths (NFC both sides; a path the device doesn't have is
    /// skipped), in the server's order. `diskPath`: relative to the folder as the disk spells it.
    static func match(_ paths: [String], in files: [KnowledgeLocalFile]) -> [Match] {
        var byPath: [String: KnowledgeLocalFile] = [:]
        for file in files { byPath[file.path.precomposedStringWithCanonicalMapping] = file }
        var seen = Set<String>()
        return paths.compactMap { path in
            let key = path.precomposedStringWithCanonicalMapping
            guard seen.insert(key).inserted, let file = byPath[key] else { return nil }
            return Match(path: file.path, diskPath: diskPath(of: file))
        }
    }

    /// The file's path relative to the folder as its URL spells it ("/"-joined, the disk's form).
    static func diskPath(of file: KnowledgeLocalFile) -> String {
        let depth = file.path.split(separator: "/").count
        return file.url.pathComponents.suffix(depth).joined(separator: "/")
    }

    static func isFolderGone(_ error: any Error) -> Bool {
        if case let APIError.http(status, _) = error { status == 404 } else { false }
    }

    /// Writes a scan's text as `name` in `folder`, unless the account signed out or the folder
    /// was chosen anew or removed since `generation` (checked under the gates' lock: a sign-out
    /// waits, then removes the folder; it's never made again after). Whether it was written.
    nonisolated static func writeText(_ pages: [String], name: String, in folder: URL,
                                      signOutGate: KnowledgeDiskGate = .signOuts, signOuts: Int,
                                      gate: KnowledgeDiskGate, generation: Int) throws -> Bool {
        var result: Result<Bool, any Error> = .success(false)
        signOutGate.run(at: signOuts) {
            gate.run(at: generation) {
                result = Result {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try JSONEncoder().encode(pages).write(to: folder.appending(path: name), options: .atomic)
                    return true
                }
            }
        }
        return try result.get()
    }

    /// `file`'s path relative to `root` ("/"-joined), nil when it isn't inside.
    static func relativePath(of file: URL, in root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parts = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// What *Read Again* came to.
    enum RereadOutcome: Equatable {
        /// Read and sent (the server reads it anew if its text changed).
        case sent
        /// Waits on the device for the connection.
        case waiting
        /// This device couldn't read it.
        case unreadable(Unreadable)
    }

    /// The file of `path` in `root` as the disk has it (off the main actor: iCloud may be slow).
    @concurrent
    static func locate(_ path: String, in root: URL) async -> URL? {
        KnowledgeOriginal.locate(path, in: root)
    }
}

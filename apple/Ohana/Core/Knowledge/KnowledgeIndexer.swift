import Foundation
import Observation

/// Reads the family's knowledge folder on this device into the server's index: walks the folder
/// (`KnowledgeWalker`), hashes what changed since last time (`KnowledgeHashCache`), sends the
/// manifest, then reads (`KnowledgeText`) and uploads the files the server asks for, through a
/// queue kept on the device (`KnowledgeUploadQueue`). One per family (`FamilyContext.knowledge`);
/// one run at a time, a run asked for meanwhile follows it once. Runs at launch, when the app is
/// active again, every 15 minutes on the Mac, and when asked (Settings → Knowledge, a scan).
///
/// Nothing runs again by itself: a file that changed while it was read waits for the next run.
/// Choosing another folder or removing it (`link`, `unlink`) stops what runs (a new generation:
/// the old run writes nothing more). The hash cache and the queue are read and written off the
/// main actor, in order (`onDisk`); the queue at most every `queueSaveDelay` while it changes.
@Observable
final class KnowledgeIndexer {
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

    let api: FamilyAPI
    let folder: KnowledgeFolder
    /// Where the hash cache, the queue and queued texts are kept (`KnowledgeLocation.directory`).
    let directory: URL
    /// What the manifest calls this device.
    var deviceName: String
    /// When iCloud may load files for a run (the tests set their own).
    @ObservationIgnored var downloads: () -> KnowledgeDownloads = { KnowledgeDownloads.current() }
    /// Tests: what happens between a run's walk and its hashing (a scan saved meanwhile).
    @ObservationIgnored var walked: () async -> Void = {}

    private(set) var phase: Phase = .idle
    private(set) var lastRun: Run?
    /// Files the server asked for that this device didn't send, and why; by path.
    private(set) var unreadable: [String: Unreadable] = [:]
    /// Uploads waiting (or being sent).
    private(set) var waiting = 0

    @ObservationIgnored private var queue = KnowledgeUploadQueue()
    @ObservationIgnored private var queueLoaded = false
    @ObservationIgnored private var cache = KnowledgeHashCache()
    @ObservationIgnored private var cacheLoaded = false
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var runAgain = false
    /// The scans queued (`enqueue`) since the running run started its walk, by path: listed in its
    /// manifest even when the walk missed them. nil while no run walks.
    @ObservationIgnored private var scansDuringRun: [String: Hashed]?
    @ObservationIgnored private var lastStart: Date?
    /// The generation a flush is under way for.
    @ObservationIgnored private var flushingGeneration: Int?
    @ObservationIgnored private var retryDelay: Double = 2
    @ObservationIgnored private var retryWait: Task<Void, Never>?
    @ObservationIgnored private var queueSave: Task<Void, Never>?
    /// The disk work, one after the other.
    @ObservationIgnored private var diskChain: Task<Void, Never>?
    /// Grows when the folder is chosen anew or removed: what an older run would still do is void.
    @ObservationIgnored private let gate = KnowledgeDiskGate()
    /// `removeAll` ran since this indexer was made (signed out): it sends and keeps nothing more.
    @ObservationIgnored private let signOuts: Int

    /// Automatic runs (launch, active, the Mac's timer) at most this often; *Read now* and scans
    /// run at once.
    static var minimumInterval: TimeInterval = 5 * 60
    /// Files hashed at a time (each may first be loaded from iCloud, off the main actor).
    static let hashingWidth = 3
    static let maxRetryDelay: Double = 120
    /// The queue is written at most this often while it changes (and when a flush ends).
    static var queueSaveDelay = Duration.seconds(2)

    init(api: FamilyAPI, folder: KnowledgeFolder, directory: URL, deviceName: String = AppModel.deviceName) {
        self.api = api
        self.folder = folder
        self.directory = directory
        self.deviceName = deviceName
        signOuts = KnowledgeDiskGate.signOuts.current
        Connectivity.shared.whenReconnected { [weak self] in self?.retryNow() }
        Task { [weak self] in await self?.ensureQueue() }
    }

    /// The indexer of `api`'s family, its files under Application Support.
    convenience init(api: FamilyAPI) {
        let location = KnowledgeLocation(server: api.client.baseURL, familyID: api.familyID)
        self.init(api: api, folder: KnowledgeFolder(location: location), directory: location.directory())
    }

    var isRunning: Bool { runTask != nil }

    private var hashesFile: URL { directory.appending(path: "hashes.json") }
    private var queueFile: URL { directory.appending(path: "queue.json") }
    private var textsFolder: URL { directory.appending(path: "texts", directoryHint: .isDirectory) }
    private var closed: Bool { signOuts != KnowledgeDiskGate.signOuts.current }

    /// Still the generation `generation` (not signed out, the folder not chosen anew or removed).
    private func isCurrent(_ generation: Int) -> Bool {
        !closed && gate.current == generation
    }

    // MARK: Running

    /// A run unless one started within `minimumInterval` (launch, active again, the Mac's timer).
    func runIfDue(now: Date = Date()) async {
        if let lastStart, now.timeIntervalSince(lastStart) < Self.minimumInterval {
            retryNow()
            return
        }
        await run()
    }

    /// Reads the folder now; while a run is under way, one more follows it (once, however often
    /// this is called meanwhile).
    func run() async {
        if let runTask {
            runAgain = true
            await runTask.value
            return
        }
        let id = UUID()
        let task = Task {
            repeat {
                runAgain = false
                lastStart = Date()
                await runOnce()
            } while runAgain && !closed && !Task.isCancelled
            if runID == id {
                runTask = nil
                runID = nil
                // A scan queued during a run that stopped before its flush (it waited for the run);
                // not while a retry waits for the connection.
                if !queue.isEmpty, retryWait == nil, flushingGeneration == nil { Task { await flushInFolder() } }
            }
        }
        runTask = task
        runID = id
        await task.value
    }

    private func runOnce() async {
        let generation = gate.current
        guard isCurrent(generation) else { return }
        let root: URL, folderID: String
        switch folder.state() {
        case .none, .replaced:
            phase = .idle
            return
        case .missing:
            phase = .failed(KnowledgeFolderError.missing.localizedDescription)
            return
        case let .linked(url, id):
            (root, folderID) = (url, id)
        }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }

        phase = .scanning
        scansDuringRun = [:]
        defer { scansDuringRun = nil }
        let listing = await Self.walk(root)
        await walked()
        guard isCurrent(generation) else { return }
        if listing.truncated {
            phase = .failed(KnowledgeIndexError.tooManyFiles.localizedDescription)
            return
        }
        // A folder that can't be listed whole mustn't be sent: its files would count as missing.
        if let folderPath = listing.unlistable.first {
            let name = folderPath.isEmpty ? FileManager.default.displayName(atPath: root.path) : folderPath
            phase = .failed(KnowledgeIndexError.unlistable(name).localizedDescription)
            return
        }
        // A folder that looks empty (iCloud signed out, the share left, really empty) sends
        // nothing: an empty manifest would tell the server nothing anyway.
        guard !listing.files.isEmpty else {
            lastRun = Run(finished: Date(), files: 0, tooLarge: listing.tooLarge)
            phase = .idle
            return
        }

        await ensureCache()
        await ensureQueue()
        guard isCurrent(generation) else { return }
        let result = await hashed(listing.files, downloads: downloads(), generation: generation)
        let loaded = result.files.filter(\.evict).map(\.local.url)
        guard isCurrent(generation) else {
            await KnowledgeICloud.evict(loaded)
            return
        }
        // Scans saved since the walk began, which it may have missed: listed, or the server would
        // count them missing once their upload is in.
        var files = result.files
        let listed = Set(files.map(\.local.path))
        for scan in (scansDuringRun ?? [:]).values.sorted(by: { $0.local.path < $1.local.path })
        where !listed.contains(scan.local.path) && FileManager.default.fileExists(atPath: scan.local.url.path) {
            files.append(scan)
        }
        cache.keep(only: Set(files.map(\.local.path)))
        persistCache()

        let wanted: [String]
        do {
            let body = KnowledgeManifestBody(folderId: folderID, files: files.map(\.entry),
                                             device: KnowledgeDevice.normalized(deviceName))
            wanted = try await api.sendKnowledgeManifest(body)
        } catch {
            await KnowledgeICloud.evict(loaded)
            guard isCurrent(generation) else { return }
            if Self.isFolderGone(error), await folderReplaced(folderID, generation: generation) { return }
            KnowledgeFolder.log.error("Manifest: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            return
        }
        guard isCurrent(generation) else {
            await KnowledgeICloud.evict(loaded)
            return
        }
        let asked = Set(wanted.map(\.precomposedStringWithCanonicalMapping))
        unreadable = unreadable.filter { asked.contains($0.key) }
        let byPath = Dictionary(files.map { ($0.local.path, $0) }, uniquingKeysWith: { first, _ in first })
        var queued = Set<String>()
        for match in Self.match(wanted, in: files.filter { $0.hash != nil }.map(\.local)) {
            guard let file = byPath[match.path], let info = file.info else { continue }
            // A scan waiting with the text read already: kept, not read again.
            if let waiting = queue.upload(for: info.path), waiting.textFile != nil, waiting.folderId == folderID,
               waiting.file.hash == info.hash {
                continue
            }
            let upload = KnowledgeUpload(folderId: folderID, file: info, diskPath: match.diskPath,
                                         evict: file.evict ? true : nil)
            if let old = queue.add(upload) { removeText(old) }
            queued.insert(match.path)
        }
        queueChanged()
        // Loaded only to be hashed: off the device again (the queued ones once they're read).
        await KnowledgeICloud.evict(result.files.filter { $0.evict && !queued.contains($0.local.path) }.map(\.local.url))
        let uploaded = await flush()
        guard isCurrent(generation) else { return }
        lastRun = Run(finished: Date(), files: files.count, uploaded: uploaded, tooLarge: listing.tooLarge,
                      unhashable: result.unhashable, deferred: result.deferred)
        if case .failed = phase {} else { phase = .idle }
    }

    @concurrent
    private static func walk(_ root: URL) async -> KnowledgeListing {
        KnowledgeWalker.walk(root)
    }

    /// A listed file with its hash: what the manifest says of it, and where it is on the disk.
    private struct Hashed {
        /// Its size, date and tags as the manifest gives them.
        var local: KnowledgeLocalFile
        /// nil: present, but no hash known (the server keeps its document as it is).
        var hash: String?
        /// iCloud loaded it for this run: taken off the device again.
        var evict: Bool

        var entry: KnowledgeManifestFile {
            KnowledgeManifestFile(path: local.path, size: local.size, mtime: local.mtime, hash: hash, tags: local.tags)
        }

        var info: KnowledgeFileInfo? {
            hash.map { KnowledgeFileInfo(path: local.path, size: local.size, mtime: local.mtime, hash: $0, tags: local.tags) }
        }
    }

    /// Every listed file with its hash (`KnowledgeHashStep.plan`): the cache's where it's
    /// unchanged, else read (`hashingWidth` at a time; a file iCloud keeps off the device is loaded
    /// while `downloads` allow). A file that couldn't be hashed is still listed, with its last hash
    /// at the same size, else with none: leaving it out would make it missing.
    private func hashed(_ listed: [KnowledgeLocalFile], downloads: KnowledgeDownloads,
                        generation: Int) async -> (files: [Hashed], unhashable: Int, deferred: Int) {
        let steps = KnowledgeHashStep.plan(listed, cache: cache, downloads: downloads)
        var files = listed
        var hashes = [String?](repeating: nil, count: files.count)
        var evict = [Bool](repeating: false, count: files.count)
        var todo: [Int] = []
        var unhashable = 0, deferred = 0

        /// Not hashed this time: the last hash and what's known of it.
        func fallBack(_ index: Int) {
            let path = files[index].path
            hashes[index] = cache.lastHash(path: path, size: files[index].size)
            if !files[index].downloaded {
                // A placeholder's date isn't the file's.
                files[index].mtime = cache.entries[path]?.mtime ?? 0
                files[index].tags = cache.tags(for: path)
            }
        }

        for (index, step) in steps.enumerated() {
            switch step {
            case let .cached(entry):
                hashes[index] = entry.hash
                if !files[index].downloaded {
                    files[index].mtime = entry.mtime
                    files[index].tags = entry.tags
                }
            case .hash:
                todo.append(index)
            case .download:
                todo.append(index)
                evict[index] = true
            case .later:
                deferred += 1
                fallBack(index)
            }
        }
        if !todo.isEmpty {
            phase = .hashing(done: 0, of: todo.count)
            var done = 0
            await withTaskGroup(of: (Int, (hash: String, size: Int64, mtime: Int64)?).self) { group in
                var next = todo.makeIterator()
                func start() {
                    guard let index = next.next() else { return }
                    let url = files[index].url
                    group.addTask { (index, await Self.hash(url)) }
                }
                for _ in 0..<Self.hashingWidth { start() }
                for await (index, result) in group {
                    // Stopped: what's under way ends, nothing more starts or is kept.
                    guard isCurrent(generation) else { continue }
                    done += 1
                    phase = .hashing(done: done, of: todo.count)
                    if let result {
                        if !files[index].downloaded {
                            // Loaded now: its own size, date and tags.
                            files[index].size = result.size
                            files[index].mtime = result.mtime
                            files[index].downloaded = true
                            let tags = KnowledgeTags.cleaned(FinderTags.read(files[index].url))
                            if !tags.isEmpty { files[index].tags = tags }
                        }
                        hashes[index] = result.hash
                        cache.set(files[index], hash: result.hash)
                    } else {
                        unhashable += 1
                        fallBack(index)
                    }
                    start()
                }
            }
        }
        let result = files.indices.map { Hashed(local: files[$0], hash: hashes[$0], evict: evict[$0]) }
        return (result, unhashable, deferred)
    }

    @concurrent
    private static func hash(_ url: URL) async -> (hash: String, size: Int64, mtime: Int64)? {
        do {
            return try KnowledgeHasher.sha256(url)
        } catch {
            KnowledgeFolder.log.error("Can't hash \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
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

    // MARK: The server's folder

    static func isFolderGone(_ error: any Error) -> Bool {
        if case let APIError.http(status, _) = error { status == 404 } else { false }
    }

    /// After a 404 for the folder: whether the family's folder on the server is another one now (or
    /// none). Then this device's link becomes `.replaced` and its uploads go.
    private func folderReplaced(_ folderID: String, generation: Int) async -> Bool {
        let current: KnowledgeFolderInfo?
        do {
            current = try await api.knowledgeFolder()
        } catch {
            return false
        }
        guard isCurrent(generation), current?.id != folderID, folder.state().folderID == folderID else { return false }
        folder.markReplaced()
        retryWait?.cancel()
        retryWait = nil
        for name in queue.removeAll(where: { $0.folderId == folderID }) { removeText(name) }
        persistQueue()
        unreadable = [:]
        phase = .idle
        return true
    }

    // MARK: A scan

    /// Queues `file` (just written into the knowledge folder) with the text read already (a
    /// scan's): hashed now, uploaded without reading it again; the next manifest finds its hash.
    func enqueue(file: URL, pages: [String]) async throws {
        let generation = gate.current
        guard isCurrent(generation) else { return }
        guard case let .linked(root, folderID) = folder.state() else { throw KnowledgeFolderError.missing }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        guard let diskPath = Self.relativePath(of: file, in: root) else { throw KnowledgeFolderError.notInFolder }
        let path = diskPath.precomposedStringWithCanonicalMapping
        guard KnowledgeWalker.isValidPath(path) else { throw KnowledgeFolderError.notInFolder }
        guard let hashed = await Self.hash(file) else { throw CocoaError(.fileReadUnknown) }
        let tags = KnowledgeTags.cleaned(FinderTags.read(file))
        let local = KnowledgeLocalFile(path: path, url: file, size: hashed.size, mtime: hashed.mtime, tags: tags)
        let name = "\(UUID().uuidString).json"
        let texts = textsFolder, limited = KnowledgeText.limited(pages), signOuts = signOuts, gate = gate
        let written = try await Task.detached(priority: .utility) {
            try Self.writeText(limited, name: name, in: texts, signOuts: signOuts, gate: gate, generation: generation)
        }.value
        guard written else { return }
        await ensureCache()
        await ensureQueue()
        guard isCurrent(generation) else {
            removeText(name)
            return
        }
        cache.set(local, hash: hashed.hash)
        persistCache()
        scansDuringRun?[path] = Hashed(local: local, hash: hashed.hash, evict: false)
        let info = KnowledgeFileInfo(path: path, size: hashed.size, mtime: hashed.mtime, hash: hashed.hash, tags: tags)
        if let old = queue.add(KnowledgeUpload(folderId: folderID, file: info, diskPath: diskPath, textFile: name)) {
            removeText(old)
        }
        persistQueue()
        await diskIdle()
        // A run under way sends it after its manifest (which lists it).
        if runTask == nil { Task { await flushInFolder() } }
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

    // MARK: Uploading

    /// The connection is back, or the app active again: what waits is sent now, not after the
    /// backoff.
    func retryNow() {
        retryDelay = 2
        retryWait?.cancel()
        retryWait = nil
        if flushingGeneration == nil, !queue.isEmpty, runTask == nil { Task { await flushInFolder() } }
    }

    /// `flush` with the folder's security scope (not from a run, which holds it).
    private func flushInFolder() async {
        guard let root = folder.state().url else { return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        await flush()
    }

    /// Sends the queue in order; returns how many the server took. A file that can't be read on
    /// this device is skipped (`unreadable`); a refusal is dropped; no connection waits. A file
    /// that changed since it was hashed is dropped too: the next run sends it (never a run at once,
    /// which could go round without a pause).
    @discardableResult
    private func flush() async -> Int {
        let generation = gate.current
        await ensureQueue()
        await ensureCache()
        // A flush under way sends what's queued now too (it goes on until the queue is empty).
        guard isCurrent(generation), flushingGeneration != generation, !queue.isEmpty else { return 0 }
        guard case let .linked(root, folderID) = folder.state() else { return 0 }
        flushingGeneration = generation
        defer { if flushingGeneration == generation { flushingGeneration = nil } }
        let downloads = downloads()
        var sent = 0, done = 0
        var unreadableNow = unreadable
        var cacheChanged = false
        /// Waits for the connection (a retry is scheduled).
        var waits = false
        // Again while uploads came in (a scan; another flush leaves them to this one) after the
        // queue looked empty.
        repeat {
            while isCurrent(generation), let upload = queue.first {
                phase = .uploading(done: done, of: done + queue.count)
                guard upload.folderId == folderID else {
                    drop(upload)
                    continue
                }
                let path = upload.file.path
                if upload.textFile == nil, cache.readFailed(path: path, hash: upload.file.hash) {
                    unreadableNow[path] = .failed
                    drop(upload)
                    done += 1
                    continue
                }
                let read = await text(of: upload, root: root, downloads: downloads)
                guard isCurrent(generation) else { break }
                let pages: [String]
                switch read {
                case let .pages(text):
                    pages = text
                case let .unreadable(reason):
                    unreadableNow[path] = reason
                    if reason == .failed, upload.textFile == nil {
                        cache.setReadFailed(path: path, hash: upload.file.hash)
                        cacheChanged = true
                    }
                    drop(upload)
                    done += 1
                    continue
                case .later:
                    // Changed since it was hashed, not on the device now or not loaded: the next run.
                    drop(upload)
                    done += 1
                    continue
                }
                do {
                    try await api.uploadKnowledgeDocument(KnowledgeUploadBody(folderId: folderID, file: upload.file,
                                                                              pages: pages))
                    guard isCurrent(generation) else { break }
                    unreadableNow[path] = nil
                    drop(upload)
                    sent += 1
                    done += 1
                    retryDelay = 2
                } catch {
                    guard isCurrent(generation) else { break }
                    if KnowledgeUploadQueue.disposition(of: error) == .retry {
                        phase = .failed(error.localizedDescription)
                        scheduleRetry()
                        waits = true
                        break
                    }
                    if Self.isFolderGone(error), await folderReplaced(folderID, generation: generation) { return sent }
                    KnowledgeFolder.log.error("Upload refused: \(error.localizedDescription, privacy: .public)")
                    drop(upload)
                    done += 1
                }
            }
            guard isCurrent(generation) else { return sent }
            unreadable = unreadableNow
            if cacheChanged { persistCache() }
            persistQueue()
            await diskIdle()
        } while !waits && isCurrent(generation) && !queue.isEmpty
        if queue.isEmpty, case .uploading = phase { phase = .idle }
        return sent
    }

    private enum UploadText {
        case pages([String])
        /// This device didn't read the file.
        case unreadable(Unreadable)
        /// Not now: it changed since it was hashed, isn't on the device and may not be loaded now,
        /// or couldn't be loaded.
        case later
    }

    /// The upload's pages: its queued text, else read from the file (loaded from iCloud when it
    /// isn't on the device and `downloads` allow; taken off again once read).
    private func text(of upload: KnowledgeUpload, root: URL, downloads: KnowledgeDownloads) async -> UploadText {
        if let name = upload.textFile {
            let file = textsFolder.appending(path: name)
            let pages = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            }.value
            return pages.map { .pages($0) } ?? .unreadable(.failed)
        }
        let url = upload.diskPath.split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .notDirectory)
        }
        guard KnowledgeText.canRead(url) else { return .unreadable(.format) }
        let state = await Self.inspect(url)
        if !state.onDevice, !downloads.allowed { return .later }
        if let size = state.size, size != upload.file.size { return .later }
        if state.onDevice, let mtime = state.mtime, mtime != upload.file.mtime { return .later }
        let outcome = await KnowledgeText.read(url)
        if upload.evict == true || !state.onDevice { await KnowledgeICloud.evict([url]) }
        switch outcome {
        case let .pages(pages): return .pages(pages)
        case .unsupported: return .unreadable(.format)
        case .failed: return .unreadable(.failed)
        case .unavailable: return .later
        }
    }

    /// Whether the file is on the device, and its size and date where the disk says.
    @concurrent
    private static func inspect(_ url: URL) async -> (onDevice: Bool, size: Int64?, mtime: Int64?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (KnowledgeICloud.isOnDevice(url), values?.fileSize.map(Int64.init),
                values?.contentModificationDate.map { KnowledgeWalker.milliseconds($0) })
    }

    /// Takes `upload` out of the queue (itself: one queued for its path since with another hash
    /// stays), with its text.
    private func drop(_ upload: KnowledgeUpload) {
        if let removed = queue.remove(upload), let name = removed.textFile { removeText(name) }
        queueChanged()
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retryWait?.cancel()
        retryWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            retryWait = nil
            await flushInFolder()
        }
    }

    // MARK: On the disk

    private func ensureQueue() async {
        guard !queueLoaded else { return }
        let file = queueFile
        let loaded = await Task.detached(priority: .utility) { KnowledgeUploadQueue.load(file) }.value
        guard !queueLoaded else { return }
        queue = loaded
        queueLoaded = true
        waiting = queue.count
    }

    private func ensureCache() async {
        guard !cacheLoaded else { return }
        let file = hashesFile
        let loaded = await Task.detached(priority: .utility) { KnowledgeHashCache.load(file) }.value
        guard !cacheLoaded else { return }
        cache = loaded
        cacheLoaded = true
    }

    /// The queue changed: written within `queueSaveDelay`.
    private func queueChanged() {
        waiting = queue.count
        guard queueSave == nil else { return }
        queueSave = Task { [weak self] in
            try? await Task.sleep(for: Self.queueSaveDelay)
            guard !Task.isCancelled, let self else { return }
            queueSave = nil
            persistQueue()
        }
    }

    /// Writes the queue now.
    private func persistQueue() {
        queueSave?.cancel()
        queueSave = nil
        waiting = queue.count
        guard queueLoaded else { return }
        let snapshot = queue, file = queueFile
        onDisk { try? snapshot.save(to: file) }
    }

    private func persistCache() {
        guard cacheLoaded else { return }
        let snapshot = cache, file = hashesFile
        onDisk { try? snapshot.save(to: file) }
    }

    private func removeText(_ name: String) {
        let file = textsFolder.appending(path: name)
        onDisk { try? FileManager.default.removeItem(at: file) }
    }

    /// Runs `work` off the main actor after the disk work before it, unless the generation it was
    /// asked in has passed by then (signed out, the folder chosen anew or removed).
    private func onDisk(_ work: @escaping @Sendable () -> Void) {
        let signOuts = signOuts, generation = gate.current, gate = gate
        let previous = diskChain
        diskChain = Task.detached(priority: .utility) {
            await previous?.value
            KnowledgeDiskGate.signOuts.run(at: signOuts) { gate.run(at: generation, work) }
        }
    }

    /// Waits for the disk work asked for so far.
    private func diskIdle() async {
        await diskChain?.value
    }

    // MARK: Choosing and removing the folder

    /// Makes `url` the family's folder on this device (`KnowledgeFolder.link`). What runs stops
    /// first; once linked, what the device kept of the folder before goes (hash cache, uploads,
    /// texts).
    func link(_ url: URL, accepted: KnowledgeFolderError? = nil) async throws {
        stop()
        try await folder.link(url, api: api, accepted: accepted)
        await clear()
    }

    /// Forgets the folder on this device (Settings → Knowledge): the link, the hash cache, the
    /// uploads waiting and their texts. What runs stops and writes nothing more. The server keeps
    /// its index; the folder keeps its marker.
    func unlink() async {
        stop()
        folder.unlink()
        await clear()
    }

    /// Stops the run and the uploads under way: a new generation.
    private func stop() {
        gate.bump()
        runTask?.cancel()
        runTask = nil
        runID = nil
        runAgain = false
        flushingGeneration = nil
        retryWait?.cancel()
        retryWait = nil
        queueSave?.cancel()
        queueSave = nil
        phase = .idle
    }

    /// Empties what the device keeps of the folder, on the disk too.
    private func clear() async {
        queue = KnowledgeUploadQueue()
        queueLoaded = true
        cache = KnowledgeHashCache()
        cacheLoaded = true
        waiting = 0
        unreadable = [:]
        lastRun = nil
        let files = [queueFile, hashesFile, textsFolder]
        onDisk { for file in files { try? FileManager.default.removeItem(at: file) } }
        await diskIdle()
    }

    // MARK: Signing out

    /// Signing out or pairing anew: every family's folder link, hash cache and queue of `server`
    /// goes; the indexers made before stop.
    static func removeAll(server: URL) {
        KnowledgeDiskGate.signOuts.bump()
        KnowledgeFolder.removeAll(server: server)
    }
}

/// A counter the indexer's disk work checks before it writes: it runs only while the counter is
/// what it was when the work was asked for (`run(at:)` holds the lock, so a `bump` waits for it).
nonisolated final class KnowledgeDiskGate: @unchecked Sendable {
    /// Grows with every sign-out (`KnowledgeIndexer.removeAll`).
    static let signOuts = KnowledgeDiskGate()

    private let lock = NSLock()
    private var value = 0

    var current: Int { lock.withLock { value } }

    func bump() {
        lock.withLock { value += 1 }
    }

    func run(at expected: Int, _ work: () -> Void) {
        lock.withLock { if value == expected { work() } }
    }
}

nonisolated enum KnowledgeIndexError: LocalizedError, Equatable {
    case tooManyFiles
    /// A folder in the knowledge folder (or itself) couldn't be listed: nothing was sent.
    case unlistable(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles:
            String(localized: "The knowledge folder holds more than 20,000 files. Choose a folder with fewer.")
        case let .unlistable(folder):
            String(localized: "Ohana can’t open the folder “\(folder)”, so nothing was sent. It’s tried again next time.")
        }
    }
}

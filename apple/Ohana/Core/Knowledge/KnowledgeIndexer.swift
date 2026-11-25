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

    var phase: Phase = .idle
    private(set) var lastRun: Run?
    /// Files the server asked for that this device didn't send, and why; by path.
    var unreadable: [String: Unreadable] = [:]
    /// Uploads waiting (or being sent).
    private(set) var waiting = 0
    /// *Read All* until it's done (`readAll`): its files still to read, its summaries still to ask
    /// for. Kept on the disk; resumed by the next run, a retry or the connection coming back.
    private(set) var readingAll: KnowledgeReadAll?
    /// Settings → Knowledge's one progress bar, kept here so it keeps its total while the
    /// settings are closed (the settings update it with each status).
    var work = KnowledgeWorkProgress()

    @ObservationIgnored var queue = KnowledgeUploadQueue()
    @ObservationIgnored private var queueLoaded = false
    /// `finishReadAll` is asking for the summaries.
    @ObservationIgnored private var finishingReadAll = false
    @ObservationIgnored var cache = KnowledgeHashCache()
    @ObservationIgnored private var cacheLoaded = false
    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var runAgain = false
    /// The scans queued (`enqueue`) since the running run started its walk, by path: listed in its
    /// manifest even when the walk missed them. nil while no run walks.
    @ObservationIgnored private var scansDuringRun: [String: Hashed]?
    @ObservationIgnored private var lastStart: Date?
    /// The generation a flush is under way for.
    @ObservationIgnored var flushingGeneration: Int?
    @ObservationIgnored var retryDelay: Double = 2
    /// The server's word on page images (`scanStatus`), and when it was asked.
    @ObservationIgnored var scanStatusCache: (status: KnowledgeScanStatus, at: Date)?
    @ObservationIgnored var retryWait: Task<Void, Never>?
    @ObservationIgnored private var queueSave: Task<Void, Never>?
    /// The disk work, one after the other.
    @ObservationIgnored private var diskChain: Task<Void, Never>?
    /// Grows when the folder is chosen anew or removed: what an older run would still do is void.
    @ObservationIgnored let gate = KnowledgeDiskGate()
    /// `removeAll` ran since this indexer was made (signed out): it sends and keeps nothing more.
    @ObservationIgnored private let signOuts: Int

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
    private var readAllFile: URL { directory.appending(path: "read-all.json") }
    var textsFolder: URL { directory.appending(path: "texts", directoryHint: .isDirectory) }
    private var closed: Bool { signOuts != KnowledgeDiskGate.signOuts.current }

    /// Still the generation `generation` (not signed out, the folder not chosen anew or removed).
    func isCurrent(_ generation: Int) -> Bool {
        !closed && gate.current == generation
    }
}

// MARK: - Running

extension KnowledgeIndexer {

    /// A run unless one started within `minimumInterval` (launch, active again, the Mac's timer).
    func runIfDue(now: Date = Date()) async {
        await ensureQueue()
        // *Read All* hasn't read the files yet: no waiting for the interval.
        if let lastStart, now.timeIntervalSince(lastStart) < Self.minimumInterval, readingAll?.files != true {
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

    /// *Read All*: a run that reads every file of the folder again on this device and sends it with
    /// `reread` (the server takes its text anew where it changed), not only those the server asks
    /// for; a file's failed reads count no more. Then, with `summaries`, every summary is written
    /// anew (POST /knowledge/cards {all}; a server that writes none refuses, which ends it). Queued
    /// after a run under way, like `run()`. Kept on the disk until done: a lost connection retries
    /// with the uploads' backoff and when it's back, a restart picks it up.
    func readAll(summaries: Bool) async {
        await ensureQueue()
        guard !closed else { return }
        setReadingAll(KnowledgeReadAll(summaries: summaries || readingAll?.summaries == true))
        await run()
    }

    private func runOnce() async {
        let generation = gate.current
        guard isCurrent(generation) else { return }
        guard let (root, folderID) = folderToRead() else { return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        scansDuringRun = [:]
        defer { scansDuringRun = nil }
        guard let listing = await listed(root, generation: generation) else { return }
        // A folder that looks empty (iCloud signed out, the share left, really empty) sends
        // nothing: an empty manifest would tell the server nothing anyway.
        guard !listing.files.isEmpty else {
            await emptyFolder(listing)
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
        var files = result.files
        added(&files)
        cache.keep(only: Set(files.map(\.local.path)))
        persistCache()

        guard let wanted = await manifest(files, folderID: folderID, generation: generation, loaded: loaded) else {
            return
        }
        await sentRun(wanted, files: files, hashed: result.files, folderID: folderID, generation: generation,
                      listing: listing, unhashable: result.unhashable, deferred: result.deferred)
    }

    /// The folder a run reads: its URL and the server's id; nil when there is nothing to read
    /// (the phase says why).
    private func folderToRead() -> (root: URL, folderID: String)? {
        switch folder.state() {
        case .none, .replaced:
            phase = .idle
            return nil
        case .missing:
            phase = .failed(KnowledgeFolderError.missing.localizedDescription)
            return nil
        case let .linked(url, id):
            return (url, id)
        }
    }

    /// The folder's files for a run; nil when the run stops here (the phase says why).
    private func listed(_ root: URL, generation: Int) async -> KnowledgeListing? {
        phase = .scanning
        let listing = await Self.walk(root)
        await walked()
        guard isCurrent(generation) else { return nil }
        if listing.truncated {
            phase = .failed(KnowledgeIndexError.tooManyFiles.localizedDescription)
            return nil
        }
        // A folder that can't be listed whole mustn't be sent: its files would count as missing.
        if let folderPath = listing.unlistable.first {
            let name = folderPath.isEmpty ? FileManager.default.displayName(atPath: root.path) : folderPath
            phase = .failed(KnowledgeIndexError.unlistable(name).localizedDescription)
            return nil
        }
        return listing
    }

    /// A run over an empty folder: it sent nothing; *Read All* has no files to read and goes on to
    /// its summaries.
    private func emptyFolder(_ listing: KnowledgeListing) async {
        lastRun = Run(finished: Date(), files: 0, tooLarge: listing.tooLarge)
        phase = .idle
        guard var job = readingAll, job.files else { return }
        job.files = false
        job.total = 0
        setReadingAll(job)
        await finishReadAll()
    }

    /// Scans saved since the walk began, which it may have missed: listed, or the server would
    /// count them missing once their upload is in.
    private func added(_ files: inout [Hashed]) {
        let listed = Set(files.map(\.local.path))
        for scan in (scansDuringRun ?? [:]).values.sorted(by: { $0.local.path < $1.local.path })
        where !listed.contains(scan.local.path) && FileManager.default.fileExists(atPath: scan.local.url.path) {
            files.append(scan)
        }
    }

    /// The run's manifest: the paths the server asks for; nil when it failed (the phase says why,
    /// and what iCloud loaded goes off the device again).
    private func manifest(_ files: [Hashed], folderID: String, generation: Int, loaded: [URL]) async -> [String]? {
        let wanted: [String]
        do {
            let body = KnowledgeManifestBody(folderId: folderID, files: files.map(\.entry),
                                             device: KnowledgeDevice.normalized(deviceName))
            wanted = try await api.sendKnowledgeManifest(body)
        } catch {
            await KnowledgeICloud.evict(loaded)
            guard isCurrent(generation) else { return nil }
            if Self.isFolderGone(error), await folderReplaced(folderID, generation: generation) { return nil }
            KnowledgeFolder.log.error("Manifest: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
            // *Read All* tries again by itself (an ordinary run waits for the next trigger).
            if readingAll?.files == true, KnowledgeUploadQueue.disposition(of: error) == .retry { scheduleRetry() }
            return nil
        }
        guard isCurrent(generation) else {
            await KnowledgeICloud.evict(loaded)
            return nil
        }
        return wanted
    }

    /// What the manifest's answer brings: the uploads it asked for queued, the flush, and the run's
    /// record. *Read All* reads every file with a hash again; an ordinary run only what was asked.
    private func sentRun(_ wanted: [String], files: [Hashed], hashed: [Hashed], folderID: String, generation: Int,
                         listing: KnowledgeListing, unhashable: Int, deferred: Int) async {
        let everything = readingAll?.files == true
        let paths = everything ? files.compactMap { $0.hash == nil ? nil : $0.local.path } : wanted
        forgetUnreadable(paths)
        let queued = queueUploads(paths, files: files, folderID: folderID, everything: everything)
        queueChanged()
        if everything, var job = readingAll {
            job.files = false
            job.total = queued.matched
            setReadingAll(job)
        }
        // Loaded only to be hashed: off the device again (the queued ones once they're read).
        await evict(hashed, queued: queued.queued)
        let uploaded = await flush()
        guard isCurrent(generation) else { return }
        lastRun = Run(finished: Date(), files: files.count, uploaded: uploaded, tooLarge: listing.tooLarge,
                      unhashable: unhashable, deferred: deferred)
        await finishReadAll()
        guard isCurrent(generation) else { return }
        if case .failed = phase {} else { phase = .idle }
    }

    /// Files this device couldn't read that the server no longer asks for: forgotten.
    private func forgetUnreadable(_ paths: [String]) {
        guard !unreadable.isEmpty else { return }
        let asked = Set(paths.map(\.precomposedStringWithCanonicalMapping))
        unreadable = unreadable.filter { asked.contains($0.key) }
    }

    /// The uploads the run queues for the server's paths: how many of them were matched to a file,
    /// and which of those paths are queued now.
    private func queueUploads(_ paths: [String], files: [Hashed], folderID: String, everything: Bool)
        -> (matched: Int, queued: Set<String>) {
        // Most runs are asked for nothing: then no look-ups over every file (on the main actor).
        let byPath = paths.isEmpty ? [:] : Dictionary(files.map { ($0.local.path, $0) },
                                                      uniquingKeysWith: { first, _ in first })
        var matched = 0
        var queued = Set<String>()
        for match in paths.isEmpty ? [] : Self.match(paths, in: files.filter { $0.hash != nil }.map(\.local)) {
            guard let file = byPath[match.path], let info = file.info else { continue }
            matched += 1
            // A scan waiting with the text read already, or one the user asked to read again: kept.
            guard !keptWaiting(for: info, folderID: folderID) else { continue }
            let upload = KnowledgeUpload(folderId: folderID, file: info, diskPath: match.diskPath,
                                         evict: file.evict ? true : nil, reread: everything ? true : nil)
            if let old = queue.add(upload) { removeText(old) }
            queued.insert(match.path)
        }
        return (matched, queued)
    }

    /// A scan of the file that waits with its text read already, or one the user asked to read
    /// again: it stays in the queue as it is.
    private func keptWaiting(for info: KnowledgeFileInfo, folderID: String) -> Bool {
        guard let waiting = queue.upload(for: info.path) else { return false }
        return (waiting.textFile != nil || waiting.reread == true) && waiting.folderId == folderID
            && waiting.file.hash == info.hash
    }

    /// Files iCloud loaded for this run: off the device again, except those now queued (they are
    /// taken off once they have been read).
    private func evict(_ files: [Hashed], queued: Set<String>) async {
        let idle = files.filter { $0.evict && !queued.contains($0.local.path) }.map(\.local.url)
        await KnowledgeICloud.evict(idle)
    }

    /// *Read All* once its files are all sent: every summary asked for anew, then done. A lost
    /// connection keeps it for a retry; a refusal (a server that writes no summaries) ends it.
    private func finishReadAll() async {
        guard let job = readingAll, !job.files, queue.isEmpty, flushingGeneration == nil,
              !finishingReadAll, !closed else { return }
        let generation = gate.current
        if job.summaries {
            finishingReadAll = true
            defer { finishingReadAll = false }
            do {
                _ = try await api.rewriteKnowledgeCards(all: true)
            } catch {
                guard isCurrent(generation) else { return }
                if KnowledgeUploadQueue.disposition(of: error) == .retry {
                    phase = .failed(error.localizedDescription)
                    scheduleRetry()
                    return
                }
                KnowledgeFolder.log.error("Summaries: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard isCurrent(generation) else { return }
        setReadingAll(nil)
        if case .failed = phase { phase = .idle }
    }

    /// What *Read All* still has to do, kept on the disk.
    private func setReadingAll(_ job: KnowledgeReadAll?) {
        readingAll = job
        let file = readAllFile
        onDisk { try? KnowledgeReadAll.save(job, to: file) }
    }

    /// Goes on with what waits after a lost connection: *Read All*'s run, else the uploads, then
    /// its summaries.
    func resume() async {
        if readingAll?.files == true {
            if runTask == nil { await run() }
            return
        }
        await flushInFolder()
        await finishReadAll()
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
}

// MARK: - The server's folder, a scan and reading a file again

extension KnowledgeIndexer {

    /// After a 404 for the folder: whether the family's folder on the server is another one now (or
    /// none). Then this device's link becomes `.replaced` and its uploads go.
    func folderReplaced(_ folderID: String, generation: Int) async -> Bool {
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

    // MARK: Reading a file again

    /// Reads the document at `path` again on this device now, with the current reader, and uploads
    /// it with `reread` (the server takes new text even from the same reader); `assistant`: every
    /// page's image goes to the family's AI too (*Read Again with the Assistant*). Needs this
    /// device's folder with the file in it: throws `KnowledgeOriginalError` otherwise. Returns once
    /// it's sent (or waits for the connection).
    func reread(path: String, assistant: Bool) async throws -> RereadOutcome {
        let generation = gate.current
        guard isCurrent(generation) else { return .waiting }
        let state = folder.state()
        let root = try KnowledgeOriginal.linkedRoot(state)
        guard let folderID = state.folderID else { throw KnowledgeOriginalError.noFolder }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        guard let url = await Self.locate(path, in: root) else { throw KnowledgeOriginalError.notFound }
        guard KnowledgeText.canRead(url) else { return .unreadable(.format) }
        let onDevice = await Self.inspect(url).onDevice
        // Loaded from iCloud first when it isn't on the device.
        guard let hashed = await Self.hash(url) else { throw KnowledgeOriginalError.unreadable }
        guard let diskPath = Self.relativePath(of: url, in: root) else { throw KnowledgeOriginalError.notFound }
        let nfc = diskPath.precomposedStringWithCanonicalMapping
        let tags = KnowledgeTags.cleaned(FinderTags.read(url))
        await ensureCache()
        await ensureQueue()
        guard isCurrent(generation) else { return .waiting }
        let local = KnowledgeLocalFile(path: nfc, url: url, size: hashed.size, mtime: hashed.mtime, tags: tags)
        cache.set(local, hash: hashed.hash)
        persistCache()
        let info = KnowledgeFileInfo(path: nfc, size: hashed.size, mtime: hashed.mtime, hash: hashed.hash, tags: tags)
        let upload = KnowledgeUpload(folderId: folderID, file: info, diskPath: diskPath, evict: onDevice ? nil : true,
                                     reread: true, force: assistant ? true : nil)
        if let old = queue.add(upload) { removeText(old) }
        persistQueue()
        unreadable[nfc] = nil
        if flushingGeneration == nil { await flush() }
        // A flush under way (a run's) sends it: waited for, while it goes on.
        func pending() -> Bool { queue.upload(for: nfc)?.isSame(as: upload) == true }
        var waited = 0
        while isCurrent(generation), pending(), retryWait == nil, flushingGeneration != nil, waited < 2400 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        if let reason = unreadable[nfc] { return .unreadable(reason) }
        return pending() ? .waiting : .sent
    }
}

// MARK: - On the disk, the folder and signing out

extension KnowledgeIndexer {

    func ensureQueue() async {
        guard !queueLoaded else { return }
        let file = queueFile, jobFile = readAllFile
        let (loaded, job) = await Task.detached(priority: .utility) {
            (KnowledgeUploadQueue.load(file), KnowledgeReadAll.load(jobFile))
        }.value
        guard !queueLoaded else { return }
        queue = loaded
        queueLoaded = true
        waiting = queue.count
        if readingAll == nil { readingAll = job }
    }

    func ensureCache() async {
        guard !cacheLoaded else { return }
        let file = hashesFile
        let loaded = await Task.detached(priority: .utility) { KnowledgeHashCache.load(file) }.value
        guard !cacheLoaded else { return }
        cache = loaded
        cacheLoaded = true
    }

    /// The queue changed: written within `queueSaveDelay`.
    func queueChanged() {
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
    func persistQueue() {
        queueSave?.cancel()
        queueSave = nil
        waiting = queue.count
        guard queueLoaded else { return }
        let snapshot = queue, file = queueFile
        onDisk { try? snapshot.save(to: file) }
    }

    func persistCache() {
        guard cacheLoaded else { return }
        let snapshot = cache, file = hashesFile
        onDisk { try? snapshot.save(to: file) }
    }

    func removeText(_ name: String) {
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
    func diskIdle() async {
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
        readingAll = nil
        unreadable = [:]
        lastRun = nil
        let files = [queueFile, hashesFile, textsFolder, readAllFile]
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

// KnowledgeIndexerRunning.swift
// Ohana
//
// One run of the knowledge indexer: what asks for it, the listing it works from and the steps
// of the run itself. The folder link, the queue and the hash cache live in KnowledgeIndexer.swift.

import Foundation

extension KnowledgeIndexer {
    // MARK: Running

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

    func runOnce() async {
        let generation = gate.current
        guard isCurrent(generation) else { return }
        guard let linked = linkedRoot() else { return }
        let access = linked.root.startAccessingSecurityScopedResource()
        defer { if access { linked.root.stopAccessingSecurityScopedResource() } }
        phase = .scanning
        scansDuringRun = [:]
        defer { scansDuringRun = nil }
        guard let listing = await listed(generation, root: linked.root) else { return }
        await readAndSend(listing, root: linked.root, folderID: linked.folderID, generation: generation)
    }

    /// The folder this run reads, or nil when there is none to read (the phase says why).
    func linkedRoot() -> (root: URL, folderID: String)? {
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

    /// The folder walked, or nil when this run stops here (the phase says why).
    func listed(_ generation: Int, root: URL) async -> KnowledgeListing? {
        let listing = await Self.walk(root)
        await walked()
        guard isCurrent(generation) else { return nil }
        if let failure = listingFailure(listing, root: root) {
            phase = .failed(failure)
            return nil
        }
        // A folder that looks empty (iCloud signed out, the share left, really empty) sends
        // nothing: an empty manifest would tell the server nothing anyway.
        guard !listing.files.isEmpty else {
            lastRun = Run(finished: Date(), files: 0, tooLarge: listing.tooLarge)
            phase = .idle
            await finishReadAllWithoutFiles()
            return nil
        }
        return listing
    }

    /// Why this folder can't be sent whole: the words of the failure (nil when it can).
    func listingFailure(_ listing: KnowledgeListing, root: URL) -> String? {
        guard !listing.truncated else { return KnowledgeIndexError.tooManyFiles.localizedDescription }
        // A folder that can't be listed whole mustn't be sent: its files would count as missing.
        guard let folderPath = listing.unlistable.first else { return nil }
        let name = folderPath.isEmpty ? FileManager.default.displayName(atPath: root.path) : folderPath
        return KnowledgeIndexError.unlistable(name).localizedDescription
    }

    /// *Read All* over a folder with no files: nothing to read, so on to its summaries.
    func finishReadAllWithoutFiles() async {
        guard var job = readingAll, job.files else { return }
        job.files = false
        job.total = 0
        setReadingAll(job)
        await finishReadAll()
    }

    /// The run's work on a listed folder: hash its files, send the manifest, queue what the server
    /// wants and flush it.
    func readAndSend(_ listing: KnowledgeListing, root: URL, folderID: String, generation: Int) async {
        await ensureCache()
        await ensureQueue()
        guard isCurrent(generation) else { return }
        let result = await hashed(listing.files, downloads: downloads(), generation: generation)
        let loaded = result.files.filter(\.evict).map(\.local.url)
        guard isCurrent(generation) else {
            await KnowledgeICloud.evict(loaded)
            return
        }
        let files = withScansDuringRun(result.files)
        cache.keep(only: Set(files.map(\.local.path)))
        persistCache()
        guard let wanted = await wantedPaths(files, folderID: folderID, generation: generation, loaded: loaded) else {
            return
        }
        guard isCurrent(generation) else {
            await KnowledgeICloud.evict(loaded)
            return
        }
        // *Read All*: every file with a hash, read again; else what the server asks for.
        let everything = readingAll?.files == true
        let paths = everything ? files.compactMap { $0.hash == nil ? nil : $0.local.path } : wanted
        forgetUnreadable(paths)
        let queued = queueUploads(paths: paths, files: files, folderID: folderID, everything: everything)
        noteReadAllMatched(everything, matched: queued.matched)
        await evictLoaded(result.files, kept: queued.queued)
        let uploaded = await flush()
        guard isCurrent(generation) else { return }
        lastRun = Run(finished: Date(), files: files.count, uploaded: uploaded, tooLarge: listing.tooLarge,
                      unhashable: result.unhashable, deferred: result.deferred)
        await finishReadAll()
        guard isCurrent(generation) else { return }
        if case .failed = phase {} else { phase = .idle }
    }

    /// The scans saved since the walk began, which it may have missed: listed, or the server would
    /// count them missing once their upload is in.
    func withScansDuringRun(_ files: [Hashed]) -> [Hashed] {
        let listed = Set(files.map(\.local.path))
        var all = files
        for scan in (scansDuringRun ?? [:]).values.sorted(by: { $0.local.path < $1.local.path })
        where !listed.contains(scan.local.path) && FileManager.default.fileExists(atPath: scan.local.url.path) {
            all.append(scan)
        }
        return all
    }

    /// The manifest of `files`, answered with the paths the server wants read again (nil: this run
    /// is over; the phase and a retry say why).
    func wantedPaths(_ files: [Hashed], folderID: String, generation: Int, loaded: [URL]) async -> [String]? {
        do {
            let body = KnowledgeManifestBody(folderId: folderID, files: files.map(\.entry),
                                             device: KnowledgeDevice.normalized(deviceName))
            return try await api.sendKnowledgeManifest(body)
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
    }

    /// The files no longer asked for: what this device couldn't read is forgotten.
    func forgetUnreadable(_ paths: [String]) {
        guard !unreadable.isEmpty else { return }
        let asked = Set(paths.map(\.precomposedStringWithCanonicalMapping))
        unreadable = unreadable.filter { asked.contains($0.key) }
    }

    /// The uploads this run queues for the paths the server wants, and how many of them it found.
    func queueUploads(paths: [String], files: [Hashed], folderID: String, everything: Bool)
        -> (queued: Set<String>, matched: Int) {
        // Most runs are asked for nothing: then no look-ups over every file (on the main actor).
        let byPath = paths.isEmpty ? [:] : Self.byPath(files)
        var queued = Set<String>()
        var matched = 0
        for match in paths.isEmpty ? [] : Self.match(paths, in: files.filter { $0.hash != nil }.map(\.local)) {
            guard let file = byPath[match.path], let info = file.info else { continue }
            matched += 1
            // A scan waiting with the text read already, or one the user asked to read again: kept.
            if keepsWaiting(queue.upload(for: info.path), info: info, folderID: folderID) { continue }
            let upload = KnowledgeUpload(folderId: folderID, file: info, diskPath: match.diskPath,
                                         evict: file.evict ? true : nil, reread: everything ? true : nil)
            if let old = queue.add(upload) { removeText(old) }
            queued.insert(match.path)
        }
        queueChanged()
        return (queued, matched)
    }

    /// The hashed files by path (the first of a name the disk gives twice).
    static func byPath(_ files: [Hashed]) -> [String: Hashed] {
        Dictionary(files.map { ($0.local.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// An upload that stays in the queue: its text is read already, or *Read All* was asked for it,
    /// and it is of this folder and hasn't changed.
    func keepsWaiting(_ upload: KnowledgeUpload?, info: KnowledgeFileInfo, folderID: String) -> Bool {
        guard let waiting = upload, waiting.textFile != nil || waiting.reread == true,
              waiting.folderId == folderID, waiting.file.hash == info.hash else { return false }
        return true
    }

    /// *Read All* has every file of the folder in the queue: the summaries come after the uploads.
    func noteReadAllMatched(_ everything: Bool, matched: Int) {
        guard everything, var job = readingAll else { return }
        job.files = false
        job.total = matched
        setReadingAll(job)
    }

    /// Loaded only to be hashed: off the device again (the queued ones once they're read).
    func evictLoaded(_ files: [Hashed], kept: Set<String>) async {
        await KnowledgeICloud.evict(files.filter { $0.evict && !kept.contains($0.local.path) }.map(\.local.url))
    }

    /// *Read All* once its files are all sent: every summary asked for anew, then done. A lost
    /// connection keeps it for a retry; a refusal (a server that writes no summaries) ends it.
    func finishReadAll() async {
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
    func setReadingAll(_ job: KnowledgeReadAll?) {
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

    @concurrent
    static func walk(_ root: URL) async -> KnowledgeListing {
        KnowledgeWalker.walk(root)
    }
}

// KnowledgeIndexerDisk.swift
// Ohana
//
// The indexer's files on the device (the hash cache and the queue) and choosing, replacing or
// removing the knowledge folder. The run itself lives in KnowledgeIndexerRunning.swift.

import Foundation

extension KnowledgeIndexer {
    // MARK: On the disk

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
    func onDisk(_ work: @escaping @Sendable () -> Void) {
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
    func stop() {
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
    func clear() async {
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

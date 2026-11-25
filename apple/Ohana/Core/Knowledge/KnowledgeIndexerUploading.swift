// KnowledgeIndexerUploading.swift
// Ohana
//
// The upload queue: reading what is queued and sending it to the server, with the pages' images
// for the family's AI. The run itself lives in KnowledgeIndexerRunning.swift.

import Foundation

extension KnowledgeIndexer {
    // MARK: Uploading

    /// The connection is back, or the app active again: what waits is sent now, not after the
    /// backoff.
    func retryNow() {
        retryDelay = 2
        retryWait?.cancel()
        retryWait = nil
        if flushingGeneration == nil, !queue.isEmpty || readingAll != nil, runTask == nil { Task { await resume() } }
    }

    /// `flush` with the folder's security scope (not from a run, which holds it).
    func flushInFolder() async {
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
    func flush() async -> Int {
        let generation = gate.current
        await ensureQueue()
        await ensureCache()
        // A flush under way sends what's queued now too (it goes on until the queue is empty).
        guard isCurrent(generation), flushingGeneration != generation, !queue.isEmpty else { return 0 }
        guard case let .linked(root, folderID) = folder.state() else { return 0 }
        flushingGeneration = generation
        defer { endFlush(generation) }
        let running = Flushing(generation: generation, root: root, folderID: folderID,
                               downloads: downloads(), unreadable: unreadable)
        repeat {
            if await sendQueued(running) == .stop { return running.sent }
            guard isCurrent(generation) else { return running.sent }
            unreadable = running.unreadable
            if running.cacheChanged { persistCache() }
            persistQueue()
            await diskIdle()
        } while running.goesOn(current: isCurrent(generation), queueEmpty: queue.isEmpty)
        if queue.isEmpty, case .uploading = phase { phase = .idle }
        return running.sent
    }

    /// The flush of `generation` is over: only it clears the mark, so a flush that started after
    /// this one keeps its own.
    func endFlush(_ generation: Int) {
        if flushingGeneration == generation { flushingGeneration = nil }
    }

    /// What one upload leaves for the flush: on with the queue, end this round, or end the flush.
    enum Sent {
        case next, round, stop
    }

    /// What a flush keeps as it goes through the queue: how far it got, what it learned of the
    /// files, and whether the connection waits. A class, so its parts can add to it.
    final class Flushing {
        let generation: Int
        let root: URL
        let folderID: String
        let downloads: KnowledgeDownloads
        /// What this device can't read, as the run found it and as this flush learns better.
        var unreadable: [String: Unreadable]
        /// Uploaded, and dropped on the way (for the phase's count).
        var sent = 0
        var done = 0
        /// The cache holds a read failure that this flush saw go away.
        var cacheChanged = false
        /// Waits for the connection (a retry is scheduled).
        var waits = false

        init(generation: Int, root: URL, folderID: String, downloads: KnowledgeDownloads,
             unreadable: [String: Unreadable]) {
            self.generation = generation
            self.root = root
            self.folderID = folderID
            self.downloads = downloads
            self.unreadable = unreadable
        }

        /// Whether the round goes on: the connection doesn't wait, the run still stands and the
        /// queue isn't empty.
        func goesOn(current: Bool, queueEmpty: Bool) -> Bool {
            !waits && current && !queueEmpty
        }
    }

    /// One round of the queue: the uploads in order until it is empty, the folder is gone or the
    /// connection waits.
    func sendQueued(_ running: Flushing) async -> Sent {
        while isCurrent(running.generation), let upload = queue.first {
            phase = .uploading(done: running.done, of: running.done + queue.count)
            guard upload.folderId == running.folderID else {
                drop(upload)
                continue
            }
            let outcome = await sendUpload(upload, running: running)
            if outcome != .next { return outcome }
        }
        return .next
    }

    /// One upload of the queue read and sent; what the flush does next.
    func sendUpload(_ upload: KnowledgeUpload, running: Flushing) async -> Sent {
        switch await readForUpload(upload, running: running) {
        case .round: .round
        case .dropped: .next
        case let .ready(pages, scans, scansChecked):
            await uploadDocument(upload, pages: pages, scans: scans, scansChecked: scansChecked, running: running)
        }
    }

    /// What reading an upload for the flush gave: its text, or that the queue moves on without it,
    /// or that this round ends.
    enum Read {
        case ready(pages: [String], scans: [KnowledgeText.PageScan], scansChecked: Bool)
        case dropped
        case round
    }

    /// The text of an upload, read on this device: which pages and images to send, or why this
    /// upload is out of the queue (or the round is over).
    func readForUpload(_ upload: KnowledgeUpload, running: Flushing) async -> Read {
        let path = upload.file.path
        let reader = KnowledgeText.reader(forPath: path)
        if upload.textFile == nil, upload.reread != true,
           cache.readFailed(path: path, hash: upload.file.hash, reader: reader) {
            running.unreadable[path] = .failed
            drop(upload)
            running.done += 1
            return .dropped
        }
        let capture = await scanCapture(for: upload)
        guard isCurrent(running.generation) else { return .round }
        let read = await text(of: upload, root: running.root, downloads: running.downloads, capture: capture)
        guard isCurrent(running.generation) else { return .round }
        switch read {
        case let .pages(text, images):
            // Read again after a failure: the cache no longer holds it back.
            if upload.textFile == nil, cache.readFailed(path: path, hash: upload.file.hash, reader: reader) {
                cache.setReadFailed(path: path, hash: upload.file.hash, reader: reader, false)
                running.cacheChanged = true
            }
            return .ready(pages: text, scans: images, scansChecked: capture != .none)
        case let .unreadable(reason):
            running.unreadable[path] = reason
            if reason == .failed, upload.textFile == nil {
                cache.setReadFailed(path: path, hash: upload.file.hash, reader: reader)
                running.cacheChanged = true
            }
            drop(upload)
            running.done += 1
            return .dropped
        case .later:
            // Changed since it was hashed, not on the device now or not loaded: the next run.
            drop(upload)
            running.done += 1
            return .dropped
        }
    }

    /// The upload the server took, and its pages' images; what the flush does next.
    func uploadDocument(_ upload: KnowledgeUpload, pages: [String], scans: [KnowledgeText.PageScan],
                        scansChecked: Bool, running: Flushing) async -> Sent {
        let path = upload.file.path
        do {
            let id = try await api.uploadKnowledgeDocument(KnowledgeUploadBody(
                folderId: running.folderID, file: upload.file, pages: pages,
                reader: KnowledgeText.reader(forPath: path), reread: upload.reread == true,
                scansChecked: scansChecked))
            guard isCurrent(running.generation) else { return .round }
            running.unreadable[path] = nil
            if let id, !scans.isEmpty { return await sendScans(scans, of: upload, documentID: id, running: running) }
            return sentUpload(upload, running: running)
        } catch {
            guard isCurrent(running.generation) else { return .round }
            if KnowledgeUploadQueue.disposition(of: error) == .retry {
                phase = .failed(error.localizedDescription)
                scheduleRetry()
                running.waits = true
                return .round
            }
            if Self.isFolderGone(error), await folderReplaced(running.folderID, generation: running.generation) {
                return .stop
            }
            KnowledgeFolder.log.error("Upload refused: \(error.localizedDescription, privacy: .public)")
            drop(upload)
            running.done += 1
            return .next
        }
    }

    /// The server took the document: one upload shorter in the queue, and the backoff starts again.
    func sentUpload(_ upload: KnowledgeUpload, running: Flushing) -> Sent {
        drop(upload)
        running.sent += 1
        running.done += 1
        retryDelay = 2
        return .next
    }

    /// The pages' images of the document just uploaded; the outage that stopped them waits with the
    /// upload in the queue, so the next round (or run) sends the pages that are left.
    func sendScans(_ scans: [KnowledgeText.PageScan], of upload: KnowledgeUpload, documentID: String,
                   running: Flushing) async -> Sent {
        let (outage, sentScans) = await send(scans, of: upload, documentID: documentID, generation: running.generation)
        guard isCurrent(running.generation) else { return .round }
        if let outage {
            // The text is in; the pages' images wait (those sent already aren't sent again).
            var kept = upload
            kept.sentScans = sentScans
            queue.add(kept)
            queueChanged()
            phase = .failed(outage.localizedDescription)
            scheduleRetry()
            running.waits = true
            return .round
        }
        return sentUpload(upload, running: running)
    }

    /// Sends the pages' images of the document `documentID` (just uploaded) for the family's AI,
    /// those not sent before; a refusal (an older server, the setting turned off meanwhile, a newer
    /// version of the file) ends it quietly. The outage that stopped it, if one did, and the pages
    /// sent so far.
    func send(_ scans: [KnowledgeText.PageScan], of upload: KnowledgeUpload, documentID: String,
              generation: Int) async -> (outage: (any Error)?, sent: [Int]) {
        var sent = Set(upload.sentScans ?? [])
        for scan in scans where !sent.contains(scan.page) {
            do {
                try await api.sendKnowledgePageScan(documentID: documentID, page: scan.page, hash: upload.file.hash,
                                                    jpeg: scan.jpeg, force: upload.force == true)
                sent.insert(scan.page)
            } catch {
                if KnowledgeUploadQueue.disposition(of: error) == .retry { return (error, sent.sorted()) }
                KnowledgeFolder.log.info("Page scan refused: \(error.localizedDescription, privacy: .public)")
                break
            }
            guard isCurrent(generation) else { break }
        }
        return (nil, sent.sorted())
    }

    /// Which pages' images to keep while reading `upload` (`KnowledgeText.ScanCapture`): none for
    /// a file read without OCR or a scan's own text; every page of a PDF or image while the family's
    /// *Read with the assistant* is on (`KnowledgeStatusInfo.sendsScans`), and for *Read Again with
    /// the Assistant* while the family's AI can read them at all.
    func scanCapture(for upload: KnowledgeUpload) async -> KnowledgeText.ScanCapture {
        guard upload.textFile == nil, KnowledgeText.reader(forPath: upload.file.path) > 1 else { return .none }
        let forced = upload.force == true
        guard let status = await scanStatus(fresh: forced) else { return .none }
        if forced { return status.scans == true ? .all : .none }
        return status.scans == true && status.aiScans == true ? .all : .none
    }

    /// Whether the server takes page images (GET /knowledge/status), asked at most every
    /// `scanStatusAge` (unless `fresh`); nil when it can't be asked.
    func scanStatus(fresh: Bool) async -> KnowledgeScanStatus? {
        if !fresh, let cached = scanStatusCache, Date().timeIntervalSince(cached.at) < Self.scanStatusAge {
            return cached.status
        }
        do {
            let status: KnowledgeScanStatus = try await api.get("/knowledge/status")
            scanStatusCache = (status, Date())
            return status
        } catch {
            return nil
        }
    }

    /// The family's setting changed (Settings → Knowledge): asked again before the next scan.
    func scanSettingChanged() {
        scanStatusCache = nil
    }

    enum UploadText {
        /// The text, and the pages' images the capture asked for.
        case pages([String], [KnowledgeText.PageScan])
        /// This device didn't read the file.
        case unreadable(Unreadable)
        /// Not now: it changed since it was hashed, isn't on the device and may not be loaded now,
        /// or couldn't be loaded.
        case later
    }

    /// The upload's pages: its queued text, else read from the file (loaded from iCloud when it
    /// isn't on the device and `downloads` allow; taken off again once read), with the pages'
    /// images `capture` asks for.
    func text(of upload: KnowledgeUpload, root: URL, downloads: KnowledgeDownloads,
              capture: KnowledgeText.ScanCapture) async -> UploadText {
        if let name = upload.textFile {
            let file = textsFolder.appending(path: name)
            let pages = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            }.value
            return pages.map { .pages($0, []) } ?? .unreadable(.failed)
        }
        let url = upload.diskPath.split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .notDirectory)
        }
        guard KnowledgeText.canRead(url) else { return .unreadable(.format) }
        let state = await Self.inspect(url)
        if !state.onDevice, !downloads.allowed { return .later }
        if let size = state.size, size != upload.file.size { return .later }
        if state.onDevice, let mtime = state.mtime, mtime != upload.file.mtime { return .later }
        let reading = await KnowledgeText.read(url, capture: capture)
        if upload.evict == true || !state.onDevice { await KnowledgeICloud.evict([url]) }
        return outcome(reading)
    }

    /// What a finished read gives the upload: its pages and the images `capture` kept, why this
    /// device can't read the file, or that the next run takes it.
    private func outcome(_ reading: KnowledgeText.Reading) -> UploadText {
        switch reading.outcome {
        case let .pages(pages): .pages(pages, reading.scans)
        case .unsupported: .unreadable(.format)
        case .failed: .unreadable(.failed)
        case .unavailable: .later
        }
    }

    /// Whether the file is on the device, and its size and date where the disk says.
    @concurrent
    static func inspect(_ url: URL) async -> (onDevice: Bool, size: Int64?, mtime: Int64?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (KnowledgeICloud.isOnDevice(url), values?.fileSize.map(Int64.init),
                values?.contentModificationDate.map { KnowledgeWalker.milliseconds($0) })
    }

    /// Takes `upload` out of the queue (itself: one queued for its path since with another hash
    /// stays), with its text.
    func drop(_ upload: KnowledgeUpload) {
        if let removed = queue.remove(upload), let name = removed.textFile { removeText(name) }
        queueChanged()
    }

    func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        retryWait?.cancel()
        retryWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            retryWait = nil
            await resume()
        }
    }
}

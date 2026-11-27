import Foundation

// The uploads of the indexer's queue (`KnowledgeIndexer`): what a flush sends and in which order,
// reading each file here, the text and its page images going to the server, and the backoff that
// waits for the connection.

extension KnowledgeIndexer {

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
        defer { if flushingGeneration == generation { flushingGeneration = nil } }
        var round = Round(folderID: folderID, generation: generation, unreadableNow: unreadable)
        await rounds(root: root, downloads: downloads(), round: &round)
        if round.gone { return round.sent }
        if queue.isEmpty, case .uploading = phase { phase = .idle }
        return round.sent
    }

    /// What one upload of a flush left: it is done (sent or dropped), the flush waits for the
    /// connection, or it stopped (the run ended, or the folder is no longer the server's).
    private enum Flushed {
        case done, waiting, stopped
    }

    /// What reading one upload of a flush brought: its pages, that it was dropped (the reason is
    /// kept in the round), or that the run ended.
    private enum ReadOne {
        case pages([String], [KnowledgeText.PageScan])
        case dropped
        case stopped
    }

    /// What one round of the flush keeps: the folder it sends to, how far it got, and what the
    /// cache and `unreadable` look like once the round is done.
    private struct Round {
        let folderID: String
        let generation: Int
        var sent = 0
        var done = 0
        var unreadableNow: [String: Unreadable]
        var cacheChanged = false
        /// Waits for the connection (a retry is scheduled).
        var waits = false
        /// The round stopped: the run ended, or the folder is no longer the server's.
        var stopped = false
        /// The family's folder isn't the server's anymore (`folderReplaced`).
        var gone = false
    }

    /// The rounds of a flush: the uploads the queue holds, then what the round leaves on the disk;
    /// again while uploads came in, until the queue is empty, the connection waits or it stops.
    private func rounds(root: URL, downloads: KnowledgeDownloads, round: inout Round) async {
        repeat {
            await flushUploads(root: root, downloads: downloads, round: &round)
            guard isCurrent(round.generation), !round.stopped else { return }
            unreadable = round.unreadableNow
            if round.cacheChanged { persistCache() }
            persistQueue()
            await diskIdle()
        } while !round.waits && isCurrent(round.generation) && !queue.isEmpty
    }

    /// One round's uploads, in order, until the queue is empty or one of them stops the round.
    private func flushUploads(root: URL, downloads: KnowledgeDownloads, round: inout Round) async {
        while isCurrent(round.generation), let upload = queue.first {
            phase = .uploading(done: round.done, of: round.done + queue.count)
            guard upload.folderId == round.folderID else {
                drop(upload)
                continue
            }
            let flushed = await flushOne(upload, root: root, downloads: downloads, in: &round)
            if flushed != .done {
                round.stopped = flushed == .stopped
                return
            }
        }
    }

    /// One upload of a flush: read, then sent.
    private func flushOne(_ upload: KnowledgeUpload, root: URL, downloads: KnowledgeDownloads,
                          in round: inout Round) async -> Flushed {
        let capture = await scanCapture(for: upload)
        guard isCurrent(round.generation) else { return .stopped }
        switch await readPages(of: upload, root: root, downloads: downloads, capture: capture, in: &round) {
        case let .pages(text, scans):
            return await sendText(upload, pages: text, scans: scans, capture: capture, in: &round)
        case .dropped:
            return .done
        case .stopped:
            return .stopped
        }
    }

    /// Reads one upload of a flush: its text and the pages' images; a file whose read failed before
    /// is marked and dropped, as is one that can't be read here or changed since it was hashed.
    private func readPages(of upload: KnowledgeUpload, root: URL, downloads: KnowledgeDownloads,
                           capture: KnowledgeText.ScanCapture, in round: inout Round) async -> ReadOne {
        let reader = KnowledgeText.reader(forPath: upload.file.path)
        if upload.textFile == nil, upload.reread != true,
           cache.readFailed(path: upload.file.path, hash: upload.file.hash, reader: reader) {
            round.unreadableNow[upload.file.path] = .failed
            drop(upload)
            round.done += 1
            return .dropped
        }
        guard isCurrent(round.generation) else { return .stopped }
        let read = await text(of: upload, root: root, downloads: downloads, capture: capture)
        guard isCurrent(round.generation) else { return .stopped }
        switch read {
        case let .pages(text, images):
            clearReadFailed(of: upload, reader: reader, in: &round)
            return .pages(text, images)
        case let .unreadable(reason):
            markUnreadable(reason, of: upload, reader: reader, in: &round)
            return .dropped
        case .later:
            // Changed since it was hashed, not on the device now or not loaded: the next run.
            drop(upload)
            round.done += 1
            return .dropped
        }
    }

    /// The file read again after a failed read: the cache's mark of it goes away.
    private func clearReadFailed(of upload: KnowledgeUpload, reader: Int, in round: inout Round) {
        guard upload.textFile == nil, cache.readFailed(path: upload.file.path, hash: upload.file.hash,
                                                       reader: reader) else { return }
        cache.setReadFailed(path: upload.file.path, hash: upload.file.hash, reader: reader, false)
        round.cacheChanged = true
    }

    /// A file this device couldn't read: said so to the run and dropped; one whose read failed is
    /// marked in the cache (not one that simply isn't there).
    private func markUnreadable(_ reason: Unreadable, of upload: KnowledgeUpload, reader: Int,
                                in round: inout Round) {
        round.unreadableNow[upload.file.path] = reason
        if reason == .failed, upload.textFile == nil {
            cache.setReadFailed(path: upload.file.path, hash: upload.file.hash, reader: reader)
            round.cacheChanged = true
        }
        drop(upload)
        round.done += 1
    }

    /// Sends one upload's text and its page images: it is in, refused (dropped), the flush waits
    /// for the connection, or the round stopped.
    private func sendText(_ upload: KnowledgeUpload, pages: [String], scans: [KnowledgeText.PageScan],
                          capture: KnowledgeText.ScanCapture, in round: inout Round) async -> Flushed {
        let reader = KnowledgeText.reader(forPath: upload.file.path)
        do {
            let id = try await api.uploadKnowledgeDocument(KnowledgeUploadBody(
                folderId: round.folderID, file: upload.file, pages: pages, reader: reader,
                reread: upload.reread == true, scansChecked: capture != .none))
            guard isCurrent(round.generation) else { return .stopped }
            round.unreadableNow[upload.file.path] = nil
            if let id, !scans.isEmpty,
               let outcome = await sendScans(scans, of: upload, documentID: id, in: &round) {
                return outcome
            }
            drop(upload)
            round.sent += 1
            round.done += 1
            retryDelay = 2
            return .done
        } catch {
            return await refused(upload, error: error, in: &round)
        }
    }

    /// An upload the server refused: dropped, or the flush waits for the connection; the round
    /// stops when the family's link was replaced (the folder isn't the server's anymore).
    private func refused(_ upload: KnowledgeUpload, error: any Error, in round: inout Round) async -> Flushed {
        guard isCurrent(round.generation) else { return .stopped }
        if KnowledgeUploadQueue.disposition(of: error) == .retry {
            phase = .failed(error.localizedDescription)
            scheduleRetry()
            round.waits = true
            return .waiting
        }
        if Self.isFolderGone(error), await folderReplaced(round.folderID, generation: round.generation) {
            round.gone = true
            return .stopped
        }
        KnowledgeFolder.log.error("Upload refused: \(error.localizedDescription, privacy: .public)")
        drop(upload)
        round.done += 1
        return .done
    }

    /// The pages' images of the document just uploaded; the upload goes back with what was sent
    /// when an outage stopped it, and the round waits for the connection. nil: every page is in.
    private func sendScans(_ scans: [KnowledgeText.PageScan], of upload: KnowledgeUpload, documentID: String,
                           in round: inout Round) async -> Flushed? {
        let (outage, sentScans) = await send(scans, of: upload, documentID: documentID, generation: round.generation)
        guard isCurrent(round.generation) else { return .stopped }
        guard let outage else { return nil }
        // The text is in; the pages' images wait (those sent already aren't sent again).
        var kept = upload
        kept.sentScans = sentScans
        queue.add(kept)
        queueChanged()
        phase = .failed(outage.localizedDescription)
        scheduleRetry()
        round.waits = true
        return .waiting
    }

    /// Sends the pages' images of the document `documentID` (just uploaded) for the family's AI,
    /// those not sent before; a refusal (an older server, the setting turned off meanwhile, a newer
    /// version of the file) ends it quietly. The outage that stopped it, if one did, and the pages
    /// sent so far.
    private func send(_ scans: [KnowledgeText.PageScan], of upload: KnowledgeUpload, documentID: String,
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
    private func scanCapture(for upload: KnowledgeUpload) async -> KnowledgeText.ScanCapture {
        guard upload.textFile == nil, KnowledgeText.reader(forPath: upload.file.path) > 1 else { return .none }
        let forced = upload.force == true
        guard let status = await scanStatus(fresh: forced) else { return .none }
        if forced { return status.scans == true ? .all : .none }
        return status.scans == true && status.aiScans == true ? .all : .none
    }

    /// Whether the server takes page images (GET /knowledge/status), asked at most every
    /// `scanStatusAge` (unless `fresh`); nil when it can't be asked.
    private func scanStatus(fresh: Bool) async -> KnowledgeScanStatus? {
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

    private enum UploadText {
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
    private func text(of upload: KnowledgeUpload, root: URL, downloads: KnowledgeDownloads,
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
        switch reading.outcome {
        case let .pages(pages): return .pages(pages, reading.scans)
        case .unsupported: return .unreadable(.format)
        case .failed: return .unreadable(.failed)
        case .unavailable: return .later
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
    private func drop(_ upload: KnowledgeUpload) {
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

// KnowledgeIndexerFolder.swift
// Ohana
//
// The indexer's own server folder, and what a scan or a file that couldn't be read asks for.
// The run itself lives in KnowledgeIndexerRunning.swift.

import Foundation

extension KnowledgeIndexer {
    // MARK: The server's folder

    static func isFolderGone(_ error: any Error) -> Bool {
        if case let APIError.http(status, _) = error { status == 404 } else { false }
    }

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
        guard let diskPath = Self.relativePath(of: file, in: root), let path = Self.indexPath(diskPath) else {
            throw KnowledgeFolderError.notInFolder
        }
        guard let hashed = await Self.hash(file) else { throw CocoaError(.fileReadUnknown) }
        let tags = KnowledgeTags.cleaned(FinderTags.read(file))
        let local = KnowledgeLocalFile(path: path, url: file, size: hashed.size, mtime: hashed.mtime, tags: tags)
        let name = "\(UUID().uuidString).json"
        let texts = textsFolder, limited = KnowledgeText.limited(pages), signOuts = signOuts, gate = gate
        let written = try await Task.detached(priority: .utility) {
            try Self.writeText(limited, name: name, in: texts, signOuts: signOuts, gate: gate, generation: generation)
        }.value
        guard written else { return }
        let info = KnowledgeFileInfo(path: path, size: hashed.size, mtime: hashed.mtime, hash: hashed.hash, tags: tags)
        let upload = KnowledgeUpload(folderId: folderID, file: info, diskPath: diskPath, textFile: name)
        await keepScan(local: local, hash: hashed.hash, upload: upload, name: name, generation: generation)
    }

    /// The index's form of a path inside the folder: composed the way the index keeps names, and
    /// only a name it takes (nil: not a file the index can hold).
    static func indexPath(_ diskPath: String) -> String? {
        let path = diskPath.precomposedStringWithCanonicalMapping
        return KnowledgeWalker.isValidPath(path) ? path : nil
    }

    /// A scan whose text is on the disk: its hash in the cache, its upload in the queue, and a run
    /// that isn't under way sends it now (a run that is lists it with its manifest first).
    private func keepScan(local: KnowledgeLocalFile, hash: String, upload: KnowledgeUpload, name: String,
                          generation: Int) async {
        await ensureCache()
        await ensureQueue()
        guard isCurrent(generation) else {
            removeText(name)
            return
        }
        cache.set(local, hash: hash)
        persistCache()
        scansDuringRun?[local.path] = Hashed(local: local, hash: hash, evict: false)
        if let old = queue.add(upload) { removeText(old) }
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

    // MARK: Reading a file again

    /// What *Read Again* came to.
    enum RereadOutcome: Equatable {
        /// Read and sent (the server reads it anew if its text changed).
        case sent
        /// Waits on the device for the connection.
        case waiting
        /// This device couldn't read it.
        case unreadable(Unreadable)
    }

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
        let found = RereadFile(url: url, hashed: hashed, diskPath: diskPath, onDevice: onDevice)
        guard let upload = await queueReread(found, folderID: folderID, assistant: assistant,
                                             generation: generation) else { return .waiting }
        return await waitedFor(upload, generation: generation)
    }

    /// What *Read Again* came to for one file on this device: where it is, how it hashed after it
    /// was loaded, its path as the disk spells it, and whether it was on the device before.
    private struct RereadFile {
        let url: URL
        let hashed: (hash: String, size: Int64, mtime: Int64)
        let diskPath: String
        let onDevice: Bool
    }

    /// The file in the queue with `reread`, its hash in the cache, what it replaces off the disk
    /// and nothing known against it; nil when the account signed out or the folder was chosen anew.
    private func queueReread(_ found: RereadFile, folderID: String, assistant: Bool,
                             generation: Int) async -> KnowledgeUpload? {
        let tags = KnowledgeTags.cleaned(FinderTags.read(found.url))
        await ensureCache()
        await ensureQueue()
        guard isCurrent(generation) else { return nil }
        let path = found.diskPath.precomposedStringWithCanonicalMapping
        let local = KnowledgeLocalFile(path: path, url: found.url, size: found.hashed.size,
                                       mtime: found.hashed.mtime, tags: tags)
        cache.set(local, hash: found.hashed.hash)
        persistCache()
        let info = KnowledgeFileInfo(path: path, size: found.hashed.size, mtime: found.hashed.mtime,
                                     hash: found.hashed.hash, tags: tags)
        let upload = KnowledgeUpload(folderId: folderID, file: info, diskPath: found.diskPath,
                                     evict: found.onDevice ? nil : true, reread: true,
                                     force: assistant ? true : nil)
        if let old = queue.add(upload) { removeText(old) }
        persistQueue()
        unreadable[path] = nil
        return upload
    }

    /// Waits for the *Read Again* upload to leave the queue: a flush under way (a run's) sends it,
    /// so it is simply waited for; with none under way, this flushes now. What the device learned
    /// of the file meanwhile says how it ended.
    private func waitedFor(_ upload: KnowledgeUpload, generation: Int) async -> RereadOutcome {
        if flushingGeneration == nil { await flush() }
        let path = upload.file.path
        func pending() -> Bool { queue.upload(for: path)?.isSame(as: upload) == true }
        var waited = 0
        while isCurrent(generation), pending(), retryWait == nil, flushingGeneration != nil, waited < 2400 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        if let reason = unreadable[path] { return .unreadable(reason) }
        return pending() ? .waiting : .sent
    }

    /// The file of `path` in `root` as the disk has it (off the main actor: iCloud may be slow).
    @concurrent
    static func locate(_ path: String, in root: URL) async -> URL? {
        KnowledgeOriginal.locate(path, in: root)
    }
}

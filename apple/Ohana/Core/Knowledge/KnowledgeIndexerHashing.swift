// KnowledgeIndexerHashing.swift
// Ohana
//
// The hashes of the listed files: from the cache, read on the disk, and the ones the server's
// index still holds. The run itself lives in KnowledgeIndexerRunning.swift.

import Foundation

extension KnowledgeIndexer {
    // MARK: Hashing

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
            hash.map {
                return KnowledgeFileInfo(path: local.path, size: local.size, mtime: local.mtime,
                                         hash: $0, tags: local.tags)
            }
        }
    }

    /// Every listed file with its hash (`KnowledgeHashStep.plan`): the cache's where it's
    /// unchanged, else read (`hashingWidth` at a time; a file iCloud keeps off the device is loaded
    /// while `downloads` allow). A file that couldn't be hashed is still listed, with its last hash
    /// at the same size, else with none: leaving it out would make it missing.
    func hashed(_ listed: [KnowledgeLocalFile], downloads: KnowledgeDownloads,
                generation: Int) async -> (files: [Hashed], unhashable: Int, deferred: Int) {
        let steps = KnowledgeHashStep.plan(listed, cache: cache, downloads: downloads)
        let running = Hashing(listed)
        takePlanned(steps, running)
        await hashRest(running, generation: generation)
        var files: [Hashed] = []
        for index in running.files.indices {
            files.append(Hashed(local: running.files[index], hash: running.hashes[index], evict: running.evict[index]))
        }
        return (files, running.unhashable, running.deferred)
    }

    /// What hashing the listed files keeps as it goes: the files as they now read, the hash each
    /// one has and whether to take it off the device again, what is still to read and what the
    /// plan wouldn't do. A class, so its parts can add to it as they go.
    private final class Hashing {
        var files: [KnowledgeLocalFile]
        var hashes: [String?]
        var evict: [Bool]
        /// The files the plan wants read (or loaded first).
        var todo: [Int] = []
        var unhashable = 0
        var deferred = 0

        init(_ listed: [KnowledgeLocalFile]) {
            files = listed
            hashes = [String?](repeating: nil, count: listed.count)
            evict = [Bool](repeating: false, count: listed.count)
        }
    }

    /// The steps the plan made, put into what's being hashed: the cached hashes taken, what must be
    /// read put in `todo`, and the files that wait for a download counted.
    private func takePlanned(_ steps: [KnowledgeHashStep], _ running: Hashing) {
        for (index, step) in steps.enumerated() {
            switch step {
            case let .cached(entry):
                running.hashes[index] = entry.hash
                if !running.files[index].downloaded {
                    running.files[index].mtime = entry.mtime
                    running.files[index].tags = entry.tags
                }
            case .hash:
                running.todo.append(index)
            case .download:
                running.todo.append(index)
                running.evict[index] = true
            case .later:
                running.deferred += 1
                fallBack(index, running)
            }
        }
    }

    /// The files the plan wants read: hashed `hashingWidth` at a time, each one kept as it comes
    /// back, another started. Stopped: what's under way ends, nothing more starts or is kept.
    private func hashRest(_ running: Hashing, generation: Int) async {
        guard !running.todo.isEmpty else { return }
        phase = .hashing(done: 0, of: running.todo.count)
        var done = 0
        await withTaskGroup(of: (Int, (hash: String, size: Int64, mtime: Int64)?).self) { group in
            var next = running.todo.makeIterator()
            func start() {
                guard let index = next.next() else { return }
                let url = running.files[index].url
                group.addTask { (index, await Self.hash(url)) }
            }
            for _ in 0..<Self.hashingWidth { start() }
            for await (index, result) in group {
                // Stopped: what's under way ends, nothing more starts or is kept.
                guard isCurrent(generation) else { continue }
                done += 1
                phase = .hashing(done: done, of: running.todo.count)
                keepHashed(index, result, running)
                start()
            }
        }
    }

    /// One file that came back from hashing: its own size, date and tags now that it's loaded, and
    /// its hash in the cache; what couldn't be hashed falls back and is counted.
    private func keepHashed(_ index: Int, _ result: (hash: String, size: Int64, mtime: Int64)?,
                            _ running: Hashing) {
        guard let result else {
            running.unhashable += 1
            fallBack(index, running)
            return
        }
        if !running.files[index].downloaded {
            // Loaded now: its own size, date and tags.
            running.files[index].size = result.size
            running.files[index].mtime = result.mtime
            running.files[index].downloaded = true
            let tags = KnowledgeTags.cleaned(FinderTags.read(running.files[index].url))
            if !tags.isEmpty { running.files[index].tags = tags }
        }
        running.hashes[index] = result.hash
        cache.set(running.files[index], hash: result.hash)
    }

    /// Not hashed this time: the last hash and what's known of it.
    private func fallBack(_ index: Int, _ running: Hashing) {
        let path = running.files[index].path
        running.hashes[index] = cache.lastHash(path: path, size: running.files[index].size)
        if !running.files[index].downloaded {
            // A placeholder's date isn't the file's.
            running.files[index].mtime = cache.entries[path]?.mtime ?? 0
            running.files[index].tags = cache.tags(for: path)
        }
    }

    @concurrent
    static func hash(_ url: URL) async -> (hash: String, size: Int64, mtime: Int64)? {
        do {
            return try KnowledgeHasher.sha256(url)
        } catch {
            let name = url.lastPathComponent
            let reason = error.localizedDescription
            KnowledgeFolder.log.error("Can't hash \(name, privacy: .private): \(reason, privacy: .public)")
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
}

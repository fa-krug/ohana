import Foundation

/// A file whose text waits to go to the server (PUT /knowledge/documents).
nonisolated struct KnowledgeUpload: Codable, Equatable, Sendable {
    /// The server's folder it was asked for: a folder chosen since makes it void.
    var folderId: String
    /// What the upload says of the file (its path NFC, the server's form).
    var file: KnowledgeFileInfo
    /// The path as it is on the disk (the name's form may differ from NFC), relative to the folder.
    var diskPath: String
    /// The text read already (a scan's), kept in a file of its own next to the queue; nil: read
    /// from the file when it's sent.
    var textFile: String?
    /// iCloud loaded the file for this run (it wasn't on the device): taken off again once read.
    var evict: Bool?
    /// The user asked for it to be read again (*Read Again*): sent with `reread`, read even if
    /// reading it failed before.
    var reread: Bool?
    /// *Read Again with the Assistant*: every page's image goes to the family's AI (`force`).
    var force: Bool?
    /// The pages whose image the server took already (an outage stopped the rest).
    var sentScans: [Int]?

    init(folderId: String, file: KnowledgeFileInfo, diskPath: String, textFile: String? = nil, evict: Bool? = nil,
         reread: Bool? = nil, force: Bool? = nil) {
        self.folderId = folderId
        self.file = file
        self.diskPath = diskPath
        self.textFile = textFile
        self.evict = evict
        self.reread = reread
        self.force = force
    }

    /// Which upload it is: a newer one for the same path with another hash is another, and so is
    /// one the user asked for (*Read Again*) after it.
    func isSame(as other: KnowledgeUpload) -> Bool {
        file.path == other.file.path && file.hash == other.file.hash
            && (reread ?? false) == (other.reread ?? false) && (force ?? false) == (other.force ?? false)
    }
}

/// The uploads waiting, in order, kept on the device (`queue.json` in the family's
/// `KnowledgeLocation` directory) until the server took them: like the chores' queue, a refusal
/// drops the upload, no connection keeps it for later. One per path, found by its path (no
/// search through the queue): the order is a list of (sequence, path) whose stale entries are
/// skipped and compacted now and then.
nonisolated struct KnowledgeUploadQueue: Codable, Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var seq: Int
        var upload: KnowledgeUpload
    }

    private var byPath: [String: Entry] = [:]
    private var order: [(seq: Int, path: String)] = []
    private var head = 0
    private var nextSeq = 0

    init() {}

    init(_ uploads: [KnowledgeUpload]) {
        for upload in uploads { add(upload) }
    }

    var count: Int { byPath.count }
    var isEmpty: Bool { byPath.isEmpty }

    /// The uploads in order (O(n): for saving and tests).
    var items: [KnowledgeUpload] {
        order[head...].compactMap { item in
            byPath[item.path].flatMap { $0.seq == item.seq ? $0.upload : nil }
        }
    }

    /// The upload waiting for `path`.
    func upload(for path: String) -> KnowledgeUpload? {
        byPath[path]?.upload
    }

    /// The upload to send next.
    var first: KnowledgeUpload? {
        mutating get {
            while head < order.count {
                let item = order[head]
                if let entry = byPath[item.path], entry.seq == item.seq { return entry.upload }
                head += 1
            }
            compact()
            return nil
        }
    }

    /// Adds `upload` at the end; one waiting for the same path is replaced (its text file is
    /// returned, to be removed).
    @discardableResult
    mutating func add(_ upload: KnowledgeUpload) -> String? {
        let replaced = byPath[upload.file.path]?.upload.textFile
        byPath[upload.file.path] = Entry(seq: nextSeq, upload: upload)
        order.append((nextSeq, upload.file.path))
        nextSeq += 1
        compactIfSparse()
        return replaced == upload.textFile ? nil : replaced
    }

    /// Removes `upload` (by path and hash: one added for the path since, with another hash,
    /// stays). Returns what was removed (its text file may be another's than `upload`'s), nil when
    /// it wasn't there.
    @discardableResult
    mutating func remove(_ upload: KnowledgeUpload) -> KnowledgeUpload? {
        guard let entry = byPath[upload.file.path], entry.upload.isSame(as: upload) else { return nil }
        byPath[upload.file.path] = nil
        compactIfSparse()
        return entry.upload
    }

    /// Removes every upload `where` holds for; their text files.
    @discardableResult
    mutating func removeAll(where drop: (KnowledgeUpload) -> Bool) -> [String] {
        var texts: [String] = []
        for (path, entry) in byPath where drop(entry.upload) {
            byPath[path] = nil
            if let text = entry.upload.textFile { texts.append(text) }
        }
        compact()
        return texts
    }

    private mutating func compactIfSparse() {
        if order.count > 64, order.count > 2 * byPath.count { compact() }
    }

    private mutating func compact() {
        order = order[head...].filter { byPath[$0.path]?.seq == $0.seq }
        head = 0
        if byPath.isEmpty { order = [] }
    }

    static func == (a: Self, b: Self) -> Bool { a.items == b.items }

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode([KnowledgeUpload].self, forKey: .items))
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
    }

    static func load(_ file: URL) -> KnowledgeUploadQueue {
        guard let data = try? Data(contentsOf: file),
              let queue = try? JSONDecoder().decode(KnowledgeUploadQueue.self, from: data) else { return KnowledgeUploadQueue() }
        return queue
    }

    /// Kept while it holds uploads; the file goes when it's empty.
    func save(to file: URL) throws {
        if isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// What a failed upload means.
    enum Disposition: Equatable {
        /// The server won't take it as it is (a 4xx, 413 too big): dropped. The next manifest asks
        /// again for a file the server still lacks.
        case drop
        /// No connection, the server down or busy (408, 429, 5xx): kept, tried again later.
        case retry
    }

    /// Temporary failures (`APIError.isTemporary`) and a 401 (the account signs out, and its
    /// queues go with it) wait; anything else drops: a 4xx, a file that can't be read, an answer
    /// that can't be read (it came with a 2xx: the server has the text).
    @MainActor
    static func disposition(of error: any Error) -> Disposition {
        if APIError.isTemporary(error) { return .retry }
        if case APIError.unauthorized = error { return .retry }
        return .drop
    }
}

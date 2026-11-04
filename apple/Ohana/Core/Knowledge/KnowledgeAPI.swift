import Foundation

// The knowledge base's routes the app's indexer uses (server/lib/knowledge/routes.ts; editors
// only, a viewer gets 404): the family's folder, the manifest of what this device sees in it and
// the text of the files the server asks for. Paths are relative to the folder, NFC, "/"-separated.

/// What the server takes (server/lib/knowledge/input.ts, manifest.ts, documents.ts): above it a
/// request is refused (400, 413), so the app keeps below.
nonisolated enum KnowledgeLimits {
    static let maxFiles = 20_000
    static let maxPages = 2000
    /// The text of an upload, in UTF-8 bytes.
    static let maxTextBytes = 2_000_000
    static let maxPathLength = 1024
    static let maxTags = 50
    static let maxTagLength = 100
    static let maxDeviceLength = 100
    /// Files larger than this aren't read (a video, a disk image): no paperwork.
    static let maxFileSize: Int64 = 100_000_000
}

/// The family's knowledge folder on the server (GET/POST /knowledge/folder).
nonisolated struct KnowledgeFolderInfo: Codable, Equatable, Sendable {
    var id: String
    var createdAt: String
    /// The last manifest any device sent, and the name of that device; nil before one.
    var lastManifestAt: String?
    var lastManifestDevice: String?
}

nonisolated struct KnowledgeFolderResponse: Codable, Sendable {
    var folder: KnowledgeFolderInfo?
}

/// GET /knowledge/status: the folder, the family's documents by status and the number of chunks
/// (Settings → Knowledge). Without a folder every count is 0.
nonisolated struct KnowledgeStatusInfo: Codable, Equatable, Sendable {
    nonisolated struct Counts: Codable, Equatable, Sendable {
        var pending = 0
        var ready = 0
        var failed = 0
        var missing = 0
        var excluded = 0
    }

    var folder: KnowledgeFolderInfo?
    var counts: Counts
    var chunks: Int
}

/// One file of a manifest, and what an upload says of its file.
nonisolated struct KnowledgeFileInfo: Codable, Equatable, Sendable {
    var path: String
    var size: Int64
    /// Its modification date, in ms since 1970.
    var mtime: Int64
    /// SHA-256, lowercase hex.
    var hash: String
    var tags: [String]
}

/// One file of a manifest. `hash` nil (sent as JSON null): the file is there, but this run couldn't
/// hash it (iCloud didn't load it, or it waits for a better connection) and there's no hash of it
/// on the device: the server keeps its document as it is and doesn't ask for it.
nonisolated struct KnowledgeManifestFile: Encodable, Equatable, Sendable {
    var path: String
    var size: Int64
    var mtime: Int64
    var hash: String?
    var tags: [String]

    private enum CodingKeys: String, CodingKey { case path, size, mtime, hash, tags }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(size, forKey: .size)
        try c.encode(mtime, forKey: .mtime)
        // Explicitly null, not left out.
        try c.encode(hash, forKey: .hash)
        try c.encode(tags, forKey: .tags)
    }
}

/// POST /knowledge/manifest: every file this device sees in the folder.
nonisolated struct KnowledgeManifestBody: Encodable, Sendable {
    var folderId: String
    var files: [KnowledgeManifestFile]
    /// The device's name, shown with the folder's last manifest.
    var device: String?
}

nonisolated struct KnowledgeManifestAnswer: Decodable, Sendable {
    /// The paths whose text the server wants.
    var upload: [String]
}

/// PUT /knowledge/documents: a file's text, page by page.
nonisolated struct KnowledgeUploadBody: Encodable, Sendable {
    var folderId: String
    var file: KnowledgeFileInfo
    var pages: [String]

    private enum CodingKeys: String, CodingKey {
        case folderId, path, hash, size, mtime, tags, pages
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderId, forKey: .folderId)
        try c.encode(file.path, forKey: .path)
        try c.encode(file.hash, forKey: .hash)
        try c.encode(file.size, forKey: .size)
        try c.encode(file.mtime, forKey: .mtime)
        try c.encode(file.tags, forKey: .tags)
        try c.encode(pages, forKey: .pages)
    }
}

extension FamilyAPI {
    /// The family's folder; nil before a device chose one.
    func knowledgeFolder() async throws -> KnowledgeFolderInfo? {
        let response: KnowledgeFolderResponse = try await get("/knowledge/folder")
        return response.folder
    }

    /// The family's folder, made by this call when there's none yet.
    func createKnowledgeFolder() async throws -> KnowledgeFolderInfo {
        let response: KnowledgeFolderResponse = try await send(.post, "/knowledge/folder", body: [String: String]())
        guard let folder = response.folder else { throw APIError.decoding("folder") }
        return folder
    }

    /// Replaces the family's folder (deleting its documents) by a new one, with a new id: another
    /// folder was chosen anyway (`KnowledgeLinkDecision.replace`).
    func replaceKnowledgeFolder() async throws -> KnowledgeFolderInfo {
        let response: KnowledgeFolderResponse = try await send(.post, "/knowledge/folder", body: ["replace": true])
        guard let folder = response.folder else { throw APIError.decoding("folder") }
        return folder
    }

    /// The folder and what's in the index, kept on the device (Settings → Knowledge).
    func knowledgeStatus() -> CachedGet<KnowledgeStatusInfo> {
        cached("/knowledge/status")
    }

    /// Sends the manifest; the paths the server wants the text of.
    func sendKnowledgeManifest(_ body: KnowledgeManifestBody) async throws -> [String] {
        let answer: KnowledgeManifestAnswer = try await send(.post, "/knowledge/manifest", body: body)
        return answer.upload
    }

    /// Uploads a file's text (202: the server's worker indexes it).
    func uploadKnowledgeDocument(_ body: KnowledgeUploadBody) async throws {
        try await perform(.put, "/knowledge/documents", body: body)
    }
}

/// The device's name as the manifest sends it and the server keeps it: NFC, trimmed, at most
/// `maxDeviceLength` UTF-16 units (cut at a character); nil when blank.
nonisolated enum KnowledgeDevice {
    static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        var result = name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.utf16.count > KnowledgeLimits.maxDeviceLength {
            var cut = ""
            var length = 0
            for character in result {
                let units = character.utf16.count
                guard length + units <= KnowledgeLimits.maxDeviceLength else { break }
                cut.append(character)
                length += units
            }
            result = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }

    /// Whether the server's `device` names this device (`own`), both compared normalized.
    static func isThisDevice(_ device: String?, own: String) -> Bool {
        guard let device = normalized(device) else { return false }
        return device == normalized(own)
    }
}

extension ServerInfo {
    /// The server has the knowledge base on (a server from before it doesn't list it).
    var hasKnowledge: Bool { modules.contains("knowledge") }
}

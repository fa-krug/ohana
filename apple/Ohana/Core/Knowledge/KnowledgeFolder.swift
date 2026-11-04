import CryptoKit
import Foundation
import os

// The family's knowledge folder on this device: an iCloud Drive folder (shared between the
// parents' Apple IDs) the user picks once per device, kept as a bookmark per server and family.
// A marker file in it (`.ohana-knowledge.json`: server, family, the server's folder id) lets a
// second device recognise the folder as the family's, not a new one.

/// Where this device keeps what belongs to one family's knowledge folder: the bookmark (in
/// `UserDefaults`) and, in Application Support `Ohana/Knowledge/<server>/<family>/`, the hash
/// cache, the upload queue and the queued texts. Everything of a server goes on sign out and on a
/// new pairing (`KnowledgeFolder.removeAll`).
nonisolated struct KnowledgeLocation: Hashable, Sendable {
    /// The server as the marker names it (`KnowledgeMarker.serverID`).
    let server: String
    let familyID: String

    init(server: URL, familyID: String) {
        self.server = KnowledgeMarker.serverID(server)
        self.familyID = familyID
    }

    /// A short hash of the server: a folder name that is safe whatever the address holds.
    static func serverKey(_ server: String) -> String {
        SHA256.hash(data: Data(server.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    var serverKey: String { Self.serverKey(server) }

    /// `Ohana/Knowledge` in Application Support.
    static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Ohana/Knowledge", directoryHint: .isDirectory)
    }

    /// This family's folder under `base` (the tests pass their own).
    func directory(base: URL = Self.base) -> URL {
        base.appending(path: serverKey, directoryHint: .isDirectory)
            .appending(path: KnowledgeLocation.safe(familyID), directoryHint: .isDirectory)
    }

    static let defaultsPrefix = "knowledgeFolder."

    var defaultsKey: String { "\(Self.defaultsPrefix)\(serverKey).\(familyID)" }

    /// A file name of letters, digits, dots, dashes and underscores.
    static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
    }
}

/// The marker file in the folder: which server's which family it belongs to, and the server's id
/// of the folder.
nonisolated struct KnowledgeMarker: Codable, Equatable, Sendable {
    static let fileName = ".ohana-knowledge.json"

    var server: String
    var familyId: String
    var folderId: String

    /// The server as markers name it: scheme, host (lowercased) and port, and a path the server
    /// may be under, without a "/" at the end; two devices connected with the same address agree.
    static func serverID(_ url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        let host = (url.host() ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        var path = url.path(percentEncoded: false)
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// Whether the marker is this server's and family's.
    func belongs(to location: KnowledgeLocation) -> Bool {
        server == location.server && familyId == location.familyID
    }

    /// The marker in `folder`, read coordinated (iCloud loads it first); nil when there is none or
    /// it can't be read as one.
    static func read(in folder: URL) -> KnowledgeMarker? {
        let file = folder.appending(path: fileName, directoryHint: .notDirectory)
        var data: Data?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordination) { url in
            data = try? Data(contentsOf: url)
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(KnowledgeMarker.self, from: data)
    }

    /// Writes the marker into `folder` (coordinated: the folder is a file provider's).
    func write(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let file = folder.appending(path: Self.fileName, directoryHint: .notDirectory)
        var coordination: NSError?
        var failure: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordination) { url in
            do { try data.write(to: url, options: .atomic) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
    }
}

/// What choosing a folder does, from its marker and the family's folder on the server.
nonisolated enum KnowledgeLinkDecision: Equatable, Sendable {
    /// The marker is this family's and names the server's folder: just remember it.
    case use(folderID: String)
    /// POST /knowledge/folder (the family's, made when there's none) and write its id into the
    /// marker.
    case create
    /// POST /knowledge/folder `{replace: true}`: the family's folder (and its documents) goes, a new
    /// one is made and its id written into the marker. The devices that read the old one find out
    /// at their next manifest (404) and stop (`KnowledgeFolder.State.replaced`).
    case replace
    /// Asks the user first (`KnowledgeFolderError`); choosing again with that error `accepted`
    /// goes on.
    case conflict(KnowledgeFolderError)

    /// - `marker`: the folder's marker, nil without one.
    /// - `serverFolder`: the family's folder on the server, nil before a device chose one.
    /// - `accepted`: the conflict the user said yes to (*Use This Folder*).
    static func decide(marker: KnowledgeMarker?, location: KnowledgeLocation, serverFolder: KnowledgeFolderInfo?,
                       accepted: KnowledgeFolderError? = nil) -> KnowledgeLinkDecision {
        var marker = marker
        if let other = marker, !other.belongs(to: location) {
            guard accepted == .otherFamily else { return .conflict(.otherFamily) }
            // Used for this family anyway: as a folder without a marker.
            marker = nil
        }
        guard let marker else {
            // A folder the family already reads on another device: this one replaces it.
            if let serverFolder, serverFolder.lastManifestAt != nil {
                if case .serverHasFolder = accepted { return .replace }
                return .conflict(.serverHasFolder(device: serverFolder.lastManifestDevice))
            }
            return .create
        }
        // The server lost its index (a new server under the same address): it's made again.
        guard let serverFolder else { return .create }
        if serverFolder.id == marker.folderId { return .use(folderID: marker.folderId) }
        return accepted == .otherFolder ? .replace : .conflict(.otherFolder)
    }
}

nonisolated enum KnowledgeFolderError: LocalizedError, Equatable, Sendable {
    /// The marker names another family or server.
    case otherFamily
    /// The marker names this family, but the server's folder is another.
    case otherFolder
    /// The folder has no marker, but the family already has a folder that a device reads.
    case serverHasFolder(device: String?)
    /// The folder can't be opened.
    case unreadable
    /// The linked folder can't be found any more.
    case missing
    /// The file isn't in the knowledge folder.
    case notInFolder

    var errorDescription: String? {
        switch self {
        case .otherFamily:
            String(localized: "This folder belongs to another family. Use it for this family instead?")
        case .otherFolder:
            String(localized: "This folder was this family’s knowledge folder once, but the family has another one now. Use this folder instead?")
        case let .serverHasFolder(device?):
            String(localized: "This family already has a knowledge folder, read by “\(device)”. Use this folder instead?")
        case .serverHasFolder(nil):
            String(localized: "This family already has a knowledge folder. Use this folder instead?")
        case .unreadable:
            String(localized: "Ohana can’t open this folder.")
        case .missing:
            String(localized: "The knowledge folder can’t be found any more. Choose it again.")
        case .notInFolder:
            String(localized: "The file isn’t in the knowledge folder.")
        }
    }
}

/// The family's knowledge folder on this device: the folder the user chose (a security-scoped
/// bookmark) and the server's id of it. Choosing reads or writes the folder's marker.
nonisolated struct KnowledgeFolder: @unchecked Sendable {
    static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "knowledge")

    let location: KnowledgeLocation
    var defaults: UserDefaults = .standard

    /// The folder as this device knows it.
    enum State: Equatable, Sendable {
        /// None chosen on this device.
        case none
        /// Chosen, but it can't be found or reached any more (deleted, iCloud signed out).
        case missing
        /// Another device chose a different folder for the family since (the server's folder is
        /// another one now): not read any more until a folder is chosen again.
        case replaced
        case linked(url: URL, folderID: String)

        var url: URL? {
            if case let .linked(url, _) = self { url } else { nil }
        }

        var folderID: String? {
            if case let .linked(_, id) = self { id } else { nil }
        }
    }

    /// What's kept: the bookmark, the folder's id, and whether the server replaced that folder.
    private struct Saved: Codable {
        var bookmark: Data
        var folderId: String
        var replaced: Bool?
    }

    private var saved: Saved? {
        get { defaults.data(forKey: location.defaultsKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: location.defaultsKey)
            } else {
                defaults.removeObject(forKey: location.defaultsKey)
            }
        }
    }

    /// A folder is chosen on this device (found or not).
    var isLinked: Bool { saved != nil }

    /// The chosen folder (a stale bookmark is renewed).
    func state() -> State {
        guard let saved else { return .none }
        if saved.replaced == true { return .replaced }
        guard let resolved = FolderBookmark.resolve(saved.bookmark) else { return .missing }
        if let renewed = resolved.renewed { self.saved = Saved(bookmark: renewed, folderId: saved.folderId) }
        return .linked(url: resolved.url, folderID: saved.folderId)
    }

    /// Makes `url` (from the folder picker) the family's knowledge folder on this device: by its
    /// marker the server's folder, or a new one (the marker written). A marker of another family,
    /// or a folder other than the family's, throws `KnowledgeFolderError` unless that error is
    /// `accepted` (then the marker is replaced, and the server's folder too where it has another).
    /// Returns the folder's id.
    @MainActor
    @discardableResult
    func link(_ url: URL, api: FamilyAPI, accepted: KnowledgeFolderError? = nil) async throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ScanFiler.isFolder(url) else { throw KnowledgeFolderError.unreadable }
        let marker = await Task.detached(priority: .userInitiated) { KnowledgeMarker.read(in: url) }.value
        let serverFolder = try await api.knowledgeFolder()
        let folderID: String
        let decision = KnowledgeLinkDecision.decide(marker: marker, location: location, serverFolder: serverFolder,
                                                    accepted: accepted)
        switch decision {
        case let .use(id):
            folderID = id
        case .create, .replace:
            let folder = try await decision == .replace ? api.replaceKnowledgeFolder() : api.createKnowledgeFolder()
            let marker = KnowledgeMarker(server: location.server, familyId: location.familyID, folderId: folder.id)
            try await Task.detached(priority: .userInitiated) { try marker.write(in: url) }.value
            folderID = folder.id
        case let .conflict(error):
            throw error
        }
        try remember(url, folderID: folderID)
        return folderID
    }

    /// Remembers `url` as the server's folder `folderID` (what `link` does once it's decided).
    func remember(_ url: URL, folderID: String) throws {
        saved = Saved(bookmark: try FolderBookmark.make(url), folderId: folderID)
    }

    /// The server's folder isn't this one any more (another device chose another folder): the
    /// link stays, as `.replaced`, until a folder is chosen again or it's removed.
    func markReplaced() {
        guard var current = saved else { return }
        current.replaced = true
        saved = current
    }

    /// Forgets the folder on this device (the server keeps its index; the folder keeps its marker).
    func unlink() {
        saved = nil
    }

    /// Signing out or pairing anew: every family's folder of `server` is forgotten, with the hash
    /// caches and the upload queues.
    static func removeAll(server: URL, defaults: UserDefaults = .standard, base: URL = KnowledgeLocation.base) {
        let key = KnowledgeLocation.serverKey(KnowledgeMarker.serverID(server))
        let prefix = "\(KnowledgeLocation.defaultsPrefix)\(key)."
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            defaults.removeObject(forKey: name)
        }
        try? FileManager.default.removeItem(at: base.appending(path: key, directoryHint: .isDirectory))
    }
}

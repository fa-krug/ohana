import CryptoKit
import Foundation

/// The last answers of the GETs the screens show, kept on the device per server: a cold start
/// shows them at once, and they stay readable without a connection (`CachedGet`,
/// `LoadState.saved`). Raw response bodies under Caches, `Ohana/Responses/<server>/<key>.json`:
/// the system may purge them when space runs low, the server keeps the real state. Not for the
/// demo; signing out and a new pairing remove the server's copies (`clear`).
nonisolated final class ResponseCache: Sendable {
    let directory: URL

    /// Writes go out one after the other, off the main thread; `clear` waits for them.
    private static let writes = DispatchQueue(label: "ohana.response-cache", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    /// The copies of a server.
    convenience init(server: URL) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: base.appending(path: "Ohana/Responses/\(Self.folder(for: server))",
                                            directoryHint: .isDirectory))
    }

    /// A server's folder: its host, port and path in letters, digits, dots and dashes.
    static func folder(for server: URL) -> String {
        let name = (server.host() ?? "server") + (server.port.map { "-\($0)" } ?? "") + server.path()
        return String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" })
    }

    /// The body kept for `key`, and when it came.
    func read(_ key: String) -> (data: Data, date: Date)? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (data, date ?? .distantPast)
    }

    func write(_ data: Data, for key: String) {
        let (url, directory) = (file(key), directory)
        Self.writes.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                // Only a convenience: the next answer is kept again.
            }
        }
    }

    /// Removes every copy of the server, once the writes under way are done.
    func clear() {
        let directory = directory
        Self.writes.sync { try? FileManager.default.removeItem(at: directory) }
    }

    /// For tests: returns once the writes under way are done.
    static func waitForWrites() {
        writes.sync {}
    }

    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(hash).json")
    }
}

/// A value kept on the device and when it came from the server.
struct Saved<Value> {
    let value: Value
    let date: Date
}

/// A GET whose last answer is kept on the device (`ResponseCache`): `saved()` is that copy (nil
/// without one, and always in the demo), `fetch()` asks the server and keeps its answer. Screens
/// load with `LoadState.run($state, family.api.cached("/meals/plan"))`; stores use both
/// themselves.
struct CachedGet<Value: Decodable> {
    let client: APIClient
    let path: String
    var query: [String: String?] = [:]
    /// What the copy is filed under: the URL, unless a part of the query changes more often than
    /// the answer is worth keeping apart (the overview's `today`).
    let key: String

    func saved() -> Saved<Value>? {
        guard let (data, date) = client.cache?.read(key),
              let value = try? APIClient.decoder.decode(Value.self, from: data) else { return nil }
        return Saved(value: value, date: date)
    }

    func fetch() async throws -> Value {
        let (data, _) = try await client.data(for: client.request(.get, path, query: query))
        let value = try client.decode(Value.self, from: data)
        client.cache?.write(data, for: key)
        return value
    }
}

extension CachedGet {
    /// The server's answer, or the copy on the device while it can't be reached (offline, the
    /// server down). For what a screen loads on the side (tags, the recipe catalog).
    func fetchOrSaved() async throws -> Value {
        do {
            return try await fetch()
        } catch {
            return try savedIfTemporary(error)
        }
    }

    /// The copy on the device after `error`, if the failure may pass; else `error` again.
    func savedIfTemporary(_ error: any Error) throws -> Value {
        guard !(error is CancellationError), APIError.isTemporary(error), let copy = saved() else { throw error }
        return copy.value
    }
}

extension APIClient {
    /// A GET of `path` whose answer is kept on the device; `key` files it under something else
    /// than its URL.
    func cached<T: Decodable>(_ path: String, query: [String: String?] = [:], key: String? = nil,
                              as type: T.Type = T.self) -> CachedGet<T> {
        CachedGet(client: self, path: path, query: query, key: key ?? url(path, query: query).absoluteString)
    }
}

extension FamilyAPI {
    /// A GET of a family route whose answer is kept on the device; `key` (a family route too, e.g.
    /// "/overview") files it under something else than its URL.
    func cached<T: Decodable>(_ sub: String, query: [String: String?] = [:], key: String? = nil,
                              as type: T.Type = T.self) -> CachedGet<T> {
        client.cached(path(sub), query: query, key: key.map { client.url(path($0)).absoluteString })
    }
}

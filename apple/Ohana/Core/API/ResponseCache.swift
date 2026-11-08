import CryptoKit
import Foundation
import Synchronization

/// The last answers of the GETs the screens show, kept on the device per server: a cold start
/// shows them at once, and they stay readable without a connection (`CachedGet`,
/// `LoadState.saved`). Raw response bodies under Caches, `Ohana/Responses/<server>/<key>.json`:
/// the system may purge them when space runs low, the server keeps the real state. Not for the
/// demo; signing out and a new pairing remove the server's copies (`clear`).
///
/// The answers decoded last are also kept in memory for the launch (`remember` / `recall`, a few
/// dozen): a page built again (on iPhone each page opened after another) shows its copy at once,
/// without reading and decoding the file.
nonisolated final class ResponseCache: Sendable {
    let directory: URL

    private struct Remembered: Sendable {
        let value: any Sendable
        let date: Date
        var used: Int
    }

    private static let remembers = 48
    private let memory = Mutex<(entries: [String: Remembered], clock: Int)>(([:], 0))

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
        // The value in memory is older now (it's remembered again where it's decoded).
        forget(key)
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

    /// The value decoded for `key` last, if it's a `T`.
    func recall<T: Sendable>(_ type: T.Type, _ key: String) -> Saved<T>? {
        memory.withLock { memory in
            guard let entry = memory.entries[key], let value = entry.value as? T else { return nil }
            memory.clock += 1
            memory.entries[key]?.used = memory.clock
            return Saved(value: value, date: entry.date)
        }
    }

    /// Keeps `value`, decoded for `key`, in memory; the least recently used goes when there are
    /// too many.
    func remember(_ value: some Sendable, date: Date, for key: String) {
        memory.withLock { memory in
            memory.clock += 1
            memory.entries[key] = Remembered(value: value, date: date, used: memory.clock)
            if memory.entries.count > Self.remembers,
               let oldest = memory.entries.min(by: { $0.value.used < $1.value.used })?.key {
                memory.entries[oldest] = nil
            }
        }
    }

    func forget(_ key: String) {
        _ = memory.withLock { $0.entries.removeValue(forKey: key) }
    }

    /// Removes every copy of the server, once the writes under way are done.
    func clear() {
        memory.withLock { $0.entries = [:] }
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
nonisolated struct Saved<Value> {
    let value: Value
    let date: Date
}

extension Saved: Sendable where Value: Sendable {}

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

    /// Asks the server and keeps its answer without decoding it (the prefetch: the screen
    /// decodes the copy when it opens, and a copy that doesn't decode counts as none).
    func refresh() async throws {
        let (data, _) = try await client.data(for: client.request(.get, path, query: query))
        client.cache?.write(data, for: key)
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

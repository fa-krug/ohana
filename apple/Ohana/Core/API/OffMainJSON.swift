import Foundation
import os
import SwiftUI

/// An answer decoded off the main thread: the big ones (a year of the calendar, a page of
/// transactions, a page of recipes) would stall the window while they're decoded. The type must
/// be `nonisolated` (and so are the types it holds), or its conformance is the main actor's and
/// can't be used elsewhere. `APIClient.get` / `send`, `FamilyAPI`'s and `CachedGet`'s
/// `fetch()` / `savedOffMain()` and `LoadState.run` take the off-main path for these types by
/// themselves; other types are decoded on the main actor as before.
protocol OffMainDecodable: Decodable, Sendable {}

/// A bare list of such answers (autocompletes, some lists).
extension Array: OffMainDecodable where Element: OffMainDecodable {}

/// Decoding and reading kept copies away from the main thread.
nonisolated enum OffMainJSON {
    private static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "api")

    /// A body that didn't decode: `describe`d, as `APIError.decoding` says it.
    struct Failure: Error {
        let description: String
    }

    @concurrent
    static func decode<T: OffMainDecodable>(_ type: T.Type, from data: Data) async throws(Failure) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let text = describe(error)
            log.fault("Can't decode \(String(describing: T.self), privacy: .public): \(text, privacy: .public)")
            throw Failure(description: text)
        }
    }

    /// The copy kept for `key`, read and decoded off the main thread; nil without one (or one
    /// that no longer decodes).
    @concurrent
    static func saved<T: OffMainDecodable>(_ type: T.Type, cache: ResponseCache?, key: String) async -> Saved<T>? {
        guard let (data, date) = cache?.read(key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        return Saved(value: value, date: date)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, ctx):
            "missing \(path(ctx.codingPath + [key]))"
        case let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx):
            "wrong type at \(path(ctx.codingPath))"
        case let DecodingError.dataCorrupted(ctx):
            "unreadable data at \(path(ctx.codingPath))"
        default:
            error.localizedDescription
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

extension APIClient {
    /// `decode`, off the main thread.
    func decode<T: OffMainDecodable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            return try await OffMainJSON.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.description)
        }
    }

    func get<T: OffMainDecodable>(_ path: String, query: [String: String?] = [:], as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await data(for: request(.get, path, query: query))
        return try await decode(T.self, from: data)
    }

    func send<T: OffMainDecodable>(_ method: HTTPMethod, _ path: String, query: [String: String?] = [:],
                                   body: some Encodable, as type: T.Type = T.self) async throws -> T {
        let encoded = try Self.encoder.encode(body)
        let (data, _) = try await data(for: request(method, path, query: query, body: encoded))
        return try await decode(T.self, from: data)
    }

    func send<T: OffMainDecodable>(_ method: HTTPMethod, _ path: String, query: [String: String?] = [:],
                                   as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await data(for: request(method, path, query: query))
        return try await decode(T.self, from: data)
    }
}

extension FamilyAPI {
    func get<T: OffMainDecodable>(_ sub: String, query: [String: String?] = [:], as type: T.Type = T.self) async throws -> T {
        try await client.get(path(sub), query: query, as: T.self)
    }

    func send<T: OffMainDecodable>(_ method: HTTPMethod, _ sub: String, query: [String: String?] = [:],
                                   body: some Encodable, as type: T.Type = T.self) async throws -> T {
        try await client.send(method, path(sub), query: query, body: body, as: T.self)
    }

    func send<T: OffMainDecodable>(_ method: HTTPMethod, _ sub: String, query: [String: String?] = [:],
                                   as type: T.Type = T.self) async throws -> T {
        try await client.send(method, path(sub), query: query, as: T.self)
    }
}

extension CachedGet where Value: OffMainDecodable {
    /// `saved()`, read and decoded off the main thread; the value decoded last in this launch
    /// when there is one (`ResponseCache.recall`), at once.
    func savedOffMain() async -> Saved<Value>? {
        if let kept = client.cache?.recall(Value.self, key) { return kept }
        let saved = await OffMainJSON.saved(Value.self, cache: client.cache, key: key)
        if let saved { client.cache?.remember(saved.value, date: saved.date, for: key) }
        return saved
    }

    /// `fetch()`, decoded off the main thread.
    func fetch() async throws -> Value {
        let (data, _) = try await client.data(for: client.request(.get, path, query: query))
        let value = try await client.decode(Value.self, from: data)
        client.cache?.write(data, for: key)
        client.cache?.remember(value, date: .now, for: key)
        return value
    }

    /// `fetchOrSaved()`, decoded off the main thread.
    func fetchOrSaved() async throws -> Value {
        do {
            return try await fetch()
        } catch {
            return try await savedIfTemporary(error)
        }
    }

    /// `savedIfTemporary(_:)`, read and decoded off the main thread.
    func savedIfTemporary(_ error: any Error) async throws -> Value {
        guard !(error is CancellationError), APIError.isTemporary(error), let copy = await savedOffMain() else { throw error }
        return copy.value
    }
}

extension LoadState where Value: OffMainDecodable {
    /// Loads a GET kept on the device, its copy and the answer decoded off the main thread.
    static func run(_ state: Binding<LoadState<Value>>, _ get: CachedGet<Value>) async {
        await run(state, savedOffMain: get.savedOffMain, get.fetch)
    }
}

extension LoadState {
    /// Loads a GET kept on the device, made into what the screen shows; its copy and the answer
    /// decoded off the main thread.
    static func run<Answer: OffMainDecodable>(_ state: Binding<LoadState<Value>>, _ get: CachedGet<Answer>,
                                              _ transform: (Answer) -> Value) async {
        await run(state, savedOffMain: { await get.savedOffMain().map { Saved(value: transform($0.value), date: $0.date) } }) {
            transform(try await get.fetch())
        }
    }
}

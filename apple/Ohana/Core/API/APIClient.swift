import Foundation
import os

enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", patch = "PATCH", put = "PUT", delete = "DELETE"
}

/// Talks JSON to one Ohana server with the device's API token (`Authorization: Bearer …`, the
/// token the pairing page handed out). Paths are absolute on the server (`/api/v1/me`); a family's
/// routes go through `FamilyAPI`. A 401 calls `onUnauthorized` (the app signs out) and throws.
final class APIClient {
    /// Failed requests and answers that don't decode (Console: subsystem de.fa-krug.Ohana).
    static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "api")

    let baseURL: URL
    private let token: String?
    private let session: URLSession
    /// The demo's stand-in for the server (`init(demo:)`); nil for a server.
    private let demo: DemoServer?
    var onUnauthorized: (() -> Void)?

    static let decoder = JSONDecoder()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        demo = nil
    }

    /// A client of the demo: answers from `DemoServer`, without a network.
    init(demo: DemoServer) {
        baseURL = DemoServer.baseURL
        token = nil
        session = .shared
        self.demo = demo
    }

    var isDemo: Bool { demo != nil }

    /// The URL of a server path, e.g. `/api/v1/me` or `/api/images/recipes/x.webp`.
    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let (pathPart, existingQuery) = Self.split(path)
        components.path = base + (pathPart.hasPrefix("/") ? pathPart : "/" + pathPart)
        var items = existingQuery
        for (key, value) in query.sorted(by: { $0.key < $1.key }) {
            if let value { items.append(URLQueryItem(name: key, value: value)) }
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    private static func split(_ path: String) -> (String, [URLQueryItem]) {
        guard let i = path.firstIndex(of: "?") else { return (path, []) }
        let items = URLComponents(string: "x:/?" + path[path.index(after: i)...])?.queryItems ?? []
        return (String(path[..<i]), items)
    }

    func request(_ method: HTTPMethod, _ path: String, query: [String: String?] = [:], body: Data? = nil,
                 contentType: String? = "application/json") -> URLRequest {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method.rawValue
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }
        req.timeoutInterval = 60
        return req
    }

    /// Sends a request and returns the body of a 2xx answer; throws `APIError` otherwise.
    func data(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let demo {
            let (data, http) = demo.respond(to: req)
            try check(http, data: data)
            return (data, http)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response") }
        try check(http, data: data)
        return (data, http)
    }

    func check(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = APIError.message(from: data)
        Self.log.error("HTTP \(http.statusCode) \(http.url?.path() ?? "", privacy: .public): \(message ?? "", privacy: .public)")
        if http.statusCode == 401 {
            onUnauthorized?()
            throw APIError.unauthorized(message)
        }
        throw APIError.http(status: http.statusCode, message: message)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == Empty.self, data.isEmpty { return Empty() as! T }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.log.fault("Can't decode \(String(describing: T.self), privacy: .public): \(Self.describe(error), privacy: .public)")
            throw APIError.decoding(Self.describe(error))
        }
    }

    // MARK: JSON calls

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:], as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await data(for: request(.get, path, query: query))
        return try decode(T.self, from: data)
    }

    func send<T: Decodable>(_ method: HTTPMethod, _ path: String, query: [String: String?] = [:],
                            body: some Encodable, as type: T.Type = T.self) async throws -> T {
        let encoded = try Self.encoder.encode(body)
        let (data, _) = try await data(for: request(method, path, query: query, body: encoded))
        return try decode(T.self, from: data)
    }

    func send<T: Decodable>(_ method: HTTPMethod, _ path: String, query: [String: String?] = [:],
                            as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await data(for: request(method, path, query: query))
        return try decode(T.self, from: data)
    }

    /// The lines of a streamed answer (NDJSON or server-sent events), as they arrive.
    func lines(_ req: URLRequest) async throws -> AsyncThrowingStream<String, any Error> {
        if demo != nil {
            let (data, _) = try await data(for: req)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(String(line)) }
                continuation.finish()
            }
        }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("No HTTP response") }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            try check(http, data: body)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

/// One family's routes: `/api/v1/families/{id}/…` (see server/lib/api/family-api.ts) and the
/// family's other route handlers under the same prefix.
struct FamilyAPI {
    let client: APIClient
    let familyID: String

    var prefix: String { "/api/v1/families/\(familyID)" }

    /// The full server path of a family route: `path("/finance")` → `/api/v1/families/{id}/finance`.
    func path(_ sub: String) -> String {
        sub.isEmpty ? prefix : prefix + (sub.hasPrefix("/") ? sub : "/" + sub)
    }

    func get<T: Decodable>(_ sub: String, query: [String: String?] = [:], as type: T.Type = T.self) async throws -> T {
        try await client.get(path(sub), query: query)
    }

    func send<T: Decodable>(_ method: HTTPMethod, _ sub: String, query: [String: String?] = [:],
                            body: some Encodable, as type: T.Type = T.self) async throws -> T {
        try await client.send(method, path(sub), query: query, body: body)
    }

    func send<T: Decodable>(_ method: HTTPMethod, _ sub: String, query: [String: String?] = [:],
                            as type: T.Type = T.self) async throws -> T {
        try await client.send(method, path(sub), query: query)
    }

    /// Fire-and-forget style call whose answer isn't needed.
    func perform(_ method: HTTPMethod, _ sub: String, body: some Encodable) async throws {
        let _: JSONValue = try await send(method, sub, body: body)
    }

    func perform(_ method: HTTPMethod, _ sub: String) async throws {
        let _: JSONValue = try await send(method, sub)
    }
}

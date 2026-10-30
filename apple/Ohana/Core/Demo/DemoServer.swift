import Foundation

/// What the app shows while no server is connected: a stand-in for the server that answers the
/// API from the JSON files in `Resources/Demo` (`APIClient(demo:)`), so every screen works as
/// with a server, read-only. The demo family is the account's only one, and the account is a
/// viewer of it: the screens hide what changes data, and a request that would change something
/// fails with a note to connect a server.
///
/// A GET's path names its file: `/api/v1/me` → `demo-me.json`, a family route
/// `/api/v1/families/demo/finance/summary` → `demo-finance-summary.json` (the family itself,
/// `/api/v1/families/demo`, → `demo-family.json`), `/api/v1/x/y` → `demo-x-y.json`. Routes whose
/// answer depends on the query (a year, a period, a search) have a handler in
/// `DemoServer.handlers` that picks or filters a file's data.
///
/// The files are templates, so the demo's days stay around today: `{{day:N}}` is the day N days
/// from today ("YYYY-MM-DD"), `{{time:N}}` the moment N minutes from now (ISO 8601 like the
/// server's: "2026-10-30T09:15:00.000Z"), `{{month:N}}` the month N months from this one
/// ("YYYY-MM"), `{{year:N}}` the year N years from this one (digits only), `{{query:name}}` the
/// request's query parameter (empty when missing), `{{anniversary:N:YYYY}}` the day N days from
/// today in the year YYYY (a birthday coming up). `N` may be omitted (0) and signed.
struct DemoServer {
    static let baseURL = URL(string: "https://demo.ohana.invalid")!
    static let familyID = "demo"

    /// One request, as the handlers see it.
    struct Request {
        let method: HTTPMethod
        /// The server path, e.g. `/api/v1/families/demo/finance`.
        let path: String
        let query: [String: String]
        /// A family route's path below the family (`/finance`, "" for the family itself); nil
        /// for the other routes.
        let familyPath: String?
        /// The day the demo calls today.
        let today: Day
        let now: Date

        /// The file of `name` (without `demo-` and `.json`), templated; nil when there is none.
        func fixture(_ name: String) -> Data? {
            DemoServer.fixture(name, for: self)
        }

        /// The file of `name`, decoded as any JSON.
        func json(_ name: String) -> JSONValue? {
            fixture(name).flatMap { try? APIClient.decoder.decode(JSONValue.self, from: $0) }
        }
    }

    /// A handler answers a route itself (nil: not mine); they're asked in order before the
    /// path's file. Each module adds its own (`Demo+<Module>.swift`).
    typealias Handler = @MainActor (Request) -> JSONValue?

    static let handlers: [Handler] = [
        DemoServer.calendar,
        DemoServer.finance,
        DemoServer.meals,
        DemoServer.appointments,
        DemoServer.assistant,
        DemoServer.overview,
    ]

    static let readOnlyMessage = String(localized: "This is demo data. Connect your Ohana server to make changes.")

    var today: () -> Day = { Day.today }
    var now: () -> Date = { Date() }

    /// The answer to `req`: a family's GET from its handler or file; 404 for what the demo
    /// doesn't have, 403 for anything that would change data.
    func respond(to req: URLRequest) -> (Data, HTTPURLResponse) {
        let url = req.url ?? Self.baseURL
        let method = HTTPMethod(rawValue: req.httpMethod ?? "GET") ?? .get
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = url.path(percentEncoded: false)
        let request = Request(method: method, path: path, query: query, familyPath: Self.familyPath(of: path),
                              today: today(), now: now())

        guard method == .get else {
            return Self.answer(url, status: 403, .object(["error": .string(Self.readOnlyMessage)]))
        }
        for handler in Self.handlers {
            if let value = handler(request) { return Self.answer(url, status: 200, value) }
        }
        if let name = Self.fixtureName(for: request), let data = request.fixture(name) {
            return Self.answer(url, status: 200, data: data)
        }
        return Self.answer(url, status: 404, .object(["error": .string("Not found")]))
    }

    // MARK: Files

    private static let familyPrefix = "/api/v1/families/\(familyID)"

    static func familyPath(of path: String) -> String? {
        guard path == familyPrefix || path.hasPrefix(familyPrefix + "/") else { return nil }
        let rest = String(path.dropFirst(familyPrefix.count))
        return rest == "/" ? "" : rest
    }

    /// The file a GET's path names (see the type's comment).
    static func fixtureName(for request: Request) -> String? {
        if let sub = request.familyPath {
            return sub.isEmpty ? "family" : name(of: sub)
        }
        guard request.path.hasPrefix("/api/v1/") else { return nil }
        return name(of: String(request.path.dropFirst("/api/v1".count)))
    }

    private static func name(of path: String) -> String {
        path.split(separator: "/").joined(separator: "-")
    }

    private final class BundleToken {}

    static func fixture(_ name: String, for request: Request) -> Data? {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "demo-\(name)", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Data(template(text, for: request).utf8)
    }

    private static let placeholder = /\{\{(\w+)(?::([^}]*))?\}\}/

    /// Fills in the placeholders of a file (see the type's comment).
    static func template(_ text: String, for request: Request) -> String {
        text.replacing(placeholder) { match in
            let kind = String(match.output.1)
            let argument = match.output.2.map(String.init) ?? ""
            let offset = Int(argument.trimmingCharacters(in: .whitespaces)) ?? 0
            switch kind {
            case "day":
                return request.today.adding(days: offset).description
            case "month":
                let month = request.today.adding(months: offset)
                return String(format: "%04d-%02d", month.year, month.month)
            case "year":
                return String(request.today.year + offset)
            case "time":
                return timestamp(request.now.addingTimeInterval(TimeInterval(offset * 60)))
            case "anniversary":
                let parts = argument.split(separator: ":")
                let day = request.today.adding(days: parts.first.flatMap { Int($0) } ?? 0)
                let year = parts.dropFirst().first.flatMap { Int($0) } ?? day.year
                // 29 February in another year: the 28th.
                return Day(year: year, month: day.month, day: day.month == 2 && day.day == 29 ? 28 : day.day).description
            case "query":
                return request.query[argument] ?? ""
            default:
                return String(match.output.0)
            }
        }
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // MARK: Answers

    private static func answer(_ url: URL, status: Int, _ value: JSONValue) -> (Data, HTTPURLResponse) {
        answer(url, status: status, data: (try? APIClient.encoder.encode(value)) ?? Data())
    }

    private static func answer(_ url: URL, status: Int, data: Data) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

import Foundation

/// The connected server as the app leaves it for its share extensions: the server's address, the
/// device's API token and the family on screen, all in the Keychain (`Keychain`, one access group
/// for the app and the extensions, no App Group needed). The app writes them (`remember`) when it
/// pairs, at launch and when the family changes, and removes them when it signs out (`forget`).
/// Compiled into the app and the extensions: Foundation only, no app code.
nonisolated struct SharedConnection: Sendable {
    let server: URL
    let token: String
    /// The family the app shows; nil when the app hasn't said (then the account's first).
    let familyID: String?

    /// The Keychain accounts (service `de.fa-krug.Ohana`).
    enum Account {
        static let token = "apiToken"
        static let server = "serverURL"
        static let family = "selectedFamilyID"
    }

    /// The app's connection; nil without a server (the app shows the demo).
    static func load() -> SharedConnection? {
        guard let text = Keychain.load(Account.server), let server = URL(string: text),
              let token = Keychain.load(Account.token), !token.isEmpty else { return nil }
        return SharedConnection(server: server, token: token, familyID: Keychain.load(Account.family))
    }

    // MARK: Written by the app

    /// Mirrors the server and family of the app's connection for the extensions.
    static func remember(server: URL, familyID: String?) {
        Keychain.save(server.absoluteString, for: Account.server)
        remember(familyID: familyID)
    }

    static func remember(familyID: String?) {
        if let familyID {
            Keychain.save(familyID, for: Account.family)
        } else {
            Keychain.delete(Account.family)
        }
    }

    /// Signed out: the extensions see no server anymore (the token is deleted by the app).
    static func forget() {
        Keychain.delete(Account.server)
        Keychain.delete(Account.family)
    }

    // MARK: Requests

    /// A request to a server path (`/api/v1/me`), with the token. `timeout` in seconds.
    func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 60) -> URLRequest {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var req = URLRequest(url: server.appending(path: relative))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = timeout
        return req
    }

    /// The body of a 2xx answer; `SharedError` otherwise.
    func data(for req: URLRequest, session: URLSession = .shared) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SharedError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SharedError.transport("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw SharedError.server(status: http.statusCode, message: ServerErrorText.message(from: data))
        }
        return data
    }

    /// A family of GET /api/v1/me.
    struct Family: Decodable, Equatable, Sendable {
        let id: String
        let name: String
    }

    private struct Me: Decodable {
        let families: [Family]
    }

    /// The family to save into: the one the app shows, else the account's first.
    func family(session: URLSession = .shared) async throws -> Family {
        let data = try await data(for: request("GET", "/api/v1/me"), session: session)
        let me: Me
        do {
            me = try JSONDecoder().decode(Me.self, from: data)
        } catch {
            throw SharedError.transport(String(localized: "The server sent something unexpected."))
        }
        guard let family = Self.pick(me.families, selected: familyID) else { throw SharedError.noFamily }
        return family
    }

    static func pick(_ families: [Family], selected: String?) -> Family? {
        families.first { $0.id == selected } ?? families.first
    }

    /// Reading a page takes the server's AI up to about two minutes (the app's import sheet and
    /// the Shortcuts action wait for it).
    static let importTimeout: TimeInterval = 180

    /// Looking at a page (the preview) fetches it on the server: up to about 20 seconds.
    static let previewTimeout: TimeInterval = 25

    /// GET /api/v1/families/{id}/meals/status: whether the family's AI can read recipes.
    func mealsStatus(familyID: String, session: URLSession = .shared) async throws -> MealsAIAvailability {
        try decode(await data(for: request("GET", "/api/v1/families/\(familyID)/meals/status"), session: session))
    }

    /// POST …/meals/recipes/import/preview: whether the page is a recipe (its schema.org JSON-LD,
    /// read by the server without the AI), its title and photo.
    func previewRecipe(familyID: String, _ input: RecipePreviewRequest, session: URLSession = .shared) async throws -> RecipePreview {
        let req = request("POST", RecipeImportRequest.previewPath(familyID: familyID),
                          body: try JSONEncoder().encode(input), timeout: Self.previewTimeout)
        return try decode(await data(for: req, session: session))
    }

    /// POST …/meals/recipes/import with `background`: the server queues the import and answers at
    /// once (its worker reads the page; the recipe lands in "Want to try"). An older server
    /// imports it before answering.
    func startImport(familyID: String, _ input: RecipeImportRequest, session: URLSession = .shared) async throws -> RecipeImportStarted {
        let req = request("POST", RecipeImportRequest.path(familyID: familyID), body: try JSONEncoder().encode(input))
        return try decode(await data(for: req, session: session))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SharedError.transport(String(localized: "The server sent something unexpected."))
        }
    }
}

/// The body of POST …/meals/recipes/import: the page's address, and what the share sheet read of
/// it (its text: JSON-LD and the visible text; its title; its og:image). Without `text` the server
/// fetches the page itself. `background`: queue it and answer at once (`RecipeImportStarted`).
nonisolated struct RecipeImportRequest: Codable, Equatable, Sendable {
    var url: String
    var text: String?
    var title: String?
    var imageUrl: String?
    var background: Bool?

    /// The most text sent along (the page script caps it too).
    static let maxText = 100_000

    init(url: URL, text: String? = nil, title: String? = nil, imageUrl: String? = nil, background: Bool? = nil) {
        self.url = url.absoluteString
        self.text = Self.clean(text).map { String($0.prefix(Self.maxText)) }
        self.title = Self.clean(title)
        self.imageUrl = Self.clean(imageUrl).flatMap { URL(string: $0)?.scheme?.hasPrefix("http") == true ? $0 : nil }
        self.background = background
    }

    static func path(familyID: String) -> String { "/api/v1/families/\(familyID)/meals/recipes/import" }

    static func previewPath(familyID: String) -> String { path(familyID: familyID) + "/preview" }

    fileprivate static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// The body of POST …/meals/recipes/import/preview: the page's address (and title, shown back
/// when the server can't read one).
nonisolated struct RecipePreviewRequest: Encodable, Equatable, Sendable {
    var url: String
    var title: String?

    init(url: URL, title: String? = nil) {
        self.url = url.absoluteString
        self.title = RecipeImportRequest.clean(title)
    }
}

/// The preview's answer: whether the page holds a schema.org Recipe, its title and photo.
nonisolated struct RecipePreview: Decodable, Equatable, Sendable {
    let recipe: Bool
    let title: String
    let imageUrl: String?
}

/// The answer of a synchronous import (an older server, the app's import sheet): the saved recipe.
nonisolated struct ImportedRecipe: Codable, Equatable, Sendable {
    let id: String
    let title: String
}

/// An import the server's worker is doing or failed at (GET …/meals/recipes/imports). A
/// successful one is gone from the list: its recipe is in "Want to try".
nonisolated struct RecipeImportJob: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let url: String
    /// The page's title as sent; may be empty.
    let title: String
    let imageUrl: String?
    /// "waiting", "running" or "failed".
    let status: String
    let error: String?
    /// ISO 8601.
    let createdAt: String

    var isFailed: Bool { status == "failed" }
}

/// What POST …/meals/recipes/import answered: the queued import (202 `{import}`), or from an
/// older server that ignores `background`, the recipe it already saved (200 `{id, title}`).
nonisolated enum RecipeImportStarted: Decodable, Equatable, Sendable {
    case queued(RecipeImportJob)
    case imported(ImportedRecipe)

    private enum CodingKeys: String, CodingKey { case `import` }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let job = try container.decodeIfPresent(RecipeImportJob.self, forKey: .import) {
            self = .queued(job)
        } else {
            self = .imported(try ImportedRecipe(from: decoder))
        }
    }
}

/// GET …/meals/status as far as the extension needs it: false when the family's AI isn't set up
/// or the assistant is off.
nonisolated struct MealsAIAvailability: Decodable, Equatable, Sendable {
    let generate: Bool
}

/// The server's error text: `{ "error": "…" }` from the family API, `{ "message": "…" }` from the
/// other route handlers.
nonisolated enum ServerErrorText {
    static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (object["error"] as? String) ?? (object["message"] as? String)
        return text?.isEmpty == false ? text : nil
    }
}

/// What can go wrong outside the app (the share extensions).
nonisolated enum SharedError: LocalizedError, Equatable {
    /// The app has no server (it shows the demo).
    case notConnected
    /// The account belongs to no family.
    case noFamily
    case server(status: Int, message: String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            String(localized: "Open Ohana and connect your server first.")
        case .noFamily:
            String(localized: "Your account isn’t in a family yet. Open Ohana to create or join one.")
        case let .server(status, message):
            if status == 401 {
                String(localized: "Your session has ended. Open Ohana and sign in again.")
            } else {
                message ?? String(localized: "The server answered with an error (\(status)).")
            }
        case let .transport(message):
            message
        }
    }
}

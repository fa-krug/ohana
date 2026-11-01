import Foundation

/// GET /api/v1/server (public, no token): which Ohana the server runs and which of its modules
/// are on. The app needs `requiredAPIVersion` and hides the modules a server turned off
/// (`DISABLED_MODULES` on the server: their routes answer 404). A server from before this route
/// answers 404 itself: `legacy`, API version 0.
struct ServerInfo: Codable, Equatable {
    var name: String
    var version: String
    var apiVersion: Int
    /// The modules that are on, by the server's names (`Module`'s raw values); the calendar is
    /// always among them.
    var modules: [String]
    /// Push to the app (through the relay); nil when the server has it off or is older.
    var push: Push?

    struct Push: Codable, Equatable {
        /// The relay the app registers with (`PUSH_RELAY_URL` on the server).
        var relay: URL
    }

    /// The oldest API version this app works with: older servers are refused.
    static let requiredAPIVersion = 1

    /// The modules a server can turn off.
    static let optionalModules: [Module] = [.finance, .meals, .appointments, .chores, .assistant]

    /// What a server without /api/v1/server is taken for: everything it had then on (the
    /// chores came later, so such a server has none).
    static let legacy = ServerInfo(name: "Ohana", version: "", apiVersion: 0,
                                   modules: ([Module.calendar] + optionalModules.filter { $0 != .chores }).map(\.rawValue))

    init(name: String, version: String, apiVersion: Int, modules: [String], push: Push? = nil) {
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.modules = modules
        self.push = push
    }

    /// Lenient: a missing field takes its default (no API version: too old; no module list:
    /// everything on), so a slightly different server is told apart by its API version alone.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Ohana"
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        apiVersion = try c.decodeIfPresent(Int.self, forKey: .apiVersion) ?? 0
        modules = try c.decodeIfPresent([String].self, forKey: .modules) ?? Self.legacy.modules
        push = try? c.decodeIfPresent(Push.self, forKey: .push)
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, apiVersion, modules, push
    }

    /// The app can talk to this server.
    var isSupported: Bool { apiVersion >= Self.requiredAPIVersion }

    /// Whether the server has `module` on. The overview, the calendar and the settings are
    /// always there.
    func isEnabled(_ module: Module) -> Bool {
        switch module {
        case .overview, .calendar, .settings, .search: true
        case .finance, .meals, .appointments, .chores, .assistant: modules.contains(module.rawValue)
        }
    }

    /// Asks `client`'s server (kept on the device with the client's cache, `saved`); a 404 (a
    /// server from before the route) is `legacy`. Other failures (offline, not an Ohana server)
    /// throw.
    static func fetch(from client: APIClient) async throws -> ServerInfo {
        do {
            return try await request(client).fetch()
        } catch APIError.http(status: 404, message: _) {
            return .legacy
        }
    }

    /// The info as last loaded from `client`'s server.
    static func saved(from client: APIClient) -> ServerInfo? {
        request(client).saved()?.value
    }

    private static func request(_ client: APIClient) -> CachedGet<ServerInfo> {
        client.cached("/api/v1/server")
    }

    /// Said when a server's API is older than the app needs.
    static var outdatedMessage: String {
        String(localized: "This server runs an older version of Ohana. Ask its administrator to update it.")
    }
}

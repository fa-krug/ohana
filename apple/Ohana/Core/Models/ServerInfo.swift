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

    /// The oldest API version this app works with: older servers are refused.
    static let requiredAPIVersion = 1

    /// The modules a server can turn off.
    static let optionalModules: [Module] = [.finance, .meals, .appointments, .assistant]

    /// What a server without /api/v1/server is taken for.
    static let legacy = ServerInfo(name: "Ohana", version: "", apiVersion: 0,
                                   modules: ([Module.calendar] + optionalModules).map(\.rawValue))

    init(name: String, version: String, apiVersion: Int, modules: [String]) {
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.modules = modules
    }

    /// Lenient: a missing field takes its default (no API version: too old; no module list:
    /// everything on), so a slightly different server is told apart by its API version alone.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Ohana"
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        apiVersion = try c.decodeIfPresent(Int.self, forKey: .apiVersion) ?? 0
        modules = try c.decodeIfPresent([String].self, forKey: .modules) ?? Self.legacy.modules
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, apiVersion, modules
    }

    /// The app can talk to this server.
    var isSupported: Bool { apiVersion >= Self.requiredAPIVersion }

    /// Whether the server has `module` on. The overview, the calendar and the settings are
    /// always there.
    func isEnabled(_ module: Module) -> Bool {
        switch module {
        case .overview, .calendar, .settings: true
        case .finance, .meals, .appointments, .assistant: modules.contains(module.rawValue)
        }
    }

    /// Asks `client`'s server; a 404 (a server from before the route) is `legacy`. Other failures
    /// (offline, not an Ohana server) throw.
    static func fetch(from client: APIClient) async throws -> ServerInfo {
        do {
            return try await client.get("/api/v1/server", as: ServerInfo.self)
        } catch APIError.http(status: 404, message: _) {
            return .legacy
        }
    }

    /// Said when a server's API is older than the app needs.
    static var outdatedMessage: String {
        String(localized: "This server runs an older version of Ohana. Ask its administrator to update it.")
    }
}

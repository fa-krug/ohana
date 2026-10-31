import Foundation

/// Pairing with a server (server/lib/auth/device-pairing.ts): the app opens
/// `{server}/device/pair?state=…&deviceName=…` in a browser sheet; the user signs in there
/// (passkeys work: it's the system browser) and confirms, and the page calls back
/// `ohana://auth-callback?token=…&state=…`. `state` is a secret the app made up and never stored,
/// so a callback it didn't ask for doesn't match.
enum DevicePairing {
    static let callbackScheme = "ohana"

    struct Attempt: Equatable {
        let state: String
        init(state: String = UUID().uuidString) { self.state = state }
    }

    enum Outcome: Equatable {
        case paired(token: String)
        case cancelled
        case stateMismatch
        case malformed
    }

    /// Normalizes what the user typed or pasted (see `ServerLink`). Nil for something that can't
    /// be a server.
    static func serverURL(from input: String) -> URL? {
        ServerLink(input)?.server
    }

    static func pairingURL(server: URL, attempt: Attempt, deviceName: String) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/device/pair"
        components.queryItems = [
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "deviceName", value: deviceName),
        ]
        return components.url!
    }

    static func outcome(of callback: URL, attempt: Attempt) -> Outcome {
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            return .malformed
        }
        let value = { (name: String) in items.first(where: { $0.name == name })?.value }
        guard let state = value("state") else { return .malformed }
        guard state == attempt.state else { return .stateMismatch }
        if value("error") != nil { return .cancelled }
        guard let token = value("token"), !token.isEmpty else { return .malformed }
        return .paired(token: token)
    }
}

/// What someone types or pastes as their server: a bare host (`ohana.example.com`), the address
/// from the browser, any page of it (`https://ohana.example/f/abc/calendar`) or an invite link
/// (`https://ohana.example/invite/{code}`). The server is everything before the server's own
/// paths (so a server under a sub-path keeps it); an invite link brings its code along.
struct ServerLink: Equatable {
    let server: URL
    let inviteCode: String?

    /// The first path segments of the server's pages and routes (the sign-in pages, the account
    /// page, `/f/…` links, the API, and those of older servers): where the server's own path ends.
    private static let appSegments: Set<String> = [
        "f", "account", "admin", "families", "invite", "login", "setup", "setup-link", "device",
        "onboarding", "set-language", "api",
    ]

    /// Adds https:// when there's no scheme; drops the page, query and fragment. Nil for
    /// something that can't be a server (spaces, another scheme, no host).
    init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return nil }
        self.init(url: url)
    }

    /// A link the app was opened with: only http(s) links carry their server.
    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        let appStart = segments.firstIndex { Self.appSegments.contains($0) } ?? segments.count
        let page = segments[appStart...]
        if page.count == 2, page.first == "invite", let code = page.last, InviteCode.isCode(code) {
            inviteCode = code
        } else {
            inviteCode = nil
        }
        components.path = segments[..<appStart].map { "/" + $0 }.joined()
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let server = components.url else { return nil }
        self.server = server
    }
}

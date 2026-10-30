import Foundation

/// Pairing with a server (web/lib/auth/device-pairing.ts): the app opens
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

    /// Normalizes what the user typed: adds https:// when there's no scheme, drops a trailing
    /// slash, query and fragment. Nil for something that can't be a server.
    static func serverURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
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

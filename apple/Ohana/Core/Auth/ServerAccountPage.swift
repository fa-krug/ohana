import Foundation

/// The server's account page (`{server}/account`), for what needs the server's own domain:
/// adding a passkey (a passkey belongs to the server's address) and changing the email of an
/// account without a password (confirmed with a passkey). Like pairing (`DevicePairing`), the app
/// opens it in a browser sheet with a `state` it made up; the page calls back
/// `ohana://account-callback?state=…&changed=passkey|email`, or without `changed` when the user
/// went back to the app without a change.
enum ServerAccountPage {
    static let callbackHost = "account-callback"

    /// What the page changed.
    enum Change: String, Equatable {
        case passkey, email
    }

    enum Outcome: Equatable {
        /// Back from the page; `changed` nil: nothing (or nothing the app knows) changed.
        case finished(changed: Change?)
        case stateMismatch
        case malformed
    }

    static func url(server: URL, attempt: DevicePairing.Attempt) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/account"
        components.queryItems = [URLQueryItem(name: "state", value: attempt.state)]
        return components.url!
    }

    static func outcome(of callback: URL, attempt: DevicePairing.Attempt) -> Outcome {
        guard callback.scheme == DevicePairing.callbackScheme, callback.host() == callbackHost,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value else {
            return .malformed
        }
        guard state == attempt.state else { return .stateMismatch }
        let changed = items.first { $0.name == "changed" }?.value.flatMap(Change.init(rawValue:))
        return .finished(changed: changed)
    }
}

import Foundation

/// What can go wrong talking to the Ohana server. The server answers errors as JSON:
/// `{ "error": "…" }` from the family API, `{ "message": "…" }` from the other route handlers.
enum APIError: LocalizedError, Equatable {
    case invalidServer
    case unauthorized(String?)
    case http(status: Int, message: String?)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            String(localized: "That doesn’t look like an Ohana server address.")
        case let .unauthorized(message):
            message ?? String(localized: "Your session has ended, sign in again.")
        case let .http(status, message):
            message ?? String(localized: "The server answered with an error (\(status)).")
        case let .transport(message):
            message
        case let .decoding(message):
            String(localized: "The server sent something unexpected: \(message)")
        }
    }

    var status: Int? {
        switch self {
        case .unauthorized: 401
        case let .http(status, _): status
        default: nil
        }
    }

    /// A failure that may pass by itself (no connection, the server down or busy), unlike a
    /// refusal: worth trying again, and a reason to keep showing what's on the device.
    static func isTemporary(_ error: any Error) -> Bool {
        switch error {
        case is URLError, is CancellationError: true
        case APIError.transport: true
        case let APIError.http(status, _): status >= 500 || status == 408 || status == 429
        default: false
        }
    }

    /// The message of an error body, whichever key the route used.
    static func message(from data: Data) -> String? {
        ServerErrorText.message(from: data)
    }
}

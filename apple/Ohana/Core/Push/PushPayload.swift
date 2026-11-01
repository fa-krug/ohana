import CryptoKit
import Foundation
import UserNotifications

/// What a push from the server carries (server/lib/push/payload.ts), sealed for this device:
/// AES-256-GCM with the device's key, base64 of nonce + ciphertext + tag (CryptoKit's
/// `combined`). The relay and Apple see only that; the notification shows the relay's fallback
/// text ("New notification from Ohana") until the Notification Service Extension opens it.
/// Shared by the app and the extension (`OhanaNotificationService`).
nonisolated struct PushPayload: Codable, Equatable, Sendable {
    var v: Int
    var title: String
    var body: String
    /// Where a tap leads: a path of the server (`/f/{id}/…`).
    var path: String?
    var familyId: String?
    var event: String?

    enum OpenError: Error { case malformed }

    /// The APNs payload's key for the sealed payload (`{"aps": …, "o": "<base64>"}`).
    static let userInfoKey = "o"

    static func open(_ sealed: String, key: Data) throws -> PushPayload {
        guard let data = Data(base64Encoded: sealed) else { throw OpenError.malformed }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        return try JSONDecoder().decode(PushPayload.self, from: plain)
    }

    /// Shows the payload instead of the fallback: title, body, grouped by family, and the path for
    /// the tap (`userInfo["path"]`).
    func apply(to content: UNMutableNotificationContent) {
        content.title = title
        content.body = body
        if let familyId { content.threadIdentifier = familyId }
        var info = content.userInfo
        info.removeValue(forKey: Self.userInfoKey)
        if let path { info["path"] = path }
        if let familyId { info["familyId"] = familyId }
        content.userInfo = info
    }
}

/// The device's key for push payloads, in the Keychain (shared with the extension through the
/// keychain access group). Made when push is turned on, given only to the server.
nonisolated enum PushKey {
    private static let account = "pushKey"

    static func load() -> Data? {
        guard let text = Keychain.load(account), let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return data
    }

    /// The stored key, or a new one.
    static func loadOrCreate() -> Data {
        if let key = load() { return key }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        Keychain.save(key.base64EncodedString(), for: account)
        return key
    }

    static func delete() {
        Keychain.delete(account)
    }
}

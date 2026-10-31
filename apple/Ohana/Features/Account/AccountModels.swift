import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The account routes (server/lib/auth/app-routes.ts, /api/v1/me/...).

/// GET /api/v1/me/account: everything the account screen shows.
struct AccountOverview: Codable, Hashable {
    let user: UserAccount
    let passkeys: [AccountPasskey]
    let tokens: [AccountToken]
    /// Browsers signed in to the account (sessions of the server's pages).
    let sessions: Int
}

/// A passkey (server/lib/auth/passkey-management.ts `PasskeyDto`).
struct AccountPasskey: Codable, Hashable, Identifiable {
    let id: String
    let deviceName: String
    let createdAt: String
    let lastUsedAt: String?

    var createdDate: Date? { Date.server(createdAt) }
    var lastUsedDate: Date? { lastUsedAt.flatMap(Date.server) }
}

/// An API token; `current` is the one this device signs in with.
struct AccountToken: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let createdAt: String
    let lastUsedAt: String?
    let current: Bool

    var createdDate: Date? { Date.server(createdAt) }
    var lastUsedDate: Date? { lastUsedAt.flatMap(Date.server) }
}

/// POST /me/tokens: the token itself, shown once.
struct AccountNewToken: Codable, Hashable {
    let token: String
    let item: AccountToken
}

/// DELETE /me/tokens/{id}
struct AccountTokenDeleted: Codable, Hashable {
    let ok: Bool
    /// The device's own token was deleted: the app is signed out.
    let signedOut: Bool
}

/// GET / DELETE /me/sessions
struct AccountSessions: Codable, Hashable {
    let count: Int
}

/// GET or answer of PATCH/DELETE /me/passkeys…
struct AccountPasskeyList: Codable, Hashable {
    let passkeys: [AccountPasskey]
}

struct AccountProfileInput: Encodable {
    var name: String?
    var preferredLanguage: String?
}

struct AccountEmailInput: Encodable {
    let newEmail: String
    let currentPassword: String
}

struct AccountPasswordInput: Encodable {
    /// Needed when a password is set already.
    let currentPassword: String?
    let newPassword: String
}

struct AccountRemovePasswordInput: Encodable {
    let currentPassword: String
}

struct AccountPasskeyRenameInput: Encodable {
    let deviceName: String
}

struct AccountTokenInput: Encodable {
    let name: String
}

/// The languages the server writes in (notifications, preset names of new families).
enum AccountLanguage: String, CaseIterable, Identifiable {
    case en, de
    var id: String { rawValue }

    /// Each in its own language, like the web's picker.
    var title: String {
        switch self {
        case .en: "English"
        case .de: "Deutsch"
        }
    }
}

/// The web account page's rules, so the app doesn't offer what the server refuses: an account
/// always keeps a way to sign in (a password or a passkey).
enum AccountRules {
    /// The password can go only while there is a passkey.
    static func canRemovePassword(_ overview: AccountOverview) -> Bool {
        overview.user.hasPassword && !overview.passkeys.isEmpty
    }

    /// A passkey can go unless it is the last one and there is no password.
    static func canDeletePasskey(_ overview: AccountOverview) -> Bool {
        overview.user.hasPassword || overview.passkeys.count > 1
    }

    /// The email is changed with the password; without one, with a passkey on the server's
    /// account page (`ServerAccountPage`).
    static func canChangeEmailHere(_ user: UserAccount) -> Bool {
        user.hasPassword
    }

    /// The device's token first, then the others as the server lists them (oldest first).
    static func sortedTokens(_ tokens: [AccountToken]) -> [AccountToken] {
        tokens.filter(\.current) + tokens.filter { !$0.current }
    }

    /// The suffix pairing gives a device's token (server/lib/auth/device-pairing.ts): "<device> (app)",
    /// or "Ohana app" without a device name.
    private static let deviceSuffix = " (app)"
    private static let unnamedDevice = "Ohana app"

    /// A token an Ohana app signed in with (this device's, or one paired like it), not one made for
    /// a script.
    static func isDevice(_ token: AccountToken) -> Bool {
        token.current || token.name.hasSuffix(deviceSuffix) || token.name == unnamedDevice
    }

    /// The signed-in devices: this one first.
    static func deviceTokens(_ tokens: [AccountToken]) -> [AccountToken] {
        sortedTokens(tokens).filter(isDevice)
    }

    /// The tokens made for scripts and programs (Advanced ▸ API tokens).
    static func scriptTokens(_ tokens: [AccountToken]) -> [AccountToken] {
        tokens.filter { !isDevice($0) }
    }

    /// A device token's device: "iPhone" of "iPhone (app)".
    static func deviceName(_ token: AccountToken) -> String {
        let name = token.name.hasSuffix(deviceSuffix) ? String(token.name.dropLast(deviceSuffix.count)) : token.name
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? unnamedDevice : name
    }

    /// Trimmed text, nil when blank.
    static func trimmed(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// "created 3 Nov 2026 · last used 5 Nov 2026" for passkeys and tokens.
enum AccountDates {
    static func line(created: Date?, lastUsed: Date?) -> String {
        var parts: [String] = []
        if let created {
            parts.append(String(localized: "created \(created.formatted(date: .abbreviated, time: .omitted))"))
        }
        if let lastUsed {
            parts.append(String(localized: "last used \(lastUsed.formatted(.relative(presentation: .named)))"))
        } else {
            parts.append(String(localized: "never used"))
        }
        return parts.joined(separator: " · ")
    }
}

enum AccountPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

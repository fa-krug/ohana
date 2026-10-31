import Foundation
import Testing
@testable import Ohana

struct AccountTests {
    /// GET /api/v1/me/account as the server answered it (web tests' setup).
    static let account = """
    {"user":{"id":"u1","email":"anna@test","name":"Anna","preferredLanguage":"en","onboardingStep":"COMPLETED","isAdmin":true,"hasPassword":true,"hasPasskey":true},"passkeys":[{"id":"pk1","deviceName":"iPhone","createdAt":"2026-11-01T12:00:00.000Z","lastUsedAt":null}],"tokens":[{"id":"t0","name":"Home Assistant","createdAt":"2026-10-01T12:00:00.000Z","lastUsedAt":null,"current":false},{"id":"t1","name":"iPhone (app)","createdAt":"2026-11-01T12:00:00.000Z","lastUsedAt":"2026-11-01T12:00:00.000Z","current":true}],"sessions":1}
    """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesTheAccount() throws {
        let a = try decode(AccountOverview.self, Self.account)
        #expect(a.user.isAdmin && a.user.hasPassword && a.user.hasPasskey)
        #expect(a.passkeys.map(\.deviceName) == ["iPhone"])
        #expect(a.passkeys[0].createdDate != nil && a.passkeys[0].lastUsedDate == nil)
        #expect(a.tokens.count == 2)
        #expect(a.tokens[1].current && a.tokens[1].lastUsedDate != nil)
        #expect(a.sessions == 1)
    }

    @Test func decodesTheAnswersOfChanges() throws {
        let created = try decode(AccountNewToken.self, """
        {"token":"ohana_bEzB5ZaGr4O6k0mkS0SInPuOlGQHCdtqMYzVCmgqy7I","item":{"id":"t2","name":"Home Assistant","createdAt":"2026-11-01T12:00:00.000Z","lastUsedAt":null,"current":false}}
        """)
        #expect(created.token.hasPrefix("ohana_"))
        #expect(!created.item.current)
        #expect(try decode(AccountTokenDeleted.self, #"{"ok":true,"signedOut":true}"#).signedOut)
        #expect(try decode(AccountSessions.self, #"{"count":2}"#).count == 2)
        let list = try decode(AccountPasskeyList.self, #"{"passkeys":[]}"#)
        #expect(list.passkeys.isEmpty)
    }

    @Test func sortsTheDevicesTokenFirst() throws {
        let a = try decode(AccountOverview.self, Self.account)
        #expect(AccountRules.sortedTokens(a.tokens).map(\.id) == ["t1", "t0"])
    }

    @Test func tellsSignedInDevicesFromScriptTokens() throws {
        let a = try decode(AccountOverview.self, Self.account)
        #expect(AccountRules.deviceTokens(a.tokens).map(\.id) == ["t1"])
        #expect(AccountRules.scriptTokens(a.tokens).map(\.id) == ["t0"])
        #expect(AccountRules.deviceName(a.tokens[1]) == "iPhone")

        let paired = try decode(AccountToken.self, """
        {"id":"t3","name":"Mac mini (app)","createdAt":"2026-11-01T12:00:00.000Z","lastUsedAt":null,"current":false}
        """)
        let unnamed = try decode(AccountToken.self, """
        {"id":"t4","name":"Ohana app","createdAt":"2026-11-01T12:00:00.000Z","lastUsedAt":null,"current":false}
        """)
        #expect(AccountRules.isDevice(paired) && AccountRules.isDevice(unnamed))
        #expect(AccountRules.deviceName(paired) == "Mac mini")
        #expect(AccountRules.deviceName(unnamed) == "Ohana app")
        // The device signed in here comes first, the others in the server's order.
        #expect(AccountRules.deviceTokens([paired] + a.tokens + [unnamed]).map(\.id) == ["t1", "t3", "t4"])
        #expect(AccountRules.scriptTokens([paired] + a.tokens + [unnamed]).map(\.id) == ["t0"])
    }

    @Test func keepsAWayToSignIn() throws {
        let a = try decode(AccountOverview.self, Self.account)
        #expect(AccountRules.canRemovePassword(a))
        #expect(AccountRules.canDeletePasskey(a))
        #expect(AccountRules.canChangeEmailHere(a.user))

        // Password, no passkey: the password stays.
        let noPasskey = try decode(AccountOverview.self, Self.account.replacingOccurrences(
            of: #""passkeys":[{"id":"pk1","deviceName":"iPhone","createdAt":"2026-11-01T12:00:00.000Z","lastUsedAt":null}]"#,
            with: #""passkeys":[]"#))
        #expect(!AccountRules.canRemovePassword(noPasskey))

        // One passkey, no password: the passkey stays, the email is changed on the web.
        let passkeyOnly = try decode(AccountOverview.self, Self.account.replacingOccurrences(
            of: #""hasPassword":true"#, with: #""hasPassword":false"#))
        #expect(!AccountRules.canDeletePasskey(passkeyOnly))
        #expect(!AccountRules.canRemovePassword(passkeyOnly))
        #expect(!AccountRules.canChangeEmailHere(passkeyOnly.user))
    }

    @Test func encodesOnlyWhatChanges() throws {
        func json(_ value: some Encodable) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        }
        #expect(try json(AccountProfileInput(name: "Anna")).keys.sorted() == ["name"])
        #expect(try json(AccountProfileInput(preferredLanguage: "de")) as? [String: String] == ["preferredLanguage": "de"])
        let first = try json(AccountPasswordInput(currentPassword: nil, newPassword: "secret secret"))
        #expect(first.keys.sorted() == ["newPassword"])
        #expect(try json(AccountEmailInput(newEmail: "a@b.test", currentPassword: "x")).count == 2)
    }

    @Test func trimsAndDescribesDates() {
        #expect(AccountRules.trimmed("  ") == nil)
        #expect(AccountRules.trimmed(" Home ") == "Home")
        #expect(AccountDates.line(created: nil, lastUsed: nil) == "never used")
        #expect(AccountDates.line(created: Date(timeIntervalSince1970: 0), lastUsed: nil).hasPrefix("created "))
        #expect(AccountLanguage.allCases.map(\.rawValue) == ["en", "de"])
    }
}

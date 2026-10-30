import Foundation
import Testing
@testable import Ohana

struct AdminTests {
    /// GET /api/v1/admin/users and /admin/families as the server answered them.
    static let users = """
    {"users":[{"id":"u1","email":"anna@test","name":"Anna","isAdmin":true,"hasPassword":true,"passkeyCount":1,"familyCount":1,"onboardingStep":"COMPLETED","createdAt":"2026-11-01T12:00:00.000Z"},{"id":"u2","email":"ben@test","name":"","isAdmin":false,"hasPassword":false,"passkeyCount":0,"familyCount":1,"onboardingStep":"SET_CREDENTIALS","createdAt":"2026-11-01T12:00:00.000Z"}]}
    """
    static let families = """
    {"families":[{"id":"f1","name":"Krug","createdAt":"2026-11-01T12:00:00.000Z","members":[{"userId":"u1","email":"anna@test","name":"Anna","role":"editor"},{"userId":"u2","email":"ben@test","name":"","role":"viewer"}]}]}
    """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesUsers() throws {
        let users = try decode(AdminUserList.self, Self.users).users
        #expect(users.map(\.displayName) == ["Anna", "ben@test"])
        #expect(!users[0].isPending && users[1].isPending)
        #expect(AdminText.details(users[1]).contains("hasn’t signed in yet"))
        #expect(AdminText.details(users[0]) == "1 passkey · password · 1 family")
        let created = try decode(AdminCreatedUser.self, """
        {"userId":"u3","setupUrl":"http://ohana.test/setup-link/2KEP-e4tfankE-K6YXeKGu8Q_agCew6r-VVXVvpoH_s","expiresAt":"2026-11-08T12:00:00.000Z"}
        """)
        #expect(created.setupUrl.contains("/setup-link/"))
        #expect(try decode(AdminSetupLink.self, #"{"setupUrl":"http://x/setup-link/a","expiresAt":"2026-11-08T12:00:00.000Z"}"#).setupUrl == "http://x/setup-link/a")
    }

    @Test func decodesFamilies() throws {
        let families = try decode(AdminFamilyList.self, Self.families).families
        #expect(families[0].members.map(\.displayName) == ["Anna", "ben@test"])
        #expect(families[0].editorCount == 1)
        #expect(try decode(AdminCreatedFamily.self, #"{"id":"f2"}"#).id == "f2")
    }

    @Test func aFamilyKeepsAnEditor() throws {
        let family = try decode(AdminFamilyList.self, Self.families).families[0]
        let anna = family.members[0], ben = family.members[1]
        #expect(!AdminRules.canChangeRole(of: anna, in: family))
        #expect(AdminRules.canChangeRole(of: ben, in: family))
        #expect(!AdminRules.canRemove(anna, from: family))
        #expect(AdminRules.canRemove(ben, from: family))
        let alone = AdminFamily(id: "f", name: "Solo", createdAt: "", members: [anna])
        #expect(AdminRules.canRemove(anna, from: alone))
        let two = AdminFamily(id: "f", name: "Two", createdAt: "",
                              members: [anna, AdminFamilyMember(userId: "u2", email: "ben@test", name: "", role: .editor)])
        #expect(AdminRules.canChangeRole(of: anna, in: two) && AdminRules.canRemove(anna, from: two))
    }

    @Test func searches() throws {
        let users = try decode(AdminUserList.self, Self.users).users
        #expect(AdminRules.filter(users, "BEN").map(\.id) == ["u2"])
        #expect(AdminRules.filter(users, " ").count == 2)
        let families = try decode(AdminFamilyList.self, Self.families).families
        #expect(AdminRules.filter(families, "ben@").count == 1)
        #expect(AdminRules.filter(families, "Müller").isEmpty)
    }

    @Test func knowsOnesOwnAccount() throws {
        let users = try decode(AdminUserList.self, Self.users).users
        let me = try decode(MeResponse.self, """
        {"user":{"id":"u1","email":"anna@test","name":"Anna","preferredLanguage":"en","onboardingStep":"COMPLETED","isAdmin":true,"hasPassword":true,"hasPasskey":true},"families":[]}
        """).user
        #expect(AdminRules.isSelf(users[0], me: me))
        #expect(!AdminRules.isSelf(users[1], me: me))
    }

    @Test func encodesTheRoles() throws {
        let data = try JSONEncoder().encode(AdminMemberInput(email: "ben@test", role: .viewer))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object == ["email": "ben@test", "role": "viewer"])
    }
}

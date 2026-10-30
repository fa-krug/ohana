import Foundation

/// The signed-in account (web/lib/auth/serialize.ts `UserDto`).
struct UserAccount: Codable, Hashable, Identifiable {
    let id: String
    let email: String
    let name: String
    let preferredLanguage: String
    let onboardingStep: String
    let isAdmin: Bool
    let hasPassword: Bool
    let hasPasskey: Bool

    var displayName: String { name.isEmpty ? email : name }
}

enum FamilyRole: String, Codable, Hashable {
    case editor, viewer
}

/// One of the account's families (web/lib/families/manage.ts `listFamiliesOf`).
struct FamilySummary: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let role: FamilyRole
    let memberCount: Int

    var canEdit: Bool { role == .editor }
}

/// GET /api/v1/me
struct MeResponse: Codable {
    let user: UserAccount
    let families: [FamilySummary]
}

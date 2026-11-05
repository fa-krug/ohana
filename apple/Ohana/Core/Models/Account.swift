import Foundation

/// The signed-in account (server/lib/auth/serialize.ts `UserDto`).
nonisolated struct UserAccount: Codable, Hashable, Identifiable, Sendable {
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

nonisolated enum FamilyRole: String, Codable, Hashable, Sendable {
    case editor, viewer
}

/// One of the account's families (server/lib/families/manage.ts `listFamiliesOf`).
nonisolated struct FamilySummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: FamilyRole
    let memberCount: Int

    var canEdit: Bool { role == .editor }
}

/// GET /api/v1/me, decoded off the main thread (`OffMainDecodable`).
nonisolated struct MeResponse: Codable, OffMainDecodable {
    let user: UserAccount
    let families: [FamilySummary]
}

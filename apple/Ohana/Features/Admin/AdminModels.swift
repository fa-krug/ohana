import Foundation
import SwiftUI

// The administration routes (server/lib/admin/app-routes.ts, /api/v1/admin/...).

/// An account (server/lib/admin/users.ts `AdminUserDto`).
struct AdminUser: Codable, Hashable, Identifiable {
    let id: String
    let email: String
    let name: String
    let isAdmin: Bool
    let hasPassword: Bool
    let passkeyCount: Int
    let familyCount: Int
    let onboardingStep: String
    let createdAt: String

    var displayName: String { name.isEmpty ? email : name }
    /// Made by an administrator and not signed in yet (the setup link is still open).
    var isPending: Bool { onboardingStep == "SET_CREDENTIALS" }
}

struct AdminUserList: Codable, Hashable {
    let users: [AdminUser]
}

/// POST /admin/users: the new account and its one-time setup link.
struct AdminCreatedUser: Codable, Hashable {
    let userId: String
    let setupUrl: String
    let expiresAt: String
}

/// POST /admin/users/{id}/setup-link
struct AdminSetupLink: Codable, Hashable {
    let setupUrl: String
    let expiresAt: String
}

/// A family with its members (server/lib/admin/families.ts `AdminFamilyDto`).
struct AdminFamily: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let createdAt: String
    let members: [AdminFamilyMember]

    var editorCount: Int { members.filter { $0.role == .editor }.count }
}

struct AdminFamilyMember: Codable, Hashable, Identifiable {
    let userId: String
    let email: String
    let name: String
    let role: FamilyRole

    var id: String { userId }
    var displayName: String { name.isEmpty ? email : name }
}

struct AdminFamilyList: Codable, Hashable {
    let families: [AdminFamily]
}

struct AdminCreatedFamily: Codable, Hashable {
    let id: String
}

struct AdminNewUserInput: Encodable {
    let email: String
    let name: String
    let isAdmin: Bool
}

struct AdminUserUpdateInput: Encodable {
    let email: String
    let name: String
    let isAdmin: Bool
}

struct AdminFamilyNameInput: Encodable {
    let name: String
}

struct AdminMemberInput: Encodable {
    let email: String
    let role: FamilyRole
}

struct AdminRoleInput: Encodable {
    let role: FamilyRole
}

/// The server's rules, so the app doesn't offer what it refuses.
enum AdminRules {
    /// A family always keeps an editor: its only editor can't become a viewer.
    static func canChangeRole(of member: AdminFamilyMember, in family: AdminFamily) -> Bool {
        member.role == .viewer || family.editorCount > 1
    }

    /// Nor can its only editor leave while others stay (the last member can go).
    static func canRemove(_ member: AdminFamilyMember, from family: AdminFamily) -> Bool {
        member.role == .viewer || family.editorCount > 1 || family.members.count == 1
    }

    /// One's own account can't be deleted, nor lose its administrator rights.
    static func isSelf(_ user: AdminUser, me: UserAccount?) -> Bool {
        user.id == me?.id
    }

    /// The users' list filtered by a search in names and emails.
    static func filter(_ users: [AdminUser], _ query: String) -> [AdminUser] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return users }
        return users.filter { $0.email.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
    }

    static func filter(_ families: [AdminFamily], _ query: String) -> [AdminFamily] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return families }
        return families.filter { family in
            family.name.localizedCaseInsensitiveContains(q)
                || family.members.contains { $0.email.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
        }
    }
}

enum AdminText {
    static func role(_ role: FamilyRole) -> LocalizedStringKey {
        switch role {
        case .editor: "Editor"
        case .viewer: "Viewer"
        }
    }

    /// "2 passkeys · password · 1 family" for a user's row.
    static func details(_ user: AdminUser) -> String {
        var parts: [String] = []
        if user.isPending {
            parts.append(String(localized: "hasn’t signed in yet"))
        } else {
            // English has no plural variants in the catalog: the singular is its own key.
            parts.append(user.passkeyCount == 1 ? String(localized: "1 passkey") : String(localized: "\(user.passkeyCount) passkeys"))
            if user.hasPassword { parts.append(String(localized: "password")) }
        }
        parts.append(user.familyCount == 1 ? String(localized: "1 family") : String(localized: "\(user.familyCount) families"))
        return parts.joined(separator: " · ")
    }
}

/// A one-time setup link to hand on (new account, new link).
struct AdminSetupLinkItem: Identifiable {
    let url: String
    let name: String
    let isNew: Bool
    var id: String { url }
}

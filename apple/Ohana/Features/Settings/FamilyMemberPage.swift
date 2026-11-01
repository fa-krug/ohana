import SwiftUI

/// One member's page, opened from their row in Settings → Members: an account's birthday and
/// role, or a member without an account's name, birthday and invite link; editors remove them
/// here. It shows what `model` holds, so it follows the reloads, and closes once they're gone.
struct FamilyMemberPage: View {
    enum Subject: Hashable {
        case member(String)
        case person(String)
    }

    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: FamilySettingsModel
    let subject: Subject

    @State private var sheet: FamilyMemberSheet?
    @State private var confirmation: FamilyConfirmation?
    @State private var sharedLink: FamilySharedLink?

    private var member: FamilyMember? {
        guard case let .member(id) = subject else { return nil }
        return model.household?.members.first { $0.userId == id }
    }

    private var person: FamilyPerson? {
        guard case let .person(id) = subject else { return nil }
        return model.household?.person(id)
    }

    private var gone: Bool { model.household != nil && member == nil && person == nil }

    var body: some View {
        Form {
            if let household = model.household {
                if let member {
                    memberSections(member, household: household)
                } else if let person {
                    personSections(person, household: household)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle(member?.label ?? person?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load(family.api) }
        .onChange(of: gone, initial: true) { if gone { dismiss() } }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .birthday(member):
                FamilyBirthdaySheet(title: member.label, birthday: member.birthday) { birthday in
                    try await model.update(family, success: String(localized: "Birthday saved.")) { api in
                        try await api.perform(.patch, "/household/members/\(member.userId)", body: FamilyBirthdayInput(birthday: birthday))
                    }
                }
            case let .editPerson(person):
                FamilyPersonSheet(person: person) { input in
                    try await model.update(family, success: String(localized: "Saved.")) { api in
                        try await api.perform(.patch, "/household/people/\(person.id)", body: input)
                    }
                }
            }
        }
        .sheet(item: $sharedLink) { link in
            FamilyInviteLinkSheet(link: link)
        }
        .familyConfirmation($confirmation)
    }

    // MARK: Account

    @ViewBuilder
    private func memberSections(_ member: FamilyMember, household: FamilyHousehold) -> some View {
        let canManage = household.canEdit && member.userId != household.selfId
        Section {
            if !member.name.isEmpty {
                LabeledContent("Name", value: member.name)
            }
            LabeledContent("Email", value: member.email)
        }

        Section {
            Button {
                sheet = .birthday(member)
            } label: {
                birthdayRow(member.birthday)
            }
            .tint(.primary)
            if canManage {
                FamilyRolePicker(title: "Role", role: Binding(get: { member.role }, set: { setRole(member, $0) }))
            } else {
                LabeledContent("Role") { Text(member.role.title) }
            }
        }

        if canManage {
            Section {
                Button("Remove from the family", role: .destructive) {
                    confirmation = FamilyConfirmation(
                        title: String(localized: "Remove \(member.label) from the family?"),
                        button: String(localized: "Remove")
                    ) { remove("/household/members/\(member.userId)", refreshApp: true) }
                }
            }
        }
    }

    // MARK: Without an account

    @ViewBuilder
    private func personSections(_ person: FamilyPerson, household: FamilyHousehold) -> some View {
        Section {
            Button {
                sheet = .editPerson(person)
            } label: {
                LabeledContent("Name", value: person.name)
            }
            .tint(.primary)
            Button {
                sheet = .editPerson(person)
            } label: {
                birthdayRow(person.birthday)
            }
            .tint(.primary)
        }

        Section {
            if let invite = household.invite(for: person) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.url)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(household.details(of: invite))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let link = invite.link {
                    ShareLink(item: link) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    confirmation = FamilyConfirmation(
                        title: String(localized: "Revoke the invite link for \(person.name)?"),
                        button: String(localized: "Revoke"),
                        message: String(localized: "Whoever has it can’t join with it anymore.")
                    ) {
                        remove("/household/invites/\(invite.id)", refreshApp: false,
                               success: String(localized: "Invite link revoked."))
                    }
                } label: {
                    Label("Revoke", systemImage: "link.badge.minus")
                }
            } else {
                Menu {
                    ForEach([FamilyRole.editor, .viewer], id: \.self) { role in
                        Button {
                            createInvite(role: role, person: person)
                        } label: {
                            Text(role.title)
                        }
                    }
                } label: {
                    Label("Create invite link", systemImage: "link.badge.plus")
                }
            }
        } header: {
            Text("Invite link")
        } footer: {
            Text("With the link, \(person.name) signs in with a new account or their existing one and keeps their birthday. Valid for 7 days, once.")
        }

        Section {
            Button("Remove from the family", role: .destructive) {
                confirmation = FamilyConfirmation(
                    title: String(localized: "Remove \(person.name) from the family?"),
                    button: String(localized: "Remove")
                ) { remove("/household/people/\(person.id)", refreshApp: false) }
            }
        }
    }

    private func birthdayRow(_ birthday: Day?) -> some View {
        LabeledContent("Birthday") {
            if let birthday {
                Text(FamilyBirthdays.text(birthday))
            } else {
                Text("Not set")
            }
        }
    }

    // MARK: Changes

    private func setRole(_ member: FamilyMember, _ role: FamilyRole) {
        guard role != member.role else { return }
        let api = family.api
        model.change(family, success: String(localized: "Role changed.")) {
            try await api.perform(.patch, "/household/members/\(member.userId)", body: FamilyRoleInput(role: role))
        }
    }

    private func remove(_ path: String, refreshApp: Bool, success: String = String(localized: "Removed.")) {
        let api = family.api
        model.change(family, success: success) {
            try await api.perform(.delete, path)
            if refreshApp { await app.refresh() }
        }
    }

    private func createInvite(role: FamilyRole, person: FamilyPerson) {
        perform {
            if let url = try await model.createInvite(family, role: role, personId: person.id) {
                sharedLink = FamilySharedLink(url: url, name: person.name)
            }
        }
    }
}

enum FamilyMemberSheet: Identifiable {
    case birthday(FamilyMember)
    case editPerson(FamilyPerson)

    var id: String {
        switch self {
        case let .birthday(member): "birthday|\(member.userId)"
        case let .editPerson(person): "person|\(person.id)"
        }
    }
}

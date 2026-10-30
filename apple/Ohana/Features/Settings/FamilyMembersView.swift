import SwiftUI

/// Settings → Members (the web's members and invites cards): accounts with their role and
/// birthday, people without an account, and the open invite links. Editors change roles, add,
/// edit and remove; everyone sets their own birthday.
struct FamilyMembersView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    let model: FamilySettingsModel

    @State private var sheet: FamilyMembersSheet?
    @State private var confirmation: FamilyConfirmation?
    @State private var sharedLink: FamilySharedLink?

    var body: some View {
        Group {
            if let household = model.household {
                form(household)
            } else {
                ProgressView()
            }
        }
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("Members")
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .birthday(title, value, userId):
                FamilyBirthdaySheet(title: title, birthday: value) { birthday in
                    try await update { api in
                        try await api.perform(.patch, "/household/members/\(userId)", body: FamilyBirthdayInput(birthday: birthday))
                    }
                }
            case .addPerson:
                FamilyPersonSheet(person: nil) { input in
                    let added: FamilyAddedPerson = try await family.api.send(.post, "/household/people", body: input)
                    await reload()
                    if let invite = added.invite, let url = URL(string: invite.url) {
                        sharedLink = FamilySharedLink(url: url, name: added.person.name)
                    }
                }
            case let .editPerson(person):
                FamilyPersonSheet(person: person) { input in
                    try await update { api in
                        try await api.perform(.patch, "/household/people/\(person.id)", body: input)
                    }
                }
            case .addByEmail:
                FamilyAddByEmailSheet { input in
                    try await update { api in
                        try await api.perform(.post, "/household/members", body: input)
                    }
                    await app.refresh()
                }
            }
        }
        .sheet(item: $sharedLink) { link in
            FamilyInviteLinkSheet(link: link)
        }
        .familyConfirmation($confirmation)
    }

    private func form(_ household: FamilyHousehold) -> some View {
        Form {
            Section {
                ForEach(household.members) { member in
                    memberRow(member, household: household)
                }
                ForEach(household.people) { person in
                    personRow(person, household: household)
                }
            } header: {
                Text("Members")
            }

            if household.canEdit {
                Section {
                    Button {
                        sheet = .addPerson
                    } label: {
                        Label("Add a person", systemImage: "person.badge.plus")
                    }
                    Button {
                        sheet = .addByEmail
                    } label: {
                        Label("Add by email", systemImage: "at")
                    }
                } footer: {
                    Text("For someone without an account, like a child. You can create an invite link for them now or later. Someone with an Ohana account already is added by email.")
                }

                Section {
                    if household.invites.isEmpty {
                        Text("No open invite links.").foregroundStyle(.secondary)
                    }
                    ForEach(household.invites) { invite in
                        inviteRow(invite, household: household)
                    }
                    Menu {
                        ForEach([FamilyRole.editor, .viewer], id: \.self) { role in
                            Button {
                                createInvite(role: role, personId: nil, name: nil)
                            } label: {
                                Text(role.title)
                            }
                        }
                    } label: {
                        Label("Create invite link", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("Invite links")
                } footer: {
                    Text("The link lets someone join the family, with a new account or their existing one. Valid for 7 days, once.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .refreshable { await reload() }
    }

    // MARK: Rows

    private func memberRow(_ member: FamilyMember, household: FamilyHousehold) -> some View {
        let isSelf = member.userId == household.selfId
        let canBirthday = household.canEdit || isSelf
        let canManage = household.canEdit && !isSelf
        return HStack(spacing: 12) {
            FamilyAvatar(name: member.label, tint: .ohana)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(member.label).fontWeight(.medium).lineLimit(1)
                    if isSelf { Text("(you)").foregroundStyle(.secondary) }
                }
                let details = [member.name.isEmpty ? nil : member.email,
                               member.birthday.map { FamilyBirthdays.text($0) }].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(member.role.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if canBirthday {
                Menu {
                    memberActions(member, canManage: canManage)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(Text("Actions for \(member.label)"))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
        .contextMenu {
            if canBirthday { memberActions(member, canManage: canManage) }
        }
    }

    @ViewBuilder
    private func memberActions(_ member: FamilyMember, canManage: Bool) -> some View {
        Button {
            sheet = .birthday(title: member.label, value: member.birthday, userId: member.userId)
        } label: {
            Label("Set birthday", systemImage: "birthday.cake")
        }
        if canManage {
            Picker(selection: Binding(get: { member.role }, set: { setRole(member, $0) })) {
                ForEach([FamilyRole.editor, .viewer], id: \.self) { role in
                    Text(role.title).tag(role)
                }
            } label: {
                Label("Role", systemImage: "person.badge.key")
            }
            Divider()
            Button(role: .destructive) {
                confirmation = FamilyConfirmation(
                    title: String(localized: "Remove \(member.label) from the family?"),
                    button: String(localized: "Remove")
                ) { remove("/household/members/\(member.userId)", refreshApp: true) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func personRow(_ person: FamilyPerson, household: FamilyHousehold) -> some View {
        let invite = household.invite(for: person)
        return HStack(spacing: 12) {
            FamilyAvatar(name: person.name, tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).fontWeight(.medium).lineLimit(1)
                let status = invite == nil ? String(localized: "No account") : String(localized: "Invite link open")
                Text(([status] + [person.birthday.map { FamilyBirthdays.text($0) }].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let link = invite?.link {
                ShareLink(item: link) {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel(Text("Share invite link"))
                }
                .buttonStyle(.borderless)
            }
            if household.canEdit {
                Menu {
                    personActions(person)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel(Text("Actions for \(person.name)"))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
        .contextMenu {
            if household.canEdit { personActions(person) }
        }
    }

    @ViewBuilder
    private func personActions(_ person: FamilyPerson) -> some View {
        Button {
            sheet = .editPerson(person)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Menu {
            ForEach([FamilyRole.editor, .viewer], id: \.self) { role in
                Button {
                    createInvite(role: role, personId: person.id, name: person.name)
                } label: {
                    Text(role.title)
                }
            }
        } label: {
            Label("Invite", systemImage: "link")
        }
        Divider()
        Button(role: .destructive) {
            confirmation = FamilyConfirmation(
                title: String(localized: "Remove \(person.name) from the family?"),
                button: String(localized: "Remove")
            ) { remove("/household/people/\(person.id)", refreshApp: false) }
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func inviteRow(_ invite: FamilyInvite, household: FamilyHousehold) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.url)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(inviteDetails(invite, household: household))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let link = invite.link {
                ShareLink(item: link) {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel(Text("Share invite link"))
                }
                .buttonStyle(.borderless)
            }
            Button("Revoke", role: .destructive) {
                remove("/household/invites/\(invite.id)", refreshApp: false)
            }
            .buttonStyle(.borderless)
        }
    }

    private func inviteDetails(_ invite: FamilyInvite, household: FamilyHousehold) -> String {
        var parts: [String] = []
        if let person = household.person(invite.personId) { parts.append(String(localized: "for \(person.name)")) }
        parts.append(invite.role == .editor ? String(localized: "Editor") : String(localized: "Viewer"))
        if let date = invite.expiryDate {
            parts.append(String(localized: "valid until \(date.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Changes

    private func reload() async { await model.load(family.api) }

    /// A change from a sheet: thrown errors stay in the sheet.
    private func update(_ action: (FamilyAPI) async throws -> Void) async throws {
        try await action(family.api)
        await reload()
        family.didChange(.family)
    }

    private func setRole(_ member: FamilyMember, _ role: FamilyRole) {
        guard role != member.role else { return }
        let api = family.api
        model.change(family) {
            try await api.perform(.patch, "/household/members/\(member.userId)", body: FamilyRoleInput(role: role))
        }
    }

    private func remove(_ path: String, refreshApp: Bool) {
        let api = family.api
        model.change(family) {
            try await api.perform(.delete, path)
            if refreshApp { await app.refresh() }
        }
    }

    private func createInvite(role: FamilyRole, personId: String?, name: String?) {
        let api = family.api
        perform {
            let invite: FamilyNewInvite = try await api.send(.post, "/household/invites",
                                                              body: FamilyInviteInput(role: role, personId: personId))
            await reload()
            if let url = URL(string: invite.url) { sharedLink = FamilySharedLink(url: url, name: name) }
        }
    }
}

enum FamilyMembersSheet: Identifiable {
    case birthday(title: String, value: Day?, userId: String)
    case addPerson
    case editPerson(FamilyPerson)
    case addByEmail

    var id: String {
        switch self {
        case let .birthday(_, _, userId): "birthday|\(userId)"
        case .addPerson: "addPerson"
        case let .editPerson(person): "person|\(person.id)"
        case .addByEmail: "addByEmail"
        }
    }
}

/// A new invite link to hand on.
struct FamilySharedLink: Identifiable {
    let url: URL
    /// Whom it is for (a member without an account).
    var name: String?
    var id: String { url.absoluteString }
}

/// The initials of a name in a round glass badge.
struct FamilyAvatar: View {
    let name: String
    var tint: Color = .ohana

    private var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A destructive action waiting for its confirmation.
struct FamilyConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let button: String
    var message: String?
    let action: () -> Void

    init(title: String, button: String, message: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.button = button
        self.message = message
        self.action = action
    }
}

extension View {
    /// Asks before a `FamilyConfirmation`'s action.
    func familyConfirmation(_ item: Binding<FamilyConfirmation?>) -> some View {
        confirmationDialog(
            Text(item.wrappedValue?.title ?? ""),
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { confirmation in
            Button(confirmation.button, role: .destructive) { confirmation.action() }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            if let message = confirmation.message { Text(message) }
        }
    }
}

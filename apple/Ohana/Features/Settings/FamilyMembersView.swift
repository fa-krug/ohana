import SwiftUI

/// Settings → Members (the web's members and invites cards): accounts with their role and
/// birthday, people without an account, and the open invite links. A member's row opens their
/// page (`FamilyMemberPage`) where editors change roles, edit and remove, and everyone sets
/// their own birthday; editors add people and create invite links here.
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
            case .addPerson:
                FamilyPersonSheet(person: nil) { input in
                    let added: FamilyAddedPerson = try await family.api.send(.post, "/household/people", body: input)
                    await reload()
                    if let invite = added.invite, let url = URL(string: invite.url) {
                        sharedLink = FamilySharedLink(url: url, name: added.person.name)
                    }
                }
            case .addByEmail:
                FamilyAddByEmailSheet { input in
                    try await model.update(family, success: String(localized: "Added.")) { api in
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
                                createInvite(role: role)
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

    /// A member's row; opens their page when there's something to change (editors: anyone,
    /// everyone: their own birthday).
    @ViewBuilder
    private func memberRow(_ member: FamilyMember, household: FamilyHousehold) -> some View {
        let isSelf = member.userId == household.selfId
        if household.canEdit || isSelf {
            NavigationLink {
                FamilyMemberPage(model: model, subject: .member(member.userId)).assistantButton()
            } label: {
                memberLabel(member, isSelf: isSelf)
            }
        } else {
            memberLabel(member, isSelf: isSelf)
        }
    }

    private func memberLabel(_ member: FamilyMember, isSelf: Bool) -> some View {
        HStack(spacing: 12) {
            FamilyAvatar(name: member.label, tint: .ohana)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelf ? String(localized: "\(member.label) (you)") : member.label)
                    .fontWeight(.medium)
                    .lineLimit(2)
                // The role in words beside the email: it wraps with the rest at large text sizes.
                let role = member.role == .editor ? String(localized: "Editor") : String(localized: "Viewer")
                let details = [role, member.name.isEmpty ? nil : member.email,
                               member.birthday.map { FamilyBirthdays.text($0) }].compactMap { $0 }
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// A member without an account; editors open their page.
    @ViewBuilder
    private func personRow(_ person: FamilyPerson, household: FamilyHousehold) -> some View {
        if household.canEdit {
            NavigationLink {
                FamilyMemberPage(model: model, subject: .person(person.id)).assistantButton()
            } label: {
                personLabel(person, household: household)
            }
        } else {
            personLabel(person, household: household)
        }
    }

    private func personLabel(_ person: FamilyPerson, household: FamilyHousehold) -> some View {
        HStack(spacing: 12) {
            FamilyAvatar(name: person.name, tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).fontWeight(.medium).lineLimit(2)
                let status = household.invite(for: person) == nil
                    ? String(localized: "No account") : String(localized: "Invite link open")
                Text(([status] + [person.birthday.map { FamilyBirthdays.text($0) }].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
                Text(household.details(of: invite))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let link = invite.link {
                ShareLink(item: link) {
                    Image(systemName: "square.and.arrow.up")
                        .rowHitTarget()
                        .accessibilityLabel(Text("Share invite link"))
                }
                .buttonStyle(.borderless)
            }
            Button(role: .destructive) {
                let person = household.person(invite.personId)
                confirmation = FamilyConfirmation(
                    title: person.map { String(localized: "Revoke the invite link for \($0.name)?") }
                        ?? String(localized: "Revoke this invite link?"),
                    button: String(localized: "Revoke"),
                    message: String(localized: "Whoever has it can’t join with it anymore.")
                ) {
                    revoke(invite)
                }
            } label: {
                Text("Revoke").rowHitTarget()
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Changes

    private func reload() async { await model.load(family.api) }

    private func revoke(_ invite: FamilyInvite) {
        let api = family.api
        model.change(family, success: String(localized: "Invite link revoked.")) {
            try await api.perform(.delete, "/household/invites/\(invite.id)")
        }
    }

    private func createInvite(role: FamilyRole) {
        perform {
            if let url = try await model.createInvite(family, role: role, personId: nil) {
                sharedLink = FamilySharedLink(url: url)
            }
        }
    }
}

enum FamilyMembersSheet: Identifiable {
    case addPerson
    case addByEmail

    var id: Self { self }
}

extension FamilyHousehold {
    /// "for Hanna · Viewer · valid until 8 Nov 2026"
    func details(of invite: FamilyInvite) -> String {
        var parts: [String] = []
        if let person = person(invite.personId) { parts.append(String(localized: "for \(person.name)")) }
        parts.append(invite.role == .editor ? String(localized: "Editor") : String(localized: "Viewer"))
        if let date = invite.expiryDate {
            parts.append(String(localized: "valid until \(date.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A new invite link to hand on.
struct FamilySharedLink: Identifiable {
    let url: URL
    /// Whom it is for (a member without an account).
    var name: String?
    var id: String { url.absoluteString }
}

/// The initials of a name in a round badge; grows with Dynamic Type.
struct FamilyAvatar: View {
    let name: String
    var tint: Color = .ohana
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 32

    private var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
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

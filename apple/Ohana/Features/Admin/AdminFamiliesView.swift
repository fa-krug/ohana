import SwiftUI

/// Administration → Families: every family of the server with its members (the web's
/// /admin/families). Create, rename, delete; members by email, their role, removing them.
struct AdminFamiliesView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[AdminFamily]> = .idle
    @State private var query = ""
    @State private var creating = false

    var body: some View {
        LoadStateView(state: state, retry: load) { families in
            Form {
                Section {
                    let shown = AdminRules.filter(families, query)
                    if shown.isEmpty {
                        Text("No families found.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { family in
                        NavigationLink(value: AdminFamilyRoute(id: family.id)) {
                            HStack(spacing: 12) {
                                TintedIcon(systemImage: "house.fill", tint: .ohana, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(family.name).fontWeight(.medium).lineLimit(2)
                                    Text(family.members.isEmpty ? String(localized: "No members.")
                                                                : family.members.map(\.displayName).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Being an administrator doesn’t open a family: add yourself as a member for that.")
                }
            }
            .formStyle(.grouped)
            .searchable(text: $query, prompt: Text("Search families"))
        }
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(for: AdminFamilyRoute.self) { route in
            AdminFamilyDetailView(familyID: route.id, families: $state)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New family", systemImage: "plus") { creating = true }
            }
        }
        .sheet(isPresented: $creating) {
            AdminFamilyNameSheet(title: "New family", name: "") { name in
                guard let client = app.client else { return }
                let _: AdminCreatedFamily = try await client.send(.post, "/api/v1/admin/families", body: AdminFamilyNameInput(name: name))
                await load()
            }
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        await LoadState.run($state) { try await client.get("/api/v1/admin/families", as: AdminFamilyList.self).families }
    }
}

struct AdminFamilyRoute: Hashable {
    let id: String
}

/// One family: its name, members and deleting it.
struct AdminFamilyDetailView: View {
    let familyID: String
    @Binding var families: LoadState<[AdminFamily]>
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var renaming = false
    @State private var adding = false
    @State private var confirmation: AccountConfirmation?

    private var family: AdminFamily? { families.value?.first { $0.id == familyID } }

    var body: some View {
        Group {
            if let family {
                form(family)
            } else {
                ContentUnavailableView("Family not found", systemImage: "house")
            }
        }
        .navigationTitle(family?.name ?? "")
        .sheet(isPresented: $renaming) {
            if let family {
                AdminFamilyNameSheet(title: "Rename family", name: family.name) { name in
                    try await call(.patch, "", body: AdminFamilyNameInput(name: name))
                }
            }
        }
        .sheet(isPresented: $adding) {
            AdminAddMemberSheet { input in
                try await call(.post, "/members", body: input)
            }
        }
        .accountConfirmation($confirmation)
    }

    private func form(_ family: AdminFamily) -> some View {
        Form {
            Section {
                LabeledContent("Name", value: family.name)
                if let created = Date.server(family.createdAt) {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .omitted))
                }
                Button("Rename", systemImage: "pencil") { renaming = true }
            }
            Section {
                if family.members.isEmpty {
                    Text("No members.").foregroundStyle(.secondary)
                }
                ForEach(family.members) { member in
                    memberRow(member, family: family)
                }
                Button("Add member", systemImage: "person.badge.plus") { adding = true }
            } header: {
                Text("Members")
            } footer: {
                Text("A family always keeps an editor.")
            }
            Section {
                Button("Delete family", systemImage: "trash", role: .destructive) {
                    confirmation = AccountConfirmation(
                        title: String(localized: "Delete \(family.name) with everything in it?"),
                        button: String(localized: "Delete family"),
                        message: String(localized: "This can’t be undone.")
                    ) { delete(family) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func memberRow(_ member: AdminFamilyMember, family: AdminFamily) -> some View {
        // Name, role and remove in a row; the controls go under the name at accessibility sizes.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                AdminInitials(name: member.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.userId == app.me?.id ? String(localized: "\(member.displayName) (you)") : member.displayName)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    if !member.name.isEmpty {
                        Text(member.email).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                Picker("Role", selection: Binding(get: { member.role }, set: { setRole(member, $0) })) {
                    ForEach([FamilyRole.editor, .viewer], id: \.self) { Text(AdminText.role($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!AdminRules.canChangeRole(of: member, in: family))
                .accessibilityLabel(Text("Role of \(member.displayName)"))
                Button(role: .destructive) {
                    confirmation = AccountConfirmation(
                        title: String(localized: "Remove \(member.displayName) from \(family.name)?"),
                        button: String(localized: "Remove")
                    ) { remove(member) }
                } label: {
                    Image(systemName: "person.badge.minus")
                        .rowHitTarget()
                        .accessibilityLabel(Text("Remove \(member.displayName)"))
                }
                .buttonStyle(.borderless)
                .disabled(!AdminRules.canRemove(member, from: family))
            }
        }
    }

    // MARK: Changes

    /// A call on `/api/v1/admin/families/{id}{sub}`, then the list reloads (and the account's
    /// own families, which this may have changed).
    private func call(_ method: HTTPMethod, _ sub: String, body: some Encodable) async throws {
        guard let client = app.client else { return }
        let _: JSONValue = try await client.send(method, "/api/v1/admin/families/\(familyID)\(sub)", body: body)
        await reload()
    }

    private func reload() async {
        guard let client = app.client else { return }
        await LoadState.run($families) { try await client.get("/api/v1/admin/families", as: AdminFamilyList.self).families }
        await app.refresh()
    }

    private func setRole(_ member: AdminFamilyMember, _ role: FamilyRole) {
        guard role != member.role else { return }
        perform { try await call(.patch, "/members/\(member.userId)", body: AdminRoleInput(role: role)) }
    }

    private func remove(_ member: AdminFamilyMember) {
        guard let client = app.client else { return }
        perform {
            let _: JSONValue = try await client.send(.delete, "/api/v1/admin/families/\(familyID)/members/\(member.userId)")
            await reload()
        }
    }

    private func delete(_ family: AdminFamily) {
        guard let client = app.client else { return }
        perform {
            let _: JSONValue = try await client.send(.delete, "/api/v1/admin/families/\(family.id)")
            ErrorBanner.shared.success(String(localized: "Family deleted."))
            dismiss()
            await reload()
        }
    }
}

/// A family's name: new or renamed.
struct AdminFamilyNameSheet: View {
    let title: LocalizedStringKey
    let save: (String) async throws -> Void
    private let original: String
    @State private var name: String

    init(title: LocalizedStringKey, name: String, save: @escaping (String) async throws -> Void) {
        self.title = title
        self.save = save
        original = name
        _name = State(initialValue: name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AccountSheetForm(title: title, confirmTitle: original.isEmpty ? "Create" : "Save",
                         canSave: !trimmed.isEmpty && trimmed.count <= 100 && trimmed != original,
                         hasChanges: trimmed != original,
                         save: { try await save(trimmed) }) {
            Section {
                TextField("Family name", text: $name, prompt: Text("e.g. The Krugs"))
            } footer: {
                if trimmed.count > 100 {
                    Text("The name is too long (max. 100).").foregroundStyle(.red)
                } else if original.isEmpty {
                    Text("The family starts without members: add them afterwards.")
                }
            }
        }
    }
}

/// Adding an account to a family by its email, with a role.
struct AdminAddMemberSheet: View {
    let save: (AdminMemberInput) async throws -> Void
    @State private var email = ""
    @State private var role: FamilyRole = .editor

    private var trimmed: String { email.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        AccountSheetForm(title: "Add member", confirmTitle: "Add", canSave: !trimmed.isEmpty, hasChanges: !trimmed.isEmpty,
                         save: { try await save(AdminMemberInput(email: trimmed, role: role)) }) {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Picker("Role", selection: $role) {
                    ForEach([FamilyRole.editor, .viewer], id: \.self) { Text(AdminText.role($0)).tag($0) }
                }
            } footer: {
                Text("Someone with an Ohana account: the email they sign in with.")
            }
        }
    }
}

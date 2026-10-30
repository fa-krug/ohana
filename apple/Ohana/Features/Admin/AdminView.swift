import SwiftUI

/// Administration (the web's /admin): users and families, for administrators. Pushed from the
/// account screen on iPhone and iPad; a sheet from the family menu and on the Mac (`AdminSheet`).
struct AdminView: View {
    enum Tab: String, Hashable, CaseIterable {
        case users, families
        var title: LocalizedStringKey { self == .users ? "Users" : "Families" }
    }

    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .users

    var body: some View {
        Group {
            if app.me?.isAdmin == true {
                switch tab {
                case .users: AdminUsersView()
                case .families: AdminFamiliesView()
                }
            } else {
                ContentUnavailableView("Administrators only", systemImage: "lock",
                                       description: Text("Your account can’t manage this server."))
            }
        }
        .navigationTitle("Administration")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

/// Administration in its own sheet, with Done.
struct AdminSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AdminView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .errorBanner()
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 640)
        #endif
    }
}

// MARK: - Users

struct AdminUsersView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[AdminUser]> = .idle
    @State private var query = ""
    @State private var editing: AdminUserEdit?
    @State private var link: AdminSetupLinkItem?
    /// A new account's link, shown once its sheet is gone.
    @State private var pendingLink: AdminSetupLinkItem?
    @State private var confirmation: AccountConfirmation?

    var body: some View {
        LoadStateView(state: state, retry: load) { users in
            Form {
                Section {
                    let shown = AdminRules.filter(users, query)
                    if shown.isEmpty {
                        Text("No users found.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { user in
                        row(user)
                    }
                } footer: {
                    Text("New accounts come with a one-time setup link (7 days): it signs the person in and asks for a passkey or a password.")
                }
            }
            .formStyle(.grouped)
            .searchable(text: $query, prompt: Text("Search users"))
        }
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New user", systemImage: "person.badge.plus") { editing = AdminUserEdit(user: nil) }
            }
        }
        .sheet(item: $editing, onDismiss: {
            link = pendingLink
            pendingLink = nil
        }) { edit in
            AdminUserSheet(user: edit.user, isSelf: edit.user.map { AdminRules.isSelf($0, me: app.me) } ?? false) { input in
                try await save(input, for: edit.user)
            }
        }
        .sheet(item: $link) { link in
            AccountSecretSheet(title: link.isNew ? "User created" : "New setup link", systemImage: "link",
                               subtitle: link.name, secret: link.url,
                               message: "Send them the setup link: it works once, for 7 days, and lets them add a passkey or set a password.")
        }
        .accountConfirmation($confirmation)
    }

    private func row(_ user: AdminUser) -> some View {
        let isSelf = AdminRules.isSelf(user, me: app.me)
        return HStack(spacing: 12) {
            AdminInitials(name: user.displayName, tint: user.isAdmin ? .ohana : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelf ? String(localized: "\(user.displayName) (you)") : user.displayName)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if user.isAdmin {
                    Text("Admin")
                        .font(.caption2.weight(.semibold))
                        .chip(tint: .ohana)
                }
                if !user.name.isEmpty {
                    Text(user.email).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(AdminText.details(user))
                    .font(.caption)
                    .foregroundStyle(user.isPending ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                actions(user, isSelf: isSelf)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .rowHitTarget()
                    .accessibilityLabel(Text("Actions for \(user.displayName)"))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .contentShape(.rect)
        .onTapGesture { editing = AdminUserEdit(user: user) }
        .accessibilityAction(named: Text("Edit")) { editing = AdminUserEdit(user: user) }
        .contextMenu { actions(user, isSelf: isSelf) }
    }

    @ViewBuilder
    private func actions(_ user: AdminUser, isSelf: Bool) -> some View {
        Button("Edit", systemImage: "pencil") { editing = AdminUserEdit(user: user) }
        Button("New setup link", systemImage: "link.badge.plus") {
            confirmation = AccountConfirmation(
                title: String(localized: "Make a new setup link for \(user.displayName)?"),
                button: String(localized: "New setup link"),
                message: String(localized: "It signs them out everywhere and lets them set a new password, e.g. when they forgot it.")
            ) { newSetupLink(user) }
        }
        if !isSelf {
            Divider()
            Button("Delete user", systemImage: "trash", role: .destructive) {
                confirmation = AccountConfirmation(
                    title: String(localized: "Delete the account of \(user.displayName)?"),
                    button: String(localized: "Delete user"),
                    message: String(localized: "Their families stay.")
                ) { delete(user) }
            }
        }
    }

    private func load() async {
        guard let client = app.client else { return }
        await LoadState.run($state) { try await client.get("/api/v1/admin/users", as: AdminUserList.self).users }
    }

    /// Creates or saves from the sheet (errors stay in the sheet).
    private func save(_ input: AdminUserEdit.Input, for user: AdminUser?) async throws {
        guard let client = app.client else { return }
        if let user {
            let _: JSONValue = try await client.send(.patch, "/api/v1/admin/users/\(user.id)",
                                                     body: AdminUserUpdateInput(email: input.email, name: input.name, isAdmin: input.isAdmin))
            ErrorBanner.shared.success(String(localized: "User saved."))
            if AdminRules.isSelf(user, me: app.me) { await app.refresh() }
        } else {
            let created: AdminCreatedUser = try await client.send(.post, "/api/v1/admin/users",
                                                                  body: AdminNewUserInput(email: input.email, name: input.name, isAdmin: input.isAdmin))
            pendingLink = AdminSetupLinkItem(url: created.setupUrl, name: input.name.isEmpty ? input.email : input.name, isNew: true)
        }
        await load()
    }

    private func newSetupLink(_ user: AdminUser) {
        guard let client = app.client else { return }
        perform {
            let result: AdminSetupLink = try await client.send(.post, "/api/v1/admin/users/\(user.id)/setup-link")
            link = AdminSetupLinkItem(url: result.setupUrl, name: user.displayName, isNew: false)
        }
    }

    private func delete(_ user: AdminUser) {
        guard let client = app.client else { return }
        perform {
            let _: JSONValue = try await client.send(.delete, "/api/v1/admin/users/\(user.id)")
            ErrorBanner.shared.success(String(localized: "User deleted."))
            await load()
        }
    }
}

/// The user sheet's subject: nil for a new one.
struct AdminUserEdit: Identifiable {
    let id = UUID()
    let user: AdminUser?

    struct Input {
        let email: String
        let name: String
        let isAdmin: Bool
    }
}

/// A new account (email, name, administrator) or editing one.
struct AdminUserSheet: View {
    let user: AdminUser?
    let isSelf: Bool
    let save: (AdminUserEdit.Input) async throws -> Void
    @State private var email: String
    @State private var name: String
    @State private var isAdmin: Bool

    init(user: AdminUser?, isSelf: Bool, save: @escaping (AdminUserEdit.Input) async throws -> Void) {
        self.user = user
        self.isSelf = isSelf
        self.save = save
        _email = State(initialValue: user?.email ?? "")
        _name = State(initialValue: user?.name ?? "")
        _isAdmin = State(initialValue: user?.isAdmin ?? false)
    }

    private var input: AdminUserEdit.Input {
        AdminUserEdit.Input(email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                            name: name.trimmingCharacters(in: .whitespaces), isAdmin: isAdmin)
    }

    private var changed: Bool {
        input.email != (user?.email ?? "") || input.name != (user?.name ?? "") || input.isAdmin != (user?.isAdmin ?? false)
    }

    var body: some View {
        AccountSheetForm(title: user == nil ? "New user" : "Edit user", confirmTitle: user == nil ? "Create" : "Save",
                         canSave: !input.email.isEmpty && input.name.count <= 100 && changed,
                         hasChanges: changed,
                         save: { try await save(input) }) {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("Name", text: $name)
                    .textContentType(.name)
            }
            Section {
                Toggle("Administrator", isOn: $isAdmin)
                    .disabled(isSelf)
            } footer: {
                if isSelf {
                    Text("You can’t remove your own administrator rights.")
                } else if user == nil {
                    Text("The new account comes with a one-time setup link (7 days): it signs the person in and asks for a passkey or a password.")
                } else {
                    Text("Administrators manage the users and families of this server.")
                }
            }
        }
    }
}

/// The initials of a name in a round badge; grows with Dynamic Type.
struct AdminInitials: View {
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

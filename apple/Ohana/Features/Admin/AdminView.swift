import SwiftUI

/// Administration (the web's /admin): users and families, for administrators. Pushed from the
/// settings; a sheet while the account has no family (`AdminSheet`).
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

    private var calls: AdminUserCalls { AdminUserCalls(app: app, users: $state) }

    var body: some View {
        LoadStateView(state: state, retry: calls.load) { users in
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
        .task { await calls.load() }
        .refreshable { await calls.load() }
        .navigationDestination(for: AdminUserRoute.self) { route in
            AdminUserDetailView(userID: route.id, users: $state)
        }
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
                if let user = edit.user {
                    try await calls.update(user, input)
                } else {
                    pendingLink = try await calls.create(input)
                }
            }
        }
        .sheet(item: $link) { AdminSetupLinkSheet(link: $0) }
        .accountConfirmation($confirmation)
    }

    /// Opens the user's page; the same actions on a right-click / long press.
    private func row(_ user: AdminUser) -> some View {
        let isSelf = AdminRules.isSelf(user, me: app.me)
        return NavigationLink(value: AdminUserRoute(id: user.id)) {
            HStack(spacing: 12) {
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
            }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = AdminUserEdit(user: user) }
            Button("New setup link", systemImage: "link.badge.plus") {
                confirmation = .newSetupLink(for: user) {
                    perform { link = try await calls.newSetupLink(user) }
                }
            }
            if !isSelf {
                Divider()
                Button("Delete user", systemImage: "trash", role: .destructive) {
                    confirmation = .delete(user) {
                        perform { try await calls.delete(user) }
                    }
                }
            }
        }
    }
}

struct AdminUserRoute: Hashable {
    let id: String
}

/// One account: its details, editing it, a new setup link and deleting it. It shows what
/// `users` holds, so it follows the reloads, and closes once the account is gone.
struct AdminUserDetailView: View {
    let userID: String
    @Binding var users: LoadState<[AdminUser]>
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var link: AdminSetupLinkItem?
    @State private var confirmation: AccountConfirmation?

    private var calls: AdminUserCalls { AdminUserCalls(app: app, users: $users) }
    private var user: AdminUser? { users.value?.first { $0.id == userID } }
    private var gone: Bool { users.value != nil && user == nil }

    var body: some View {
        Group {
            if let user {
                form(user)
            }
        }
        .navigationTitle(user?.displayName ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: gone, initial: true) { if gone { dismiss() } }
        .sheet(isPresented: $editing) {
            if let user {
                AdminUserSheet(user: user, isSelf: AdminRules.isSelf(user, me: app.me)) { input in
                    try await calls.update(user, input)
                }
            }
        }
        .sheet(item: $link) { AdminSetupLinkSheet(link: $0) }
        .accountConfirmation($confirmation)
    }

    private func form(_ user: AdminUser) -> some View {
        Form {
            Section {
                if !user.name.isEmpty {
                    LabeledContent("Name", value: user.name)
                }
                LabeledContent("Email", value: user.email)
                LabeledContent("Administrator", value: user.isAdmin ? String(localized: "Yes") : String(localized: "No"))
                if let created = Date.server(user.createdAt) {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .omitted))
                }
                Button("Edit", systemImage: "pencil") { editing = true }
            } footer: {
                Text(AdminText.details(user))
                    .foregroundStyle(user.isPending ? .orange : .secondary)
            }
            Section {
                Button("New setup link", systemImage: "link.badge.plus") {
                    confirmation = .newSetupLink(for: user) {
                        perform { link = try await calls.newSetupLink(user) }
                    }
                }
            }
            if !AdminRules.isSelf(user, me: app.me) {
                Section {
                    Button("Delete user", systemImage: "trash", role: .destructive) {
                        confirmation = .delete(user) {
                            perform { try await calls.delete(user) { dismiss() } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .refreshable { await calls.load() }
    }
}

/// The calls on the accounts, shared by the list and a user's page; each reloads the list.
struct AdminUserCalls {
    let app: AppModel
    @Binding var users: LoadState<[AdminUser]>

    func load() async {
        guard let client = app.client else { return }
        await LoadState.run($users) { try await client.get("/api/v1/admin/users", as: AdminUserList.self).users }
    }

    /// A new account from the sheet (errors stay in the sheet); its setup link.
    func create(_ input: AdminUserEdit.Input) async throws -> AdminSetupLinkItem? {
        guard let client = app.client else { return nil }
        let created: AdminCreatedUser = try await client.send(.post, "/api/v1/admin/users",
                                                              body: AdminNewUserInput(email: input.email, name: input.name, isAdmin: input.isAdmin))
        await load()
        return AdminSetupLinkItem(url: created.setupUrl, name: input.name.isEmpty ? input.email : input.name, isNew: true)
    }

    /// Saves the sheet's changes (errors stay in the sheet).
    func update(_ user: AdminUser, _ input: AdminUserEdit.Input) async throws {
        guard let client = app.client else { return }
        let _: JSONValue = try await client.send(.patch, "/api/v1/admin/users/\(user.id)",
                                                 body: AdminUserUpdateInput(email: input.email, name: input.name, isAdmin: input.isAdmin))
        if AdminRules.isSelf(user, me: app.me) { await app.refresh() }
        await load()
    }

    func newSetupLink(_ user: AdminUser) async throws -> AdminSetupLinkItem? {
        guard let client = app.client else { return nil }
        let result: AdminSetupLink = try await client.send(.post, "/api/v1/admin/users/\(user.id)/setup-link")
        return AdminSetupLinkItem(url: result.setupUrl, name: user.displayName, isNew: false)
    }

    /// Deletes the account; `deleted` runs before the list reloads (the user's page closes).
    func delete(_ user: AdminUser, deleted: () -> Void = {}) async throws {
        guard let client = app.client else { return }
        let _: JSONValue = try await client.send(.delete, "/api/v1/admin/users/\(user.id)")
        deleted()
        await load()
    }
}

extension AccountConfirmation {
    static func newSetupLink(for user: AdminUser, _ action: @escaping () -> Void) -> AccountConfirmation {
        AccountConfirmation(
            title: String(localized: "Make a new setup link for \(user.displayName)?"),
            button: String(localized: "New setup link"),
            message: String(localized: "It signs them out everywhere and lets them set a new password, e.g. when they forgot it."),
            action: action
        )
    }

    static func delete(_ user: AdminUser, _ action: @escaping () -> Void) -> AccountConfirmation {
        AccountConfirmation(
            title: String(localized: "Delete the account of \(user.displayName)?"),
            button: String(localized: "Delete user"),
            message: String(localized: "Their families stay."),
            action: action
        )
    }
}

/// A setup link to hand on: a new account's or a new one.
struct AdminSetupLinkSheet: View {
    let link: AdminSetupLinkItem

    var body: some View {
        AccountSecretSheet(title: link.isNew ? "User created" : "New setup link", systemImage: "link",
                           subtitle: link.name, secret: link.url,
                           message: "Send them the setup link: it works once, for 7 days, and lets them add a passkey or set a password.")
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

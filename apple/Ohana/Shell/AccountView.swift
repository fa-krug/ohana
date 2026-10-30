import SwiftUI

/// The account on this device (the web's /account): profile and language, email, password,
/// passkeys, API tokens, the signed-in browsers, appearance, administration for admins, and
/// signing out. The Mac's Settings window; a sheet on iPhone and iPad. Adding a passkey stays on
/// the web: a passkey belongs to the server's own domain.
struct AccountView: View {
    @AppStorage("appearance") private var appearance = Appearance.system

    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            if app.client == nil {
                ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Connect Ohana to your server first."))
            } else {
                AccountForm()
            }
        }
        .errorBanner()
        .preferredColorScheme(appearance.colorScheme)
    }
}

/// What a sheet of the account screen edits.
private enum AccountSheet: Identifiable {
    case email(String)
    case password(hasPassword: Bool)
    case removePassword
    case renamePasskey(AccountPasskey)
    case createToken

    var id: String {
        switch self {
        case .email: "email"
        case .password: "password"
        case .removePassword: "removePassword"
        case let .renamePasskey(passkey): "passkey|\(passkey.id)"
        case .createToken: "createToken"
        }
    }
}

private struct AccountForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system
    #if os(macOS)
    @AppStorage("menuBarAssistant") private var menuBarAssistant = true
    #endif

    @State private var state: LoadState<AccountOverview> = .idle
    @State private var name = ""
    @State private var sheet: AccountSheet?
    @State private var confirmation: AccountConfirmation?
    @State private var confirmSignOut = false
    @FocusState private var nameFocused: Bool

    private var user: UserAccount? { state.value?.user ?? app.me }

    var body: some View {
        Form {
            header

            if let overview = state.value {
                profileSection(overview.user)
                emailSection(overview.user)
                passwordSection(overview)
                passkeysSection(overview)
                tokensSection(overview)
                sessionsSection(overview)
            } else if case let .failed(message) = state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try again") { Task { await load() } }
                    webLink("Open the account page on the web", systemImage: "safari")
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }

            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                #if os(macOS)
                Toggle("Show the assistant in the menu bar", isOn: $menuBarAssistant)
                #endif
            } header: {
                Text("Appearance")
            } footer: {
                Text("Applies to this device only.")
            }

            if user?.isAdmin == true {
                Section {
                    NavigationLink {
                        AdminView()
                    } label: {
                        Label("Administration", systemImage: "person.badge.shield.checkmark")
                    }
                } footer: {
                    Text("Users and families of this server.")
                }
            }

            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            } footer: {
                Text("Signs this device out and deletes its token.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }
            }
            #endif
        }
        .task(id: app.me?.id) { await load() }
        .refreshable { await load() }
        .sheet(item: $sheet) { sheet in
            sheetView(sheet)
        }
        .accountConfirmation($confirmation)
        .confirmationDialog("Sign out of Ohana on this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    await app.signOut()
                    dismiss()
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                TintedIcon(systemImage: "person.fill", tint: .ohana, size: 44)
                VStack(alignment: .leading) {
                    Text(user?.displayName ?? "").font(.headline)
                    Text(user?.email ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let server = app.serverURL {
                LabeledContent("Server", value: server.host() ?? server.absoluteString)
            }
        }
    }

    private func profileSection(_ user: UserAccount) -> some View {
        Section {
            HStack {
                TextField("Name", text: $name, prompt: Text("Your name"))
                    .focused($nameFocused)
                    .onSubmit(saveName)
                    .submitLabel(.done)
                if AccountRules.trimmed(name) ?? "" != user.name {
                    Button("Save", action: saveName)
                        .buttonStyle(.glassProminent)
                        .disabled(name.count > 100)
                }
            }
            Picker("Language", selection: Binding(get: { user.preferredLanguage }, set: setLanguage)) {
                ForEach(AccountLanguage.allCases) { Text($0.title).tag($0.rawValue) }
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("The language of notifications and of what Ohana names for you, like a new family’s calendar types.")
        }
    }

    @ViewBuilder
    private func emailSection(_ user: UserAccount) -> some View {
        Section {
            LabeledContent("Email", value: user.email)
            if AccountRules.canChangeEmailHere(user) {
                Button("Change email…", systemImage: "envelope") { sheet = .email(user.email) }
            } else {
                webLink("Change email on the web", systemImage: "safari")
            }
        } header: {
            Text("Email")
        } footer: {
            if !AccountRules.canChangeEmailHere(user) {
                Text("Your account has no password, so the change is confirmed with a passkey. That works on the web page of your server.")
            }
        }
    }

    private func passwordSection(_ overview: AccountOverview) -> some View {
        Section {
            Text(overview.user.hasPassword ? "A password is set." : "No password: you sign in with passkeys only.")
                .foregroundStyle(.secondary)
            Button(overview.user.hasPassword ? "Change password…" : "Set a password…", systemImage: "key") {
                sheet = .password(hasPassword: overview.user.hasPassword)
            }
            if overview.user.hasPassword {
                Button("Remove password…", systemImage: "key.slash", role: .destructive) { sheet = .removePassword }
                    .disabled(!AccountRules.canRemovePassword(overview))
            }
        } header: {
            Text("Password")
        } footer: {
            if overview.user.hasPassword && !AccountRules.canRemovePassword(overview) {
                Text("Add a passkey before you remove the password: an account always keeps a way to sign in.")
            }
        }
    }

    private func passkeysSection(_ overview: AccountOverview) -> some View {
        Section {
            if overview.passkeys.isEmpty {
                Text("No passkeys yet.").foregroundStyle(.secondary)
            }
            ForEach(overview.passkeys) { passkey in
                passkeyRow(passkey, canDelete: AccountRules.canDeletePasskey(overview))
            }
            webLink("Add a passkey on the web", systemImage: "plus")
        } header: {
            Text("Passkeys")
        } footer: {
            Text("Sign in with your fingerprint, face or device PIN. A passkey belongs to your server’s web address, so new ones are added on its web page.")
        }
    }

    private func passkeyRow(_ passkey: AccountPasskey, canDelete: Bool) -> some View {
        let title = passkey.deviceName.isEmpty ? String(localized: "Passkey") : passkey.deviceName
        return HStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill").foregroundStyle(Color.ohana)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(AccountDates.line(created: passkey.createdDate, lastUsed: passkey.lastUsedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                passkeyActions(passkey, title: title, canDelete: canDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text("Actions for \(title)"))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .contextMenu { passkeyActions(passkey, title: title, canDelete: canDelete) }
    }

    @ViewBuilder
    private func passkeyActions(_ passkey: AccountPasskey, title: String, canDelete: Bool) -> some View {
        Button("Rename", systemImage: "pencil") { sheet = .renamePasskey(passkey) }
        Button("Delete", systemImage: "trash", role: .destructive) {
            confirmation = AccountConfirmation(
                title: String(localized: "Delete the passkey \(title)?"),
                button: String(localized: "Delete"),
                message: String(localized: "You can’t sign in with it anymore.")
            ) { deletePasskey(passkey) }
        }
        .disabled(!canDelete)
    }

    private func tokensSection(_ overview: AccountOverview) -> some View {
        Section {
            if overview.tokens.isEmpty {
                Text("No API tokens.").foregroundStyle(.secondary)
            }
            ForEach(AccountRules.sortedTokens(overview.tokens)) { token in
                tokenRow(token)
            }
            Button("Create token…", systemImage: "plus") { sheet = .createToken }
        } header: {
            Text("API tokens")
        } footer: {
            Text("Apps like this one sign in with a token, and so can scripts and AI agents (\"Authorization: Bearer <token>\"). A token can do everything you can.")
        }
    }

    private func tokenRow(_ token: AccountToken) -> some View {
        HStack(spacing: 12) {
            Image(systemName: token.current ? "iphone.gen3" : "key.horizontal")
                .foregroundStyle(token.current ? Color.ohana : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(token.name.isEmpty ? String(localized: "Token") : token.name).lineLimit(1)
                    if token.current {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.ohana.opacity(0.18), in: .capsule)
                    }
                }
                Text(AccountDates.line(created: token.createdDate, lastUsed: token.lastUsedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                confirmDelete(token)
            } label: {
                Image(systemName: "trash")
                    .accessibilityLabel(Text("Delete \(token.name)"))
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete(token) }
        }
    }

    private func sessionsSection(_ overview: AccountOverview) -> some View {
        Section {
            LabeledContent("Signed-in browsers", value: overview.sessions.formatted())
            Button("Sign out other devices", systemImage: "rectangle.portrait.and.arrow.right") {
                confirmation = AccountConfirmation(
                    title: String(localized: "Sign out the other devices?"),
                    button: String(localized: "Sign out"),
                    message: String(localized: "Every browser signed in to your account is signed out. This device and other apps stay signed in: delete their tokens above.")
                ) { signOutOthers() }
            }
            .disabled(overview.sessions == 0)
        } header: {
            Text("Other devices")
        }
    }

    private func webLink(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Button {
            if let url = app.webURL("/account") { openURL(url) }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: AccountSheet) -> some View {
        switch sheet {
        case let .email(current):
            AccountEmailSheet(current: current) { input in
                try await change(.put, "/api/v1/me/email", body: input, as: UserAccount.self)
                ErrorBanner.shared.success(String(localized: "Email updated."))
            }
        case let .password(hasPassword):
            AccountPasswordSheet(hasPassword: hasPassword) { input in
                try await change(.put, "/api/v1/me/password", body: input, as: UserAccount.self)
                ErrorBanner.shared.success(String(localized: "Password saved. Your browsers were signed out."))
            }
        case .removePassword:
            AccountRemovePasswordSheet { password in
                try await change(.delete, "/api/v1/me/password", body: AccountRemovePasswordInput(currentPassword: password),
                                 as: UserAccount.self)
                ErrorBanner.shared.success(String(localized: "Password removed."))
            }
        case let .renamePasskey(passkey):
            AccountPasskeyRenameSheet(passkey: passkey) { name in
                try await change(.patch, "/api/v1/me/passkeys/\(passkey.id)", body: AccountPasskeyRenameInput(deviceName: name),
                                 as: AccountPasskeyList.self)
                ErrorBanner.shared.success(String(localized: "Passkey renamed."))
            }
        case .createToken:
            AccountCreateTokenSheet { name in
                guard let client = app.client else { throw CancellationError() }
                let created: AccountNewToken = try await client.send(.post, "/api/v1/me/tokens", body: AccountTokenInput(name: name))
                await load()
                return created
            }
        }
    }

    // MARK: Changes

    private func load() async {
        guard let client = app.client else { return }
        await LoadState.run($state) { try await client.get("/api/v1/me/account") }
        if let user = state.value?.user, !nameFocused { name = user.name }
    }

    /// A change from a sheet (errors stay in the sheet); the account reloads, the app's too.
    private func change<T: Decodable>(_ method: HTTPMethod, _ path: String, body: some Encodable, as: T.Type) async throws {
        guard let client = app.client else { return }
        let _: T = try await client.send(method, path, body: body)
        await load()
        await app.refresh()
    }

    private func saveName() {
        guard let user, let client = app.client else { return }
        let new = AccountRules.trimmed(name) ?? ""
        guard new != user.name, new.count <= 100 else { return }
        nameFocused = false
        perform {
            let _: UserAccount = try await client.send(.patch, "/api/v1/me/profile", body: AccountProfileInput(name: new))
            ErrorBanner.shared.success(String(localized: "Name saved."))
            await load()
            await app.refresh()
        }
    }

    private func setLanguage(_ language: String) {
        guard let client = app.client, language != user?.preferredLanguage else { return }
        perform {
            let _: UserAccount = try await client.send(.patch, "/api/v1/me/profile", body: AccountProfileInput(preferredLanguage: language))
            await load()
            await app.refresh()
        }
    }

    private func deletePasskey(_ passkey: AccountPasskey) {
        guard let client = app.client else { return }
        perform {
            let _: AccountPasskeyList = try await client.send(.delete, "/api/v1/me/passkeys/\(passkey.id)")
            ErrorBanner.shared.success(String(localized: "Passkey removed."))
            await load()
            await app.refresh()
        }
    }

    /// Deleting the device's own token signs the app out: that is said before, not found after.
    private func confirmDelete(_ token: AccountToken) {
        if token.current {
            confirmation = AccountConfirmation(
                title: String(localized: "Delete this device’s token?"),
                button: String(localized: "Delete and sign out"),
                message: String(localized: "Ohana on this device signs in with it: you are signed out right away and pair the app again to come back.")
            ) { deleteToken(token) }
        } else {
            confirmation = AccountConfirmation(
                title: String(localized: "Delete the token \(token.name)?"),
                button: String(localized: "Delete"),
                message: String(localized: "Whatever uses it can’t sign in anymore.")
            ) { deleteToken(token) }
        }
    }

    private func deleteToken(_ token: AccountToken) {
        guard let client = app.client else { return }
        perform {
            let result: AccountTokenDeleted = try await client.send(.delete, "/api/v1/me/tokens/\(token.id)")
            if result.signedOut {
                await app.signOut()
                dismiss()
                return
            }
            ErrorBanner.shared.success(String(localized: "Token deleted."))
            await load()
        }
    }

    private func signOutOthers() {
        guard let client = app.client else { return }
        perform {
            let _: JSONValue = try await client.send(.delete, "/api/v1/me/sessions")
            ErrorBanner.shared.success(String(localized: "Other devices signed out."))
            await load()
        }
    }
}

/// Light / dark / system, per device (the web app's lib/theme.ts).
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

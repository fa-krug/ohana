import SwiftUI

/// The account on this device (the web's /account): profile and language, email, password,
/// passkeys, the signed-in devices and browsers, appearance, administration for admins, signing
/// out, and (under Advanced) API tokens for scripts. On the Mac it's the Settings window (⌘,)
/// with toolbar tabs; on iPhone and iPad one grouped form in a sheet, the API tokens a page of
/// it. Adding a passkey stays on the web: a passkey belongs to the server's own domain.
struct AccountView: View {
    @AppStorage("appearance") private var appearance = Appearance.system

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.client == nil {
                ContentUnavailableView("Not signed in", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Connect Ohana to your server first."))
            } else {
                #if os(macOS)
                TabView {
                    Tab("General", systemImage: "gearshape") { AccountForm(page: .general) }
                    Tab("Account", systemImage: "person.crop.circle") { AccountForm(page: .account) }
                    Tab("Sign-In & Security", systemImage: "lock") { AccountForm(page: .security) }
                    Tab("Advanced", systemImage: "gearshape.2") { AccountForm(page: .developer) }
                }
                #else
                NavigationStack { AccountForm(page: .all) }
                #endif
            }
        }
        .errorBanner()
        .preferredColorScheme(appearance.colorScheme)
    }
}

/// Which part of the account a form shows: everything on iPhone and iPad (but the API tokens,
/// a page of their own there), one tab of the Mac's Settings window otherwise.
enum AccountPage: Hashable {
    case all
    /// Appearance (and the Mac's menu bar assistant).
    case general
    /// Who you are: name, language, email; administration, signing out.
    case account
    /// Password, passkeys, the signed-in devices and browsers.
    case security
    /// API tokens for scripts and programs.
    case developer

    /// Whether the form shows `part`.
    func shows(_ part: AccountPage) -> Bool {
        self == .all ? part != .developer : self == part
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
    let page: AccountPage
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system
    #if os(macOS)
    @AppStorage("menuBarAssistant") private var menuBarAssistant = true
    @State private var showAdmin = false
    #endif

    @State private var state: LoadState<AccountOverview> = .idle
    @State private var name = ""
    @State private var sheet: AccountSheet?
    @State private var confirmation: AccountConfirmation?
    @State private var confirmSignOut = false
    @FocusState private var nameFocused: Bool

    private var user: UserAccount? { state.value?.user ?? app.me }
    /// The general tab shows nothing of the server's.
    private var needsOverview: Bool { page != .general }

    var body: some View {
        Form {
            if page.shows(.account) { header }

            if needsOverview {
                if let overview = state.value {
                    if page.shows(.account) {
                        profileSection(overview.user)
                        emailSection(overview.user)
                    }
                    if page.shows(.security) {
                        passwordSection(overview)
                        passkeysSection(overview)
                        devicesSection(overview)
                    }
                    if page == .developer { developerSections(overview) }
                } else if case let .failed(message) = state {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Button("Try again") { Task { await load() } }
                        webLink("Open the account page on the web", systemImage: "safari")
                    }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
            }

            if page.shows(.general) { appearanceSection }
            if page.shows(.account) {
                adminSection
                if page == .all { advancedSection }
                signOutSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(page == .developer ? "API tokens" : "Account")
        .toolbar {
            #if os(iOS)
            if page == .all {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            #endif
        }
        .task(id: app.me?.id) { if needsOverview { await load() } }
        .refreshable { await load() }
        .sheet(item: $sheet) { sheet in
            sheetView(sheet)
        }
        #if os(macOS)
        .sheet(isPresented: $showAdmin) { AdminSheet() }
        #endif
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

    // MARK: Account

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                TintedIcon(systemImage: "person.fill", tint: .ohana, size: 44)
                VStack(alignment: .leading) {
                    Text(user?.displayName ?? "").font(.headline)
                    Text(user?.email ?? "").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
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
                        .buttonStyle(.borderedProminent)
                        .disabled(name.count > 100)
                }
            }
            Picker("Language", selection: Binding(get: { user.preferredLanguage }, set: setLanguage)) {
                ForEach(AccountLanguage.allCases) { Text($0.title).tag($0.rawValue) }
            }
        } header: {
            Text("Profile")
        } footer: {
            if name.count > 100 {
                Text("The name is too long (max. 100).").foregroundStyle(.red)
            } else {
                Text("The language of notifications and of what Ohana names for you, like a new family’s calendar types.")
            }
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

    @ViewBuilder private var adminSection: some View {
        if user?.isAdmin == true {
            Section {
                #if os(macOS)
                Button("Open Administration…", systemImage: "person.badge.shield.checkmark") { showAdmin = true }
                #else
                NavigationLink {
                    AdminView()
                } label: {
                    Label("Administration", systemImage: "person.badge.shield.checkmark")
                }
                #endif
            } header: {
                Text("Administration")
            } footer: {
                Text("Users and families of this server.")
            }
        }
    }

    /// iPhone and iPad: the API tokens are a page here; on the Mac they're the Advanced tab.
    private var advancedSection: some View {
        Section {
            NavigationLink {
                AccountForm(page: .developer)
            } label: {
                Label("API tokens", systemImage: "terminal")
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("For your own programs and scripts. You don’t need this to use Ohana.")
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        } footer: {
            Text("Signs this device out and deletes its token.")
        }
    }

    // MARK: General

    private var appearanceSection: some View {
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
    }

    // MARK: Sign-in and security

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
            Image(systemName: "person.badge.key.fill").foregroundStyle(Color.ohana).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text(AccountDates.line(created: passkey.createdDate, lastUsed: passkey.lastUsedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                passkeyActions(passkey, title: title, canDelete: canDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .rowHitTarget()
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

    /// The Ohana apps signed in to the account (their tokens), and the browsers signed in on the web.
    private func devicesSection(_ overview: AccountOverview) -> some View {
        Section {
            ForEach(AccountRules.deviceTokens(overview.tokens)) { token in
                deviceRow(token)
            }
            LabeledContent("Browsers signed in on the web", value: overview.sessions.formatted())
            Button("Sign out all browsers", systemImage: "rectangle.portrait.and.arrow.right") {
                confirmation = AccountConfirmation(
                    title: String(localized: "Sign out all browsers?"),
                    button: String(localized: "Sign out"),
                    message: String(localized: "Every browser signed in to your account is signed out. The apps listed above stay signed in.")
                ) { signOutOthers() }
            }
            .disabled(overview.sessions == 0)
        } header: {
            Text("Signed-in devices")
        } footer: {
            Text("Where your account is signed in. Sign out a device you don’t use anymore or don’t recognize.")
        }
    }

    private func deviceRow(_ token: AccountToken) -> some View {
        let device = AccountRules.deviceName(token)
        return HStack(spacing: 12) {
            Image(systemName: token.current ? Self.thisDeviceIcon : "ipad.and.iphone")
                .foregroundStyle(token.current ? Color.ohana : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device).lineLimit(2)
                Group {
                    if token.current {
                        Text("This device")
                    } else {
                        Text(AccountDates.line(created: token.createdDate, lastUsed: token.lastUsedDate))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                confirmDelete(token)
            } label: {
                Text("Sign out").rowHitTarget()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Sign out \(device)"))
        }
        .contextMenu {
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmDelete(token) }
        }
    }

    private static var thisDeviceIcon: String {
        #if os(macOS)
        "laptopcomputer"
        #else
        "iphone.gen3"
        #endif
    }

    // MARK: Advanced: API tokens

    @ViewBuilder
    private func developerSections(_ overview: AccountOverview) -> some View {
        let tokens = AccountRules.scriptTokens(overview.tokens)
        Section {
            if tokens.isEmpty {
                Text("No API tokens.").foregroundStyle(.secondary)
            }
            ForEach(tokens) { token in
                tokenRow(token)
            }
            Button("Create token…", systemImage: "plus") { sheet = .createToken }
        } header: {
            Text("API tokens")
        } footer: {
            Text("A token lets one of your own programs, like a script or a home automation system, use Ohana as you. It can do everything you can: only create one for programs you trust, and delete it when you stop using them.")
        }
        Section {
            DisclosureGroup("How to use") {
                Text("Send the token with every request, in this header:")
                Text(verbatim: "Authorization: Bearer <token>")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let server = app.serverURL {
                    Text("The requests go to \(server.appending(path: "api/v1").absoluteString).")
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func tokenRow(_ token: AccountToken) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name.isEmpty ? String(localized: "Token") : token.name).lineLimit(2)
                Text(AccountDates.line(created: token.createdDate, lastUsed: token.lastUsedDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                confirmDelete(token)
            } label: {
                Image(systemName: "trash")
                    .rowHitTarget()
                    .accessibilityLabel(Text("Delete \(token.name)"))
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete(token) }
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

    /// Signing a device out deletes its token; for this device that signs the app out, which is
    /// said before, not found after.
    private func confirmDelete(_ token: AccountToken) {
        let device = AccountRules.deviceName(token)
        if token.current {
            confirmation = AccountConfirmation(
                title: String(localized: "Sign out this device?"),
                button: String(localized: "Sign out"),
                message: String(localized: "You are signed out right away and connect the app again to come back.")
            ) { deleteToken(token) }
        } else if AccountRules.isDevice(token) {
            confirmation = AccountConfirmation(
                title: String(localized: "Sign out \(device)?"),
                button: String(localized: "Sign out"),
                message: String(localized: "Ohana on \(device) is signed out right away. It can be connected again.")
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
            ErrorBanner.shared.success(AccountRules.isDevice(token) ? String(localized: "Signed out.")
                                                                    : String(localized: "Token deleted."))
            await load()
        }
    }

    private func signOutOthers() {
        guard let client = app.client else { return }
        perform {
            let _: JSONValue = try await client.send(.delete, "/api/v1/me/sessions")
            ErrorBanner.shared.success(String(localized: "Browsers signed out."))
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

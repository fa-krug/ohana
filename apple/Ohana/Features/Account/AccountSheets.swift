import SwiftUI

/// The frame of the account's and the administration's small editors: a grouped form in a
/// sheet with Cancel and a confirm button; the save runs here and a failure shows in the form.
struct AccountSheetForm<Content: View>: View {
    let title: LocalizedStringKey
    var confirmTitle: LocalizedStringKey = "Save"
    var confirmRole: ButtonRole?
    /// False when the sheet shows something else after saving (a new token).
    var dismissOnSave = true
    let canSave: Bool
    let save: () async throws -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                content
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(confirmTitle, role: confirmRole, action: run)
                            .buttonStyle(.glassProminent)
                            .disabled(!canSave)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 440, idealWidth: 480, minHeight: 300)
        #endif
    }

    private func run() {
        guard canSave, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await save()
                if dismissOnSave { dismiss() }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Changing the email: the new one, confirmed with the current password.
struct AccountEmailSheet: View {
    let current: String
    let save: (AccountEmailInput) async throws -> Void
    @State private var email = ""
    @State private var password = ""

    private var newEmail: String? { AccountRules.trimmed(email) }

    var body: some View {
        AccountSheetForm(title: "Change email",
                         canSave: newEmail != nil && newEmail?.lowercased() != current.lowercased() && !password.isEmpty,
                         save: { try await save(AccountEmailInput(newEmail: newEmail ?? "", currentPassword: password)) }) {
            Section {
                LabeledContent("Current email", value: current)
                TextField("New email", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
            Section {
                SecureField("Current password", text: $password)
                    .textContentType(.password)
            } footer: {
                Text("Confirm the change with your password.")
            }
        }
    }
}

/// Setting a first password or changing it (with the current one).
struct AccountPasswordSheet: View {
    let hasPassword: Bool
    let save: (AccountPasswordInput) async throws -> Void
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""

    private var mismatch: Bool { !repeated.isEmpty && repeated != new }

    var body: some View {
        AccountSheetForm(title: hasPassword ? "Change password" : "Set a password",
                         canSave: !new.isEmpty && new == repeated && (!hasPassword || !current.isEmpty),
                         save: {
                             try await save(AccountPasswordInput(currentPassword: hasPassword ? current : nil, newPassword: new))
                         }) {
            if hasPassword {
                Section {
                    SecureField("Current password", text: $current)
                        .textContentType(.password)
                }
            }
            Section {
                SecureField("New password", text: $new)
                    .textContentType(.newPassword)
                SecureField("Repeat the new password", text: $repeated)
                    .textContentType(.newPassword)
            } footer: {
                if mismatch {
                    Text("The passwords don’t match.").foregroundStyle(.red)
                } else {
                    Text("At least 8 characters. Your browsers are signed out afterwards; this device stays signed in.")
                }
            }
        }
    }
}

/// Removing the password (sign in with passkeys only), confirmed with it.
struct AccountRemovePasswordSheet: View {
    let save: (String) async throws -> Void
    @State private var password = ""

    var body: some View {
        AccountSheetForm(title: "Remove password", confirmTitle: "Remove", confirmRole: .destructive,
                         canSave: !password.isEmpty, save: { try await save(password) }) {
            Section {
                SecureField("Current password", text: $password)
                    .textContentType(.password)
            } footer: {
                Text("You then sign in with passkeys only. Your browsers are signed out; this device stays signed in.")
            }
        }
    }
}

/// Renaming a passkey.
struct AccountPasskeyRenameSheet: View {
    let passkey: AccountPasskey
    let save: (String) async throws -> Void
    @State private var name: String

    init(passkey: AccountPasskey, save: @escaping (String) async throws -> Void) {
        self.passkey = passkey
        self.save = save
        _name = State(initialValue: passkey.deviceName)
    }

    var body: some View {
        AccountSheetForm(title: "Rename passkey",
                         canSave: name.trimmingCharacters(in: .whitespaces) != passkey.deviceName && name.count <= 100,
                         save: { try await save(name) }) {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. iPhone"))
            }
        }
    }
}

/// A new API token: its name, then the token, shown once.
struct AccountCreateTokenSheet: View {
    let create: (String) async throws -> AccountNewToken
    @State private var name = ""
    @State private var created: AccountNewToken?

    var body: some View {
        if let created {
            AccountSecretSheet(title: "Token created", systemImage: "key.horizontal.fill",
                               subtitle: created.item.name, secret: created.token,
                               message: "Copy the token now: it won’t be shown again.")
        } else {
            AccountSheetForm(title: "New API token", confirmTitle: "Create token", dismissOnSave: false,
                             canSave: AccountRules.trimmed(name) != nil && name.count <= 100,
                             save: {
                                 created = try await create(AccountRules.trimmed(name) ?? "")
                             }) {
                Section {
                    TextField("What it’s for", text: $name, prompt: Text("e.g. Home Assistant"))
                } footer: {
                    Text("For scripts and AI agents: send as \"Authorization: Bearer <token>\". A token can do everything you can.")
                }
            }
        }
    }
}

/// A secret shown once (an API token, a setup link): copy or share it now.
struct AccountSecretSheet: View {
    let title: LocalizedStringKey
    var systemImage = "key.fill"
    var subtitle: String?
    let secret: String
    let message: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TintedIcon(systemImage: systemImage, tint: .ohana, size: 56)
                    VStack(spacing: 6) {
                        Text(title).font(.title2.bold())
                        if let subtitle {
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                    }
                    Text(secret)
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .contentCard(cornerRadius: 16, padding: 12)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                AccountPasteboard.copy(secret)
                                copied = true
                            } label: {
                                Label(copied ? "Copied." : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.glassProminent)
                            if let url = URL(string: secret), url.scheme?.hasPrefix("http") == true {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }
}

/// A destructive action waiting for its confirmation.
struct AccountConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let button: String
    var message: String?
    let action: () -> Void
}

extension View {
    /// Asks before an `AccountConfirmation`'s action.
    func accountConfirmation(_ item: Binding<AccountConfirmation?>) -> some View {
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

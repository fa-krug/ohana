import SwiftUI

/// The account on this device: who is signed in where, the web pages for what the app leaves to
/// the browser (passkeys, password, API tokens, administration), and signing out.
struct AccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if let me = app.me {
                Section {
                    HStack(spacing: 14) {
                        TintedIcon(systemImage: "person.fill", tint: .ohana, size: 44)
                        VStack(alignment: .leading) {
                            Text(me.displayName).font(.headline)
                            Text(me.email).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let server = app.serverURL {
                        LabeledContent("Server", value: server.host() ?? server.absoluteString)
                    }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                webLink("Passkeys, password and API tokens", systemImage: "key", path: "/account")
                if app.me?.isAdmin == true {
                    webLink("Administration", systemImage: "person.badge.shield.checkmark", path: "/admin")
                }
            } header: {
                Text("On the web")
            } footer: {
                Text("These open your Ohana server in the browser.")
            }
            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
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
        .confirmationDialog("Sign out of Ohana on this device?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) {
                Task {
                    await app.signOut()
                    dismiss()
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    private func webLink(_ title: LocalizedStringKey, systemImage: String, path: String) -> some View {
        Button {
            if let url = app.webURL(path) { openURL(url) }
        } label: {
            Label(title, systemImage: systemImage)
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

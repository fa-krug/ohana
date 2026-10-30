import AuthenticationServices
import SwiftUI

/// Connecting a server, over the demo (a sheet): the server's address, then signing in on the
/// server's own page (passkeys and passwords both work there), which hands the app its token
/// (`DevicePairing`). The field takes what people have at hand: the address from the browser,
/// any link of the server or an invite link (`ServerLink`). A link the app was opened with signs
/// in right away (`AppModel.pendingServer`); an invite waits in `InviteInbox` and is joined once
/// signed in. Once paired the sheet closes and the loading screen covers the app until the
/// server's data is there.
struct ConnectServerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverURL") private var savedServer = ""
    @State private var server = ""
    @State private var inbox = InviteInbox.shared
    @State private var busy = false
    @State private var error: String?
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 96

    private var link: ServerLink? { ServerLink(server) }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: false) }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 560, idealHeight: 640)
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 8)
                OhanaLogo(size: logoSize)
                VStack(spacing: 8) {
                    Text("Connect your Ohana")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("Until then the app shows a demo family. Sign in to your server to see your own calendar, finances, meals and appointments.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    if inbox.code != nil { inviteNote }
                    form
                    signInButton
                    if let code = inbox.code, let link {
                        Button("New to Ohana? Create your account") {
                            openURL(link.server.appending(path: "invite/\(code)"))
                        }
                        .buttonStyle(.borderless)
                        .help("Opens the invite in the browser, where you create your account. Then come back and sign in.")
                    }
                    Text("You sign in on your server’s page; the app gets its own key, which you can remove on your account page.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 440)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background { OhanaBackground() }
        .onAppear { if server.isEmpty { server = savedServer } }
        .onChange(of: server) { _, text in takeAppInvite(text) }
        .onChange(of: app.pendingServer, initial: true) {
            guard let url = app.takePendingServer() else { return }
            server = url.absoluteString
            signIn()
        }
    }

    private var inviteNote: some View {
        Label {
            Text("You’ve been invited to a family. Sign in to your Ohana to join it.")
        } icon: {
            Image(systemName: "envelope.open.fill").foregroundStyle(Color.ohana)
        }
        .font(.callout)
        .contentCard(cornerRadius: 16, padding: 14, tint: .ohana)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Ohana address")
                .font(.headline)
            TextField("Your Ohana address", text: $server, prompt: Text(verbatim: "ohana.example.com"))
                .labelsHidden()
                .textContentType(.URL)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .onSubmit(signIn)
                .padding(12)
                .background(Color.pageBackground, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Your Ohana address")
            if let problem = Self.problem(server) {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("The address you use for Ohana in the browser, like ohana.example.com. A link from Ohana works too, such as an invite.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .contentCard(cornerRadius: 20)
    }

    private var signInButton: some View {
        Button(action: signIn) {
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text("Sign in")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(busy || link == nil)
    }

    /// What's wrong with the field's text, said while typing; nil when it's empty or usable.
    static func problem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ServerLink(trimmed) == nil else { return nil }
        if trimmed.contains(where: \.isWhitespace) {
            return String(localized: "An address has no spaces, like ohana.example.com.")
        }
        return String(localized: "That isn’t a web address. It looks like ohana.example.com.")
    }

    /// An app invite link (`ohana://invite/…`) pasted into the field: it has no server, so its code
    /// waits for the sign-in and the field asks for the address.
    private func takeAppInvite(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == DevicePairing.callbackScheme,
              let code = InviteCode.code(in: url) else { return }
        inbox.receive(code)
        server = savedServer
    }

    private func signIn() {
        guard !busy else { return }
        guard let link else {
            error = Self.problem(server) ?? APIError.invalidServer.localizedDescription
            return
        }
        if let code = link.inviteCode { inbox.receive(code) }
        let url = link.server
        server = url.absoluteString
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                // The server must answer its health check before the browser opens.
                let client = APIClient(baseURL: url, token: nil)
                _ = try await client.get("/api/health", as: JSONValue.self)
            } catch is CancellationError {
                return
            } catch {
                self.error = String(localized: "Couldn’t reach \(url.host() ?? url.absoluteString). Check the address: it’s the one you use for Ohana in the browser.")
                return
            }
            do {
                let attempt = DevicePairing.Attempt()
                let callback = try await webAuthenticationSession.authenticate(
                    using: DevicePairing.pairingURL(server: url, attempt: attempt, deviceName: AppModel.deviceName),
                    callback: .customScheme(DevicePairing.callbackScheme),
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
                switch DevicePairing.outcome(of: callback, attempt: attempt) {
                case let .paired(token):
                    // The loading screen takes over from here.
                    dismiss()
                    await app.didPair(server: url, token: token)
                case .cancelled:
                    break
                case .stateMismatch, .malformed:
                    error = String(localized: "Signing in didn’t finish. Please try again.")
                }
            } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

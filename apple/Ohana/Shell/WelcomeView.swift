import AuthenticationServices
import SwiftUI

/// First launch: the server's address, then signing in on the server's own page (passkeys and
/// passwords both work there), which hands the app its token (`DevicePairing`).
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage("serverURL") private var savedServer = ""
    @State private var server = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                Image(systemName: "house.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(Color.ohana.gradient, in: .rect(cornerRadius: 26))
                    .glassEffect(.regular.tint(.ohana.opacity(0.2)), in: .rect(cornerRadius: 26))
                VStack(spacing: 8) {
                    Text("Ohana")
                        .font(.largeTitle.bold())
                    Text("Calendar, finances, meals and appointments for your family.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                GlassEffectContainer(spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Your Ohana server")
                            .font(.headline)
                        TextField("ohana.example.com", text: $server)
                            .textContentType(.URL)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .padding(12)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                            .onSubmit(signIn)
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                        }
                        Button(action: signIn) {
                            HStack {
                                if busy { ProgressView().controlSize(.small) }
                                Text("Sign in")
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("You sign in on your server’s page; the app gets its own key, which you can remove on your account page.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                }
                .frame(maxWidth: 440)
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background { OhanaBackground() }
        .onAppear { if server.isEmpty { server = savedServer } }
    }

    private func signIn() {
        guard !busy else { return }
        guard let url = DevicePairing.serverURL(from: server) else {
            error = APIError.invalidServer.localizedDescription
            return
        }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                // The server must answer its health check before the browser opens.
                let client = APIClient(baseURL: url, token: nil)
                _ = try await client.get("/api/health", as: JSONValue.self)
                let attempt = DevicePairing.Attempt()
                let callback = try await webAuthenticationSession.authenticate(
                    using: DevicePairing.pairingURL(server: url, attempt: attempt, deviceName: AppModel.deviceName),
                    callback: .customScheme(DevicePairing.callbackScheme),
                    preferredBrowserSession: .shared,
                    additionalHeaderFields: [:]
                )
                switch DevicePairing.outcome(of: callback, attempt: attempt) {
                case let .paired(token):
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

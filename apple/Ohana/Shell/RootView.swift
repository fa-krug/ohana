import SwiftUI

/// Signed out: the welcome screen. Signed in: the shell of the selected family.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Group {
            switch app.phase {
            case .signedOut:
                WelcomeView()
            case .loading:
                ProgressView("Loading your families…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { OhanaBackground() }
            case let .failed(message):
                ContentUnavailableView {
                    Label("Can’t reach your server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await app.refresh() } }
                        .buttonStyle(.glassProminent)
                    Button("Sign out", role: .destructive) { Task { await app.signOut() } }
                        .buttonStyle(.glass)
                }
                .background { OhanaBackground() }
            case .ready:
                AppShell()
            }
        }
        .errorBanner()
        .animation(.smooth, value: app.phase)
        .preferredColorScheme(appearance.colorScheme)
    }
}

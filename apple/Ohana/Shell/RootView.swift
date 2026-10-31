import SwiftUI

/// The shell of the selected family, of the server's account or of the demo. While the app
/// switches between the two (`AppModel.switching`) the loading screen takes the shell's place,
/// which closes its sheets too.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Group {
            if let switching = app.switching {
                LoadingScreen(switching: switching)
            } else {
                switch app.phase {
                case .loading:
                    LoadingScreen()
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Can’t reach your server", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await app.refresh() } }
                            .buttonStyle(.glassProminent)
                        Button("Sign out and show the demo", role: .destructive) { Task { await app.signOut() } }
                            .buttonStyle(.glass)
                    }
                    .background { OhanaBackground() }
                case .outdated:
                    ContentUnavailableView {
                        Label("Your server needs an update", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    } description: {
                        Text(ServerInfo.outdatedMessage)
                    } actions: {
                        Button("Try again") { Task { await app.refresh() } }
                            .buttonStyle(.glassProminent)
                        Button("Sign out and show the demo", role: .destructive) { Task { await app.signOut() } }
                            .buttonStyle(.glass)
                    }
                    .background { OhanaBackground() }
                case .ready:
                    AppShell()
                }
            }
        }
        .errorBanner()
        .animation(.smooth, value: app.phase)
        .animation(.smooth, value: app.switching)
        .preferredColorScheme(appearance.colorScheme)
    }
}

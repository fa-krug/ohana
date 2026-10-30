import SwiftUI

@main
struct OhanaApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(.ohana)
                .onOpenURL { app.open($0) }
                // Server links (a notification's "open in Ohana") arrive as web browsing.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { app.open(url) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        #endif
        .commands { ShellCommands() }

        #if os(macOS)
        Settings {
            AccountView()
                .environment(app)
                .tint(.ohana)
                .frame(width: 480, height: 520)
        }
        #endif
    }
}

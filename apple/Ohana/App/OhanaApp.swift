import SwiftUI

@main
struct OhanaApp: App {
    @State private var app = AppModel()
    #if os(macOS)
    @AppStorage("menuBarAssistant") private var menuBarAssistant = true
    #endif

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
        // The assistant in the menu bar: a click away while the window is hidden or another app
        // is in front.
        MenuBarExtra(isInserted: $menuBarAssistant) {
            MenuBarAssistant()
                .environment(app)
                .tint(.ohana)
        } label: {
            Label("Ask Ohana", systemImage: "sparkles")
        }
        .menuBarExtraStyle(.window)

        Settings {
            AccountView()
                .environment(app)
                .tint(.ohana)
                .frame(width: 480, height: 520)
        }
        #endif
    }
}

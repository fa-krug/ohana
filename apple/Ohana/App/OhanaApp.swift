import SwiftUI

@main
struct OhanaApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(.ohana)
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

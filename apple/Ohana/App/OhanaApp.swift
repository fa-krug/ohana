import SwiftUI

@main
struct OhanaApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let app = AppModel()
        _app = State(initialValue: app)
        #if os(macOS)
        // The assistant in the menu bar: a click away while the window is hidden or another app
        // is in front.
        MenuBarItem.shared.start(app)
        #endif
    }

    /// The main window's scene id (File ▸ New Window).
    static let mainWindow = "main"

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            RootView()
                .environment(app)
                .tint(.ohana)
                .onOpenURL { app.open($0) }
                // Server links (a notification's "open in Ohana") arrive as web browsing.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { app.open(url) }
                }
                // What changed while the app was open shows on the widgets.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background, !app.isDemo { WidgetSync.reload() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        #endif
        .commands { ShellCommands() }
    }
}

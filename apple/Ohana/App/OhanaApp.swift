import CoreSpotlight
import SwiftUI

@main
struct OhanaApp: App {
    @State private var app: AppModel

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
                // A recipe picked in Spotlight (`RecipeSpotlight`).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    Task { await app.openSpotlightItem(id) }
                }
                .modifier(RecipeSpotlightUpdates(app: app))
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        #endif
        .commands { ShellCommands() }
    }
}

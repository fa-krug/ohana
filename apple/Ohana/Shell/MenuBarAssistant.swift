#if os(macOS)
import SwiftUI

/// The Mac's menu bar assistant: the selected family's chat (the same chats as the window's
/// panel), opened ready to type.
struct MenuBarAssistant: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.switching != nil {
                ProgressView()
            } else if !app.isEnabled(.assistant) {
                ContentUnavailableView("The assistant is turned off on your Ohana server.", systemImage: "sparkles")
            } else if let family = app.selectedFamily, let context = app.context(for: family) {
                AssistantPanel()
                    .environment(context)
                    .id(family.id)
                    .onAppear { context.ask() }
            } else {
                ContentUnavailableView("Sign in to Ohana first", systemImage: "sparkles")
            }
        }
        .errorBanner()
        .frame(width: 420, height: 560)
    }
}

/// The menu bar item that opens it, shown while `menuBarAssistant` is on and the server has the
/// assistant. AppKit's status item rather than SwiftUI's `MenuBarExtra`: that one sets its icon
/// again whenever a window of the app redraws, and a few redraws in one display cycle (the
/// calendar's reload) make AppKit abort with "more Update Constraints in Window passes than there
/// are views in the window".
final class MenuBarItem: NSObject, NSPopoverDelegate {
    static let shared = MenuBarItem()

    private var app: AppModel?
    private var item: NSStatusItem?
    private let popover = NSPopover()

    /// Shows the item once the app has launched and follows the setting from then on.
    func start(_ app: AppModel) {
        self.app = app
        popover.behavior = .transient
        popover.delegate = self
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MenuBarItem.shared.launched = true
                MenuBarItem.shared.sync()
            }
        }
        // Defaults may change on any thread.
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarItem.shared.sync() }
        }
        // A server without the assistant has no menu bar item.
        center.addObserver(forName: .serverModulesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarItem.shared.sync() }
        }
    }

    /// A status item made before the app has launched crashes in `NSApplication.init`.
    private var launched = false
    private var shown: Bool?

    private func sync() {
        guard launched else { return }
        let shown = (UserDefaults.standard.object(forKey: "menuBarAssistant") as? Bool ?? true)
            && app?.isEnabled(.assistant) != false
        // Stored before the item is made: making it saves its position in the defaults, which
        // calls this again.
        guard shown != self.shown else { return }
        self.shown = shown
        if shown {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: String(localized: "Ask Ohana"))
            item.button?.target = self
            item.button?.action = #selector(toggle)
            self.item = item
        } else if let item {
            popover.close()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { return popover.performClose(sender) }
        guard let app else { return }
        // A new view each time, so it appears (and gets ready to type) again.
        popover.contentViewController = NSHostingController(rootView: MenuBarAssistant().environment(app).tint(.ohana))
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
#endif

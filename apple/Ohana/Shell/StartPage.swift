import Foundation

/// The page the app opens on (Settings → This device → Start page): the one shown last (the
/// default), or a page picked there. The shell opens it at launch and when the app comes back
/// after `awayLimit` in the background (`AppShell`); a notification or link that opened the app
/// wins.
enum StartPage {
    /// Its `UserDefaults` entry.
    static let defaultsName = "startPage"
    /// The stored value for "the page shown last".
    static let last = ""
    /// Away this long, the app opens on the picked page again.
    static let awayLimit: TimeInterval = 15 * 60

    /// The pages one can pick, in the sidebar's order (not the assistant on iPhone: it's no page
    /// there; not the search or the settings).
    static var choices: [Module] {
        [.overview] + Module.modules.filter { !Module.notPages.contains($0) }
    }

    /// The picked page, if it's one of `choices` and `enabled`; nil: the page shown last.
    static func module(_ stored: String, enabled: (Module) -> Bool) -> Module? {
        guard let page = Module(rawValue: stored), choices.contains(page), enabled(page) else { return nil }
        return page
    }
}

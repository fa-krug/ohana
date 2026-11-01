import Foundation
import os
import WidgetKit

/// What every widget shows at one moment: the family's snapshot, or why there is none.
struct OhanaEntry: TimelineEntry {
    enum State {
        case ready(WidgetSnapshot)
        /// No server connected in the app (the demo, signed out).
        case signedOut
        /// Connected, but nothing loaded yet (offline since).
        case unavailable
    }

    let date: Date
    let state: State

    var snapshot: WidgetSnapshot? {
        if case let .ready(snapshot) = state { snapshot } else { nil }
    }
}

/// One provider for all the widgets: they show the same family's overview, loaded at most every
/// half hour (and whenever the app asks, `WidgetSync`), with entries where their look changes
/// by itself (an event ending, midnight).
struct OhanaProvider: TimelineProvider {
    func placeholder(in context: Context) -> OhanaEntry {
        OhanaEntry(date: Date(), state: .ready(.sample()))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (OhanaEntry) -> Void) {
        let sample = placeholder(in: context)
        if context.isPreview {
            completion(sample)
            return
        }
        Task {
            let state = await WidgetLoader.load()
            // The gallery shows the sample until there's a family to show.
            if case .ready = state {
                completion(OhanaEntry(date: Date(), state: state))
            } else {
                completion(sample)
            }
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<OhanaEntry>) -> Void) {
        Task {
            let now = Date()
            let state = await WidgetLoader.load()
            let reload = now.addingTimeInterval(WidgetLoader.interval)
            guard case let .ready(snapshot) = state else {
                completion(Timeline(entries: [OhanaEntry(date: now, state: state)], policy: .after(reload)))
                return
            }
            let changes = snapshot.changes(after: now).filter { $0 < reload.addingTimeInterval(24 * 3600) }
            let entries = [now] + changes.prefix(40)
            completion(Timeline(entries: entries.map { OhanaEntry(date: $0, state: state) }, policy: .after(reload)))
        }
    }
}

/// Loads the family's overview from its server with the device's API token, like the app's
/// overview does; keeps the last one for when the server can't be reached.
enum WidgetLoader {
    static let interval: TimeInterval = 30 * 60
    private static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "widgets")

    /// The family's overview; the widgets asking at once (the app reloads them all) share one request.
    static func load() async -> OhanaEntry.State {
        await requests.load()
    }

    private static let requests = Requests()

    private actor Requests {
        private var running: Task<OhanaEntry.State, Never>?

        func load() async -> OhanaEntry.State {
            if let running { return await running.value }
            let task = Task { await WidgetLoader.fetch() }
            running = task
            let state = await task.value
            running = nil
            return state
        }
    }

    private static func fetch(now: Date = Date()) async -> OhanaEntry.State {
        guard let source = WidgetStore.loadSource() else { return .signedOut }
        let cached = WidgetStore.loadSnapshot().flatMap { $0.familyID == source.familyID ? $0 : nil }
        guard let token = Keychain.load(Keychain.apiTokenAccount) else { return .signedOut }
        // Loaded a moment ago (the app asked several widgets at once): no need to ask again.
        if let cached, cached.today == Day(now), now.timeIntervalSince(cached.loadedAt) < 60 {
            return .ready(cached)
        }
        var request = URLRequest(url: source.overviewURL(today: Day(now)))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return .signedOut }
            guard (200..<300).contains(status) else {
                log.error("Overview: HTTP \(status)")
                return cached.map { .ready($0) } ?? .unavailable
            }
            let snapshot = try WidgetSnapshot(overview: data, source: source, loadedAt: now)
            WidgetStore.saveSnapshot(snapshot)
            return .ready(snapshot)
        } catch {
            log.error("Overview: \(error.localizedDescription, privacy: .public)")
            return cached.map { .ready($0) } ?? .unavailable
        }
    }
}

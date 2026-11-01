import Foundation
import Observation
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif

/// A kitchen timer started from a duration in a recipe step.
struct CookTimer: Codable, Hashable, Identifiable {
    let id: UUID
    /// What started it (recipe, step, duration): tapping the same duration again doesn't start a
    /// second one while it runs.
    let source: String
    let recipeID: String
    let recipeTitle: String
    let stepID: Int
    /// "Step 3"
    let stepLabel: String
    /// The step's text, for the notification.
    let instruction: String
    let seconds: Int
    let startedAt: Date

    var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(seconds)) }
    func isDone(at now: Date) -> Bool { endsAt <= now }
}

/// The running cook timers, app-wide: they go on when the cook view closes, are kept across
/// launches, show in a Live Activity on iPhone and iPad, and end with a local notification (shown
/// while the app is open too: the cook view keeps the screen on, so it usually is). A finished
/// timer stays until it's dismissed, an hour at most.
@Observable final class CookTimers {
    static let shared = CookTimers()

    private(set) var timers: [CookTimer] = []
    /// Moves on when a timer finishes, so views asking `isDone(at: now)` redraw.
    private(set) var now = Date.now

    @ObservationIgnored private let defaults: UserDefaults
    /// Off in tests: no notifications, no Live Activity.
    @ObservationIgnored private let effects: Bool
    @ObservationIgnored private var waits: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var askedForNotifications = false
    private static let storageKey = "ohana-cook-timers"
    static let notificationThread = "ohana-cook-timers"

    init(defaults: UserDefaults = .standard, effects: Bool = true) {
        self.defaults = defaults
        self.effects = effects
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([CookTimer].self, from: data) {
            timers = saved
        }
        refresh()
    }

    /// Soonest first.
    var sorted: [CookTimer] { timers.sorted { $0.endsAt < $1.endsAt } }

    func running(source: String) -> CookTimer? {
        timers.first { $0.source == source && !$0.isDone(at: .now) }
    }

    /// Starts a timer, unless the same duration's timer still runs (then that one is returned).
    @discardableResult
    func start(source: String, recipeID: String, recipeTitle: String, stepID: Int, stepLabel: String,
               instruction: String, seconds: Int, at date: Date = .now) -> CookTimer {
        if let running = running(source: source) { return running }
        // A finished one for the same duration makes room for the new one.
        for old in timers where old.source == source { remove(old.id) }
        let timer = CookTimer(id: UUID(), source: source, recipeID: recipeID, recipeTitle: recipeTitle,
                              stepID: stepID, stepLabel: stepLabel, instruction: instruction,
                              seconds: seconds, startedAt: date)
        timers.append(timer)
        save()
        wait(for: timer)
        if effects { schedule(timer) }
        syncActivity()
        return timer
    }

    /// Stops a running timer or dismisses a finished one.
    func remove(_ id: UUID) {
        waits.removeValue(forKey: id)?.cancel()
        timers.removeAll { $0.id == id }
        save()
        if effects {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
            center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        }
        syncActivity()
    }

    /// Catches up after the app was away: drops timers finished over an hour ago, waits for the
    /// running ones and brings the Live Activity up to date.
    func refresh() {
        now = .now
        let stale = timers.filter { $0.endsAt.addingTimeInterval(3600) < now }
        if !stale.isEmpty {
            timers.removeAll { stale.contains($0) }
            save()
        }
        for timer in timers where waits[timer.id] == nil && !timer.isDone(at: now) { wait(for: timer) }
        syncActivity()
    }

    private func wait(for timer: CookTimer) {
        waits[timer.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timer.endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            waits[timer.id] = nil
            now = .now
            syncActivity()
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(timers), forKey: Self.storageKey)
    }

    // MARK: Notification

    private func schedule(_ timer: CookTimer) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Timer done: \(timer.stepLabel)")
        content.subtitle = timer.recipeTitle
        content.body = timer.instruction
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = Self.notificationThread
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, timer.endsAt.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: trigger)
        let ask = !askedForNotifications
        askedForNotifications = true
        Task {
            let center = UNUserNotificationCenter.current()
            // Asked with the first timer, the moment it's clearly needed.
            if ask { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            try? await center.add(request)
        }
    }

    // A finished timer's notification shows while the app is open, with its sound: the notification
    // center's delegate is `PushNotifications` (Core/Push), which presents every notification so.

    // MARK: Live Activity

    private func syncActivity() {
        #if canImport(ActivityKit) && os(iOS)
        guard effects else { return }
        let running = sorted.filter { !$0.isDone(at: .now) }
        let shown = running.prefix(3).map {
            CookTimerAttributes.Timer(id: $0.id.uuidString, title: $0.stepLabel, subtitle: $0.recipeTitle,
                                      start: $0.startedAt, end: $0.endsAt)
        }
        let state = CookTimerAttributes.ContentState(timers: Array(shown), more: running.count - shown.count)
        Task { await Self.sync(state) }
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    /// One activity for all timers: started with the first, updated as they change, ended with
    /// the last. A timer finishing while the app is away counts down to 0:00 there and is taken
    /// off when the app is back.
    private static func sync(_ state: CookTimerAttributes.ContentState) async {
        let activities = Activity<CookTimerAttributes>.activities
        guard let last = state.timers.map(\.end).max() else {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: state, staleDate: last)
        if let activity = activities.first {
            await activity.update(content)
            for extra in activities.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: CookTimerAttributes(), content: content)
        }
    }
    #endif
}

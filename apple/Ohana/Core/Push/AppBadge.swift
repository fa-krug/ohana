import Foundation
import os
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// The number on the app's icon: the account's open chores due today and the overdue ones,
/// assigned to it or subscribed, in its families but those muted on this device
/// (server/lib/chores/badge.ts). Every push brings it (`PushPayload.badge`, set by the
/// Notification Service Extension); the app asks `GET /api/v1/me/badge` at launch, on becoming
/// active, when the day changes while it runs and after chore changes, and clears it in the demo.
/// Shown only while notifications may badge the icon.
///
/// Midnight: each answer (and each push) brings tomorrow's number too, which `MidnightBadge`
/// has the system switch to at 00:00; on iOS a background job (an app refresh task, `taskID`, run
/// by `OhanaApp`'s `.backgroundTask`) asks the server again soon after, in case something changed
/// meanwhile, and schedules the next one.
enum AppBadge {
    /// In `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let taskID = "de.fa-krug.Ohana.badge"

    private static var pending: Task<Void, Never>?
    /// The app's model: the background job asks with its connection.
    private static weak var app: AppModel?

    /// At launch: asks again whenever the day changes while the app runs.
    static func start(_ app: AppModel) {
        self.app = app
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated { app?.refreshBadge() }
        }
    }

    /// Asks the server (changes in a row ask once), then sets the badge; clears it in the demo.
    static func refresh(_ client: APIClient?) {
        pending?.cancel()
        guard let client, !client.isDemo else {
            clear()
            return
        }
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            _ = await update(client)
        }
    }

    static func clear() {
        pending?.cancel()
        pending = nil
        MidnightBadge.cancel()
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
        #endif
        set(0)
    }

    /// Asks the server and sets today's number and tomorrow's switch; false when it couldn't.
    @discardableResult
    private static func update(_ client: APIClient) async -> Bool {
        guard await badgesAllowed() else { return true }
        do {
            let answer = try await client.get("/api/v1/me/badge", query: ["today": Day.today.description], as: BadgeCount.self)
            guard !Task.isCancelled else { return false }
            set(answer.count)
            if let tomorrow = answer.tomorrow { await MidnightBadge.schedule(tomorrow) }
            scheduleJob()
            return true
        } catch {
            PushNotifications.log.error("Loading the badge failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func set(_ count: Int) {
        Task {
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
            } catch {
                PushNotifications.log.error("Setting the badge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated private static func badgesAllowed() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().badgeSetting == .enabled
    }

    // MARK: The midnight job (iOS)

    /// Five minutes past the next midnight: after `MidnightBadge` switched, so the server's
    /// answer is about the new day. The system runs it when it sees fit from then on.
    static func jobStart(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 60 * 60)
        return midnight.addingTimeInterval(5 * 60)
    }

    private static func scheduleJob() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = jobStart()
        do {
            // Replaces the one waiting.
            try BGTaskScheduler.shared.submit(request)
        } catch {
            PushNotifications.log.error("Scheduling the badge job failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// The job itself; the system cancels it when its time is up.
    static func runJob() async {
        guard let client = app?.client, !client.isDemo else { return }
        // Not reached (offline, out of time): tomorrow night's job still has to come.
        if await !update(client) { scheduleJob() }
    }
}

/// GET /api/v1/me/badge.
nonisolated struct BadgeCount: Decodable, Sendable {
    let count: Int
    /// The number from the next midnight on (older servers: none).
    let tomorrow: MidnightBadge.Next?
}

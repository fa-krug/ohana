import Foundation
import os
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// The number on the app's icon: the account's open chores already due (from their time, else
/// from when their part of the day starts) and the overdue ones, assigned to it or subscribed,
/// in its families but those muted on this device
/// (server/lib/chores/badge.ts). Every push brings it (`PushPayload.badge`, set by the
/// Notification Service Extension); the app asks `GET /api/v1/me/badge` at launch, on becoming
/// active, when the day changes while it runs and after chore changes, and clears it in the demo.
/// Shown only while notifications may badge the icon.
///
/// Later: each answer (and each push) brings the moments the number changes at until the end of
/// tomorrow (a morning's chores in the morning, midnight), which `BadgeSchedule` has the system
/// switch to; on iOS a background job (an app refresh task, `taskID`, run
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
        BadgeSchedule.cancel()
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
        #endif
        set(0)
    }

    /// Asks the server and sets the number now and its switches ahead; false when it couldn't.
    @discardableResult
    private static func update(_ client: APIClient) async -> Bool {
        guard await badgesAllowed() else { return true }
        do {
            let answer = try await client.get("/api/v1/me/badge", query: clock(), as: BadgeCount.self)
            guard !Task.isCancelled else { return false }
            set(answer.count)
            await BadgeSchedule.schedule(steps: answer.steps, tomorrow: answer.tomorrow)
            scheduleJob()
            return true
        } catch {
            PushNotifications.log.error("Loading the badge failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The device's wall clock for the server: `today` and `time` ("HH:MM").
    static func clock(_ now: Date = Date(), calendar: Calendar = .current) -> [String: String?] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        func pad(_ n: Int?, _ width: Int = 2) -> String {
            let s = String(n ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return [
            "today": "\(pad(c.year, 4))-\(pad(c.month))-\(pad(c.day))",
            "time": "\(pad(c.hour)):\(pad(c.minute))",
        ]
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

    /// Five minutes past the next midnight: after `BadgeSchedule` switched, so the server's
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
    let tomorrow: BadgeSchedule.Next?
    /// The changes until the end of tomorrow (older servers: none).
    let steps: [BadgeSchedule.Step]?
}

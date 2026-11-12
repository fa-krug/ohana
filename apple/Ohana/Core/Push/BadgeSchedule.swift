import Foundation
import UserNotifications

/// Switches the app icon's number while the app doesn't run: local notifications that carry only a
/// badge (nothing shows), one at each moment the server says the number changes until the end of
/// tomorrow (`GET /api/v1/me/badge`'s `steps`, a push's `badgeSteps`: chores becoming due, their
/// time or the start of their part of the day, and midnight). Older servers send only the number
/// from the next midnight on (`tomorrow`, `badgeTomorrow`). Scheduled by the app (`AppBadge`) and
/// by the Notification Service Extension from every push; fixed identifiers, so the newest
/// schedule replaces the one before. Shared with the extension targets.
nonisolated enum BadgeSchedule {
    /// The switch at midnight (older servers).
    static let midnightIdentifier = "de.fa-krug.Ohana.badge.midnight"
    private static let stepPrefix = "de.fa-krug.Ohana.badge.step."
    /// As many as the server sends at most (server/lib/chores/badge.ts `MAX_BADGE_STEPS`).
    static let maxSteps = 16

    static var identifiers: [String] {
        [midnightIdentifier] + (0..<maxSteps).map { stepPrefix + String($0) }
    }

    /// Whether a notification is one of these (shows nothing, in the foreground too).
    static func isBadgeOnly(_ identifier: String) -> Bool {
        identifier == midnightIdentifier || identifier.hasPrefix(stepPrefix)
    }

    /// The number from the start of `day` ("YYYY-MM-DD") on.
    struct Next: Codable, Equatable, Sendable {
        var day: String
        var count: Int
    }

    /// The number from `at` ("YYYY-MM-DDTHH:MM", wall clock) on.
    struct Step: Codable, Equatable, Sendable {
        var at: String
        var count: Int
    }

    /// The local midnight that starts `day`; nil for a malformed day.
    static func start(of day: String, calendar: Calendar = .current) -> Date? {
        moment("\(day)T00:00", calendar: calendar)
    }

    /// The local moment of a wall-clock "YYYY-MM-DDTHH:MM"; nil when malformed.
    static func moment(_ at: String, calendar: Calendar = .current) -> Date? {
        let halves = at.split(separator: "T")
        guard halves.count == 2 else { return nil }
        let date = halves[0].split(separator: "-").compactMap { Int($0) }
        let time = halves[1].split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, time.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: date[0], month: date[1], day: date[2], hour: time[0], minute: time[1]))
    }

    /// The requests for the switches ahead of `now`: one per step when the server sent steps
    /// (even none), else the one at midnight.
    static func requests(steps: [Step]?, tomorrow: Next?, now: Date = Date(), calendar: Calendar = .current) -> [UNNotificationRequest] {
        if let steps {
            let ahead = steps.compactMap { step in moment(step.at, calendar: calendar).map { (step, $0) } }
                .filter { $0.1 > now }
                .prefix(maxSteps)
            return ahead.enumerated().map { i, pair in
                request(stepPrefix + String(i), count: pair.0.count, at: pair.1, calendar: calendar)
            }
        }
        guard let tomorrow, let start = start(of: tomorrow.day, calendar: calendar), start > now else { return [] }
        return [request(midnightIdentifier, count: tomorrow.count, at: start, calendar: calendar)]
    }

    private static func request(_ identifier: String, count: Int, at date: Date, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.badge = NSNumber(value: max(0, count))
        let when = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    /// Replaces the scheduled switches with these.
    static func schedule(steps: [Step]?, tomorrow: Next?) async {
        cancel()
        for request in requests(steps: steps, tomorrow: tomorrow) {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

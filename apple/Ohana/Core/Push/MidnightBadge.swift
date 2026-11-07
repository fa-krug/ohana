import Foundation
import UserNotifications

/// Switches the app icon's number at midnight without the app running: a local notification that
/// carries only a badge (nothing shows), at the start of the day the server's "tomorrow" number is
/// for (`GET /api/v1/me/badge`, a push's `badgeTomorrow`). Scheduled by the app (`AppBadge`) and by
/// the Notification Service Extension from every push; one identifier, so the newest replaces the
/// one before. Shared with the extension targets.
nonisolated enum MidnightBadge {
    static let identifier = "de.fa-krug.Ohana.badge.midnight"

    /// The number from the start of `day` ("YYYY-MM-DD") on.
    struct Next: Codable, Equatable, Sendable {
        var day: String
        var count: Int
    }

    /// The local midnight that starts `day`; nil for a malformed day.
    static func start(of day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The request for `next`; nil when its midnight isn't ahead of `now`.
    static func request(_ next: Next, now: Date = Date(), calendar: Calendar = .current) -> UNNotificationRequest? {
        guard let start = start(of: next.day, calendar: calendar), start > now else { return nil }
        let content = UNMutableNotificationContent()
        content.badge = NSNumber(value: max(0, next.count))
        let when = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    /// Schedules the switch to `next` (replacing the one before); a day already begun is left out.
    static func schedule(_ next: Next) async {
        guard let request = request(next) else { return }
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

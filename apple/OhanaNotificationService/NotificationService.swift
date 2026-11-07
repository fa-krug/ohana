import UserNotifications

/// Opens the sealed payload of a push (`PushPayload`, server/lib/push/payload.ts) with the
/// device's key from the shared Keychain and shows its title and body. The relay put only a
/// fallback text on the notification ("New notification from Ohana"); that stays when the
/// payload can't be opened (no key: push was turned off, or another server's). The payload's
/// number for tomorrow is scheduled for midnight (`MidnightBadge`).
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        if let sealed = request.content.userInfo[PushPayload.userInfoKey] as? String,
           let key = PushKey.load(),
           let payload = try? PushPayload.open(sealed, key: key) {
            payload.apply(to: content)
            // Called off the main thread: waiting here (briefly) keeps the extension alive until
            // the system has the request.
            if let next = payload.badgeTomorrow, let request = MidnightBadge.request(next) {
                let added = DispatchSemaphore(value: 0)
                UNUserNotificationCenter.current().add(request) { _ in added.signal() }
                _ = added.wait(timeout: .now() + 5)
            }
        }
        contentHandler(content)
    }
}

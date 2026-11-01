import Foundation
import Observation
import os
import UserNotifications
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Push notifications to this device (server/lib/push, relay/). A self-hosted server can't sign
/// APNs requests for this app, so this build's relay (Info.plist `OhanaPushRelay`) holds the key:
/// the app registers its APNs token with the relay, gives the server the relay's token and a key
/// of its own (`PushKey`), and the server sends sealed payloads through the relay, which the
/// Notification Service Extension opens. Off until the user turns it on for this device
/// (`enable`); then renewed at every start (`renew`: APNs tokens change).
@Observable
final class PushNotifications: NSObject {
    static let shared = PushNotifications()
    static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "push")

    /// The relay this build's APNs key lives with.
    static let relay: URL? = (Bundle.main.object(forInfoDictionaryKey: "OhanaPushRelay") as? String)
        .flatMap { URL(string: $0) }

    /// Debug builds get their APNs tokens from the sandbox; TestFlight and the App Store from
    /// production.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    /// Whether a server with `info` can push to this build: it has push on, through our relay.
    static func isAvailable(_ info: ServerInfo?) -> Bool {
        guard let server = info?.push?.relay, let relay else { return false }
        return sameRelay(server, relay)
    }

    static func sameRelay(_ a: URL, _ b: URL) -> Bool {
        func normalized(_ u: URL) -> String {
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.host = c?.host?.lowercased()
            c?.scheme = c?.scheme?.lowercased()
            var path = c?.path ?? ""
            while path.hasSuffix("/") { path.removeLast() }
            c?.path = path
            c?.query = nil
            c?.fragment = nil
            return c?.string ?? u.absoluteString
        }
        return normalized(a) == normalized(b)
    }

    /// The user turned push on for this device (and its server); remembered per device.
    private(set) var isOn = UserDefaults.standard.bool(forKey: Keys.on) {
        didSet { UserDefaults.standard.set(isOn, forKey: Keys.on) }
    }

    /// This device as the server knows it (`GET /api/v1/me/push`); nil until loaded.
    private(set) var device: PushDevice?
    private(set) var busy = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var tokenWaiter: CheckedContinuation<Data, any Error>?
    /// Counts token requests, so a late timeout doesn't end a newer one.
    @ObservationIgnored private var tokenRequest = 0
    /// The connection push was renewed for (`renew`).
    @ObservationIgnored private weak var renewed: APIClient?

    private enum Keys {
        static let on = "pushNotifications"
    }

    /// Becomes the notification center's delegate (taps open their page).
    func start(_ app: AppModel) {
        self.app = app
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: Turning it on and off

    /// Asks for permission, registers with APNs and the relay, and tells the server. Throws a
    /// message for the user.
    func enable(client: APIClient, info: ServerInfo?) async throws {
        guard Self.isAvailable(info), let relay = Self.relay else { throw PushError.unavailable }
        busy = true
        defer { busy = false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { throw PushError.denied }
        try await register(client: client, relay: relay, muted: device?.mutedFamilyIds)
        isOn = true
    }

    /// Stops pushes to this device: the server forgets it, the key goes.
    func disable(client: APIClient?) async {
        busy = true
        defer { busy = false }
        if let client, !client.isDemo {
            _ = try? await client.send(.delete, "/api/v1/me/push", as: PushDevice.self)
        }
        forget()
    }

    /// Signed out or switched servers: the server dropped the device with the token; forget the
    /// key and the switch here too.
    func forget() {
        isOn = false
        device = nil
        PushKey.delete()
    }

    /// Registers again at start (a new APNs token, a new relay token) while push is on, once per
    /// connection. Quiet: failures are logged, the next start tries again.
    func renew(client: APIClient, info: ServerInfo?) async {
        guard isOn, !client.isDemo, renewed !== client else { return }
        guard Self.isAvailable(info), let relay = Self.relay else { return }
        renewed = client
        let status = await Self.authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        do {
            try await register(client: client, relay: relay, muted: nil)
        } catch {
            Self.log.error("Renewing push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Loads what the server knows of this device (registered, muted families). On here but
    /// forgotten there (the relay said the device is gone): registers again.
    func load(client: APIClient, info: ServerInfo?) async {
        guard !client.isDemo else { return }
        do {
            device = try await client.get("/api/v1/me/push", as: PushDevice.self)
            if device?.registered == false, isOn {
                renewed = nil
                await renew(client: client, info: info)
            }
        } catch {
            Self.log.error("Loading push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Turns pushes of one family on or off on this device.
    func setMuted(_ familyID: String, muted: Bool, client: APIClient) async throws {
        var ids = device?.mutedFamilyIds ?? []
        ids.removeAll { $0 == familyID }
        if muted { ids.append(familyID) }
        device = try await client.send(.patch, "/api/v1/me/push", body: PushMuteInput(mutedFamilyIds: ids), as: PushDevice.self)
    }

    /// A test push to this device, right away.
    func sendTest(client: APIClient) async throws {
        device = try await client.send(.post, "/api/v1/me/push/test", as: PushDevice.self)
    }

    private func register(client: APIClient, relay: URL, muted: [String]?) async throws {
        let apnsToken = try await requestAPNsToken()
        let relayToken = try await registerWithRelay(relay, apnsToken: apnsToken)
        let key = PushKey.loadOrCreate()
        let input = PushRegistration(
            relay: relay.absoluteString,
            relayToken: relayToken,
            key: key.base64EncodedString(),
            platform: Self.platform,
            mutedFamilyIds: muted
        )
        device = try await client.send(.put, "/api/v1/me/push", body: input, as: PushDevice.self)
    }

    // MARK: APNs

    /// The APNs token, from `registerForRemoteNotifications` (the app delegate passes it on).
    private func requestAPNsToken() async throws -> Data {
        if let waiting = tokenWaiter {
            tokenWaiter = nil
            waiting.resume(throwing: CancellationError())
        }
        tokenRequest += 1
        let request = tokenRequest
        return try await withCheckedThrowingContinuation { continuation in
            tokenWaiter = continuation
            #if canImport(UIKit)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.tokenRequest == request else { return }
                self.didFailToRegister(PushError.noToken)
            }
        }
    }

    func didRegister(deviceToken: Data) {
        tokenWaiter?.resume(returning: deviceToken)
        tokenWaiter = nil
    }

    func didFailToRegister(_ error: any Error) {
        tokenWaiter?.resume(throwing: error)
        tokenWaiter = nil
    }

    // MARK: The relay

    private func registerWithRelay(_ relay: URL, apnsToken: Data) async throws -> String {
        var req = URLRequest(url: relay.appending(path: "v1/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONEncoder().encode(RelayRegistration(
            apnsToken: apnsToken.map { String(format: "%02x", $0) }.joined(),
            environment: Self.environment,
            platform: Self.platform
        ))
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw PushError.relay(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let answer = try? JSONDecoder().decode(RelayRegistrationAnswer.self, from: data) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PushError.relay(APIError.message(from: data) ?? "HTTP \(status)")
        }
        return answer.relayToken
    }

    // MARK: Taps

    /// Opens the page a notification leads to (`/f/{id}/…` on the server).
    func open(path: String?) {
        guard let path, let app, let server = app.serverURL,
              let url = URL(string: path, relativeTo: server)?.absoluteURL else { return }
        app.open(url)
    }
}

extension PushNotifications: nonisolated UNUserNotificationCenterDelegate {
    /// In the foreground too: a banner, in the list, with its sound.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run { PushNotifications.shared.open(path: path) }
    }
}

/// GET/PUT/PATCH/DELETE /api/v1/me/push.
struct PushDevice: Codable, Equatable {
    var registered: Bool
    var platform: String?
    var mutedFamilyIds: [String]
    var lastSentAt: String?
    var lastError: String?
}

struct PushRegistration: Encodable {
    let relay: String
    let relayToken: String
    let key: String
    let platform: String
    /// Left out on renewal: the server keeps the muted families.
    let mutedFamilyIds: [String]?
}

struct PushMuteInput: Encodable {
    let mutedFamilyIds: [String]
}

private struct RelayRegistration: Encodable {
    let apnsToken: String
    let environment: String
    let platform: String
}

private struct RelayRegistrationAnswer: Decodable {
    let relayToken: String
}

enum PushError: LocalizedError {
    case unavailable
    case denied
    case noToken
    case relay(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "This server doesn’t send notifications to the app.")
        case .denied:
            String(localized: "Notifications are turned off for Ohana. Turn them on in the system settings.")
        case .noToken:
            String(localized: "The device couldn’t register for notifications. Try again later.")
        case let .relay(message):
            String(localized: "The notification service couldn’t be reached: \(message)")
        }
    }
}

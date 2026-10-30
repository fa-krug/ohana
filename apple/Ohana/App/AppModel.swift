import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The app's session: which server, the device's API token, the account and its families, and
/// the family on screen. One per app; views read it from the environment.
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// No server or token yet: the welcome screen.
        case signedOut
        /// Signed in, loading the account.
        case loading
        case ready
        /// Signed in, but the account couldn't be loaded (offline, server down).
        case failed(String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var serverURL: URL?
    private(set) var me: UserAccount?
    private(set) var families: [FamilySummary] = []
    private(set) var client: APIClient?

    /// The family on screen; remembered per device.
    var selectedFamilyID: String? {
        didSet { UserDefaults.standard.set(selectedFamilyID, forKey: Keys.family) }
    }

    var selectedFamily: FamilySummary? {
        families.first { $0.id == selectedFamilyID } ?? families.first
    }

    /// Family contexts by id, so a family's caches and change signals survive switching away.
    private var contexts: [String: FamilyContext] = [:]

    private enum Keys {
        static let server = "serverURL"
        static let family = "selectedFamilyID"
        static let token = "apiToken"
    }

    init() {
        selectedFamilyID = UserDefaults.standard.string(forKey: Keys.family)
        #if DEBUG
        // Development: `-OHANA_DEV_SERVER http://localhost:3000 -OHANA_DEV_TOKEN ohana_…` as launch
        // arguments signs in with an API token without pairing (nothing is stored).
        if let text = UserDefaults.standard.string(forKey: "OHANA_DEV_SERVER"), let url = URL(string: text),
           let token = UserDefaults.standard.string(forKey: "OHANA_DEV_TOKEN") {
            connect(server: url, token: token)
            Task { await refresh() }
            return
        }
        #endif
        if let text = UserDefaults.standard.string(forKey: Keys.server), let url = URL(string: text),
           let token = Keychain.load(Keys.token) {
            connect(server: url, token: token)
            Task { await refresh() }
        }
    }

    /// For previews and tests: a model with fixed data, not touching the Keychain.
    init(preview server: URL, me: UserAccount, families: [FamilySummary]) {
        serverURL = server
        client = APIClient(baseURL: server, token: nil)
        self.me = me
        self.families = families
        selectedFamilyID = families.first?.id
        phase = .ready
    }

    func context(for family: FamilySummary) -> FamilyContext? {
        guard let client else { return nil }
        if let existing = contexts[family.id], existing.family == family { return existing }
        let context = FamilyContext(family: family, api: FamilyAPI(client: client, familyID: family.id))
        if let old = contexts[family.id] { context.adoptRevisions(from: old) }
        contexts[family.id] = context
        return context
    }

    // MARK: Signing in and out

    /// Stores the paired server and token and loads the account.
    func didPair(server: URL, token: String) async {
        UserDefaults.standard.set(server.absoluteString, forKey: Keys.server)
        Keychain.save(token, for: Keys.token)
        connect(server: server, token: token)
        await refresh()
    }

    private func connect(server: URL, token: String) {
        serverURL = server
        let client = APIClient(baseURL: server, token: token)
        client.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.forget() }
        }
        self.client = client
        contexts = [:]
        phase = .loading
    }

    /// Reloads the account and its families (after creating or leaving a family, too).
    func refresh() async {
        guard let client else { return }
        if me == nil { phase = .loading }
        do {
            let response: MeResponse = try await client.get("/api/v1/me")
            me = response.user
            families = response.families
            if selectedFamilyID == nil || !families.contains(where: { $0.id == selectedFamilyID }) {
                selectedFamilyID = families.first?.id
            }
            phase = .ready
        } catch is CancellationError {
        } catch APIError.unauthorized {
            forget()
        } catch {
            if me == nil { phase = .failed(error.localizedDescription) }
        }
    }

    /// Signs the device out: the server forgets its token, the app forgets the server.
    func signOut() async {
        if let client {
            _ = try? await client.send(.delete, "/api/v1/me", as: JSONValue.self)
        }
        forget()
    }

    private func forget() {
        Keychain.delete(Keys.token)
        client = nil
        me = nil
        families = []
        contexts = [:]
        phase = .signedOut
    }

    /// What the server calls this device, shown in the account's token list.
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// A page of the web app (for what the app leaves to it: passkeys).
    func webURL(_ path: String) -> URL? {
        client?.url(path)
    }

    // MARK: Links

    /// Opens a link into a family: `ohana://f/{familyId}/meals/recipes/{id}` or the same path on
    /// the server (`https://ohana.example/f/{id}/…`, e.g. from a notification). Switches to the
    /// family when it is one of the account's. False for links it can't open.
    @discardableResult
    func open(_ url: URL) -> Bool {
        var path = url.path(percentEncoded: false)
        if url.scheme == DevicePairing.callbackScheme {
            // ohana://f/{id}/…: "f" is the host.
            path = "/" + (url.host() ?? "") + path
        } else if let server = serverURL, url.host() != server.host() {
            return false
        }
        guard let (familyID, route) = AppRoute.parse(webPath: path),
              let family = families.first(where: { $0.id == familyID }) else { return false }
        selectedFamilyID = family.id
        context(for: family)?.open(route)
        return true
    }
}

/// The family on screen: its API and the change signals between modules (the web app's
/// lib/assistant events: the assistant changing calendar entries makes the calendar reload).
@Observable
final class FamilyContext {
    let family: FamilySummary
    let api: FamilyAPI

    init(family: FamilySummary, api: FamilyAPI) {
        self.family = family
        self.api = api
    }

    var canEdit: Bool { family.canEdit }

    private(set) var revisions: [DataArea: Int] = [:]

    /// A counter per area that grows with every change; views reload with `.task(id:)` on it.
    func revision(_ area: DataArea) -> Int { revisions[area, default: 0] }

    /// Something changed `areas` (the assistant, another screen): views showing them reload.
    func didChange(_ areas: DataArea...) {
        for area in areas { revisions[area, default: 0] += 1 }
    }

    func didChange(_ areas: [DataArea]) {
        for area in areas { revisions[area, default: 0] += 1 }
    }

    fileprivate func adoptRevisions(from other: FamilyContext) {
        revisions = other.revisions
    }

    // MARK: Routes

    /// Where the user is being sent (`open`); the shell switches to its module, whose root takes
    /// it (`takeRoute`).
    private(set) var pendingRoute: AppRoute?

    /// Sends the user to `route`: from a card, a link in another module, a web link.
    func open(_ route: AppRoute) {
        pendingRoute = route
    }

    // MARK: Asking the assistant

    /// What the assistant should do when it shows next (`ask`): the panel or the assistant's page
    /// takes it with `takeAssistantRequest()`.
    private(set) var assistantRequest: AssistantRequest?

    /// Opens the assistant with the composer focused, from anywhere: optionally on a new chat,
    /// with `prompt` typed in, and sent right away with `send`. The shell shows the panel (or the
    /// assistant's page when it's on screen).
    func ask(_ prompt: String? = nil, send: Bool = false, newChat: Bool = false) {
        assistantRequest = AssistantRequest(prompt: prompt, send: send, newChat: newChat)
    }

    func takeAssistantRequest() -> AssistantRequest? {
        defer { assistantRequest = nil }
        return assistantRequest
    }

    /// The pending route if `module` shows it; it's taken (cleared) then. Module roots call this
    /// in `.onChange(of: family.pendingRoute, initial: true)`.
    func takeRoute(for module: Module) -> AppRoute? {
        guard let route = pendingRoute, route.module == module else { return nil }
        pendingRoute = nil
        return route
    }
}

/// See `FamilyContext.ask`.
struct AssistantRequest: Equatable, Identifiable {
    let id = UUID()
    var prompt: String?
    var send: Bool
    var newChat: Bool
}

/// What a change can touch, for `FamilyContext.didChange`.
enum DataArea: String, CaseIterable, Hashable {
    case family, calendar, events, finance, meals, recipes, shopping, mealPlan, appointments, settings
}

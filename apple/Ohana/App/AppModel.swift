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
        if let text = UserDefaults.standard.string(forKey: Keys.server), let url = URL(string: text),
           let token = Keychain.load(Keys.token) {
            connect(server: url, token: token)
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

    /// A page of the web app (for what the app leaves to it: administration, passkeys).
    func webURL(_ path: String) -> URL? {
        client?.url(path)
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
}

/// What a change can touch, for `FamilyContext.didChange`.
enum DataArea: String, CaseIterable, Hashable {
    case family, calendar, events, finance, meals, recipes, shopping, mealPlan, appointments, settings
}

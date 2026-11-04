import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The app's session: which server, the device's API token, the account and its families, and
/// the family on screen. One per app; views read it from the environment. Without a server the
/// app shows the demo (`DemoServer`, read-only) until one is connected. The account, its families
/// and the server's info as last loaded are kept on the device (`ResponseCache`): the app opens
/// on them at once, offline too, and refreshes behind.
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// Loading the account (of the server or the demo).
        case loading
        case ready
        /// Signed in, but the account couldn't be loaded (offline, server down).
        case failed(String)
        /// The server's API is older than the app needs (`ServerInfo.requiredAPIVersion`).
        case outdated
    }

    /// What the loading screen covers the whole app for, while it switches between the demo
    /// and a server (`RootView`).
    enum Switch: Equatable {
        /// A server was connected: until its account and families are loaded.
        case server(host: String)
        /// The server was removed (signed out): until the demo is loaded.
        case demo
    }

    private(set) var phase: Phase = .loading
    private(set) var switching: Switch?
    /// The connected server; nil in the demo.
    private(set) var serverURL: URL?
    private(set) var me: UserAccount?
    private(set) var families: [FamilySummary] = []
    private(set) var client: APIClient?
    /// The server's version and modules (GET /api/v1/server, the demo's too); nil until it
    /// answered. Unknown, every module shows.
    private(set) var serverInfo: ServerInfo? {
        didSet {
            guard serverInfo != oldValue else { return }
            for context in contexts.values { context.serverInfo = serverInfo }
            AssistantInbox.shared.available = isEnabled(.assistant)
            NotificationCenter.default.post(name: .serverModulesChanged, object: nil)
            syncWidgets()
        }
    }

    /// The server of a link opened in the demo (an invite link, a page of the server): the
    /// connect sheet takes it (`takePendingServer`) and starts signing in.
    private(set) var pendingServer: URL?

    /// The sheet that connects a server (`ConnectServerView`), shown over the demo.
    var showsConnect = false

    /// The family page behind the tabs on iPhone (`FamilySidebarHost`) is on screen.
    var showsFamilySidebar = false
    /// How many module roots are on screen (none while a page is pushed over one): the swipe
    /// to the family page is on only then.
    var moduleRootsOnScreen = 0

    /// No server connected: the screens show the demo's data.
    var isDemo: Bool { client?.isDemo ?? true }

    /// The family on screen; remembered per device (the demo's isn't), in the Keychain too for the
    /// share extensions (`SharedConnection`).
    var selectedFamilyID: String? {
        didSet {
            guard !isDemo, selectedFamilyID != oldValue else { return }
            UserDefaults.standard.set(selectedFamilyID, forKey: Keys.family)
            SharedConnection.remember(familyID: selectedFamilyID)
            syncWidgets()
            prefetch()
        }
    }

    var selectedFamily: FamilySummary? {
        families.first { $0.id == selectedFamilyID } ?? families.first
    }

    /// Whether the server has `module` on (all of them while that isn't known yet).
    func isEnabled(_ module: Module) -> Bool {
        // The knowledge base: the selected family's editors, not the demo (`FamilyContext.knowledgeAvailable`).
        if module == .knowledge {
            return !isDemo && selectedFamily?.canEdit == true && serverInfo?.hasKnowledge == true
        }
        return serverInfo?.isEnabled(module) ?? true
    }

    /// Family contexts by id, so a family's caches and change signals survive switching away.
    private var contexts: [String: FamilyContext] = [:]

    /// Loads the selected family's screens ahead (`prefetch`).
    @ObservationIgnored private let prefetcher = Prefetcher()
    /// The server answered for the account since connecting (not only its copy on the device).
    @ObservationIgnored private var answered = false

    private enum Keys {
        static let server = "serverURL"
        static let family = "selectedFamilyID"
        static let token = SharedConnection.Account.token
    }

    /// Whether this model tells the widgets what to show (`WidgetSync`): the app's, not the
    /// previews' and tests'.
    private var syncsWidgets = false
    #if os(macOS)
    /// Reads the knowledge folders every 15 minutes while the app runs (`indexKnowledge`).
    @ObservationIgnored private var knowledgeTimer: Timer?
    #endif

    init() {
        syncsWidgets = true
        Connectivity.shared.start()
        #if os(macOS)
        knowledgeTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.indexKnowledge() }
        }
        #endif
        Connectivity.shared.whenReconnected { [weak self] in
            guard let self, !isDemo else { return }
            // Offline at launch, the account is asked again (and the screens loaded ahead then).
            if answered { prefetch() } else { Task { await self.refresh() } }
        }
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
            // Also for installs from before the share extensions: they read it from the Keychain.
            SharedConnection.remember(server: url, familyID: selectedFamilyID)
        } else {
            connectDemo()
        }
        Task { await refresh() }
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

    /// For previews and tests: the demo before it's loaded, not touching the Keychain.
    init(signedOutPreview: Void) {
        connectDemo()
    }

    func context(for family: FamilySummary) -> FamilyContext? {
        guard let client else { return nil }
        if let existing = contexts[family.id], existing.family == family { return existing }
        let context = FamilyContext(family: family, api: FamilyAPI(client: client, familyID: family.id))
        context.serverInfo = serverInfo
        if let old = contexts[family.id] { context.adoptRevisions(from: old) }
        contexts[family.id] = context
        return context
    }

    // MARK: Signing in and out

    /// Stores the paired server and token and loads the account, behind the loading screen
    /// (the demo's data must not show as the server's).
    func didPair(server: URL, token: String) async {
        await whileSwitching(.server(host: server.host() ?? server.absoluteString)) {
            UserDefaults.standard.set(server.absoluteString, forKey: Keys.server)
            Keychain.save(token, for: Keys.token)
            // It may be another account: nothing of the last one shows.
            ResponseCache(server: server).clear()
            ChoresStore.removeQueues(server: server)
            KnowledgeIndexer.removeAll(server: server)
            connect(server: server, token: token)
            SharedConnection.remember(server: server, familyID: selectedFamilyID)
            await refresh()
        }
    }

    private func connect(server: URL, token: String) {
        serverURL = server
        let client = APIClient(baseURL: server, token: token, cache: ResponseCache(server: server))
        client.onUnauthorized = { [weak self] in
            Task { @MainActor in await self?.useDemo(signingOut: false) }
        }
        self.client = client
        // The demo's family isn't remembered: back to the server's.
        selectedFamilyID = UserDefaults.standard.string(forKey: Keys.family)
        reset()
        restoreSaved(client)
    }

    /// The account, families and server info kept on the device: ready at once, `refresh`
    /// brings the server's.
    private func restoreSaved(_ client: APIClient) {
        guard let saved = Self.meRequest(client).saved()?.value else { return }
        serverInfo = ServerInfo.saved(from: client)
        if let serverInfo, !serverInfo.isSupported { return }
        take(saved)
    }

    private static func meRequest(_ client: APIClient) -> CachedGet<MeResponse> {
        client.cached("/api/v1/me")
    }

    private func take(_ response: MeResponse) {
        me = response.user
        families = response.families
        if selectedFamilyID == nil || !families.contains(where: { $0.id == selectedFamilyID }) {
            selectedFamilyID = families.first?.id
        }
        phase = .ready
    }

    private func connectDemo() {
        serverURL = nil
        client = APIClient(demo: DemoServer())
        reset()
    }

    /// Forgets the previous connection's account, families and caches.
    private func reset() {
        prefetcher.cancel()
        answered = false
        me = nil
        families = []
        contexts = [:]
        serverInfo = nil
        phase = .loading
    }

    /// Covers the app with the loading screen for `work`, and a little longer when it's quick, so
    /// the switch reads as one and never flickers.
    private func whileSwitching(_ kind: Switch, _ work: () async -> Void) async {
        switching = kind
        let start = ContinuousClock.now
        await work()
        let rest = Self.minimumSwitch - (ContinuousClock.now - start)
        if rest > .zero { try? await Task.sleep(for: rest) }
        switching = nil
    }

    static var minimumSwitch = Duration.milliseconds(900)

    /// Reloads the account and its families (after creating or leaving a family, too), and asks
    /// the server for its version and modules alongside. A server too old for the app shows as
    /// `outdated`; when the server's info can't be had (offline) the check waits for the next
    /// refresh.
    func refresh() async {
        guard let client else { return }
        if me == nil { phase = .loading }
        async let checked = checkServer(client)
        do {
            let response = try await Self.meRequest(client).fetch()
            if let info = await checked {
                serverInfo = info
                guard info.isSupported else {
                    phase = .outdated
                    return
                }
            }
            take(response)
            answered = true
            syncWidgets()
            // Push: a new APNs token, a new relay token (while it's on for this device).
            let info = serverInfo
            Task { await PushNotifications.shared.renew(client: client, info: info) }
            prefetch()
            AppleCalendarSync.shared.syncAllSoon()
        } catch is CancellationError {
        } catch APIError.unauthorized {
            await useDemo(signingOut: false)
        } catch {
            if me == nil { phase = .failed(error.localizedDescription) }
        }
    }

    /// The server's info, nil when it can't be had (offline, an odd answer): then it's asked again
    /// next time.
    private func checkServer(_ client: APIClient) async -> ServerInfo? {
        do {
            return try await ServerInfo.fetch(from: client)
        } catch {
            APIClient.log.error("No server info: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Loads the selected family's main screens in the background, so they're on the device
    /// before they're opened (`Prefetcher`: not in the demo, at most every 15 minutes a family).
    /// Only once the server answered: the account's copy alone may be outdated.
    private func prefetch() {
        guard answered, phase == .ready, let family = selectedFamily, let context = context(for: family) else { return }
        sendQueuedChanges()
        indexKnowledge()
        prefetcher.start(context)
    }

    /// Sends the selected family's changes left waiting (at launch, when the app is active again,
    /// a family switch, the connection back).
    func sendQueuedChanges() {
        guard !isDemo, let family = selectedFamily, let context = context(for: family) else { return }
        context.sendQueuedChanges(me: me?.id)
    }

    /// Reads the knowledge folders linked on this device into the server's index, for every family
    /// the account edits (`FamilyContext.indexKnowledge`): at launch, when the app is active again,
    /// the connection back, and every 15 minutes on the Mac. Each family's indexer runs at most
    /// every few minutes this way.
    func indexKnowledge() {
        guard !isDemo, answered, phase == .ready, let server = serverURL, serverInfo?.hasKnowledge == true else { return }
        for family in families where family.canEdit {
            let location = KnowledgeLocation(server: server, familyID: family.id)
            guard KnowledgeFolder(location: location).isLinked else { continue }
            context(for: family)?.indexKnowledge()
        }
    }

    /// Signs the device out: the server forgets its token, the app forgets the server and shows
    /// the demo again.
    func signOut() async {
        await useDemo(signingOut: true)
    }

    /// Back to the demo, behind the loading screen; `signingOut` deletes the token on the server
    /// first (not after a 401: the server doesn't know it anymore).
    private func useDemo(signingOut: Bool) async {
        guard let client, !client.isDemo else { return }
        await whileSwitching(.demo) {
            Keychain.delete(Keys.token)
            client.cache?.clear()
            ShoppingReminders.forget(server: client.baseURL)
            CalendarStore.removeQueues(server: client.baseURL)
            ChoresStore.removeQueues(server: client.baseURL)
            KnowledgeIndexer.removeAll(server: client.baseURL)
            AppleCalendarSync.shared.removeAll(server: client.baseURL)
            SharedConnection.forget()
            if syncsWidgets { WidgetSync.reload() }
            // The server drops the device's push with its token.
            PushNotifications.shared.forget()
            connectDemo()
            if signingOut {
                _ = try? await client.send(.delete, "/api/v1/me", as: JSONValue.self)
            }
            await refresh()
        }
    }

    /// The widgets show the family on screen (`SharedConnection`): they reload, and learn which
    /// modules the server has off.
    private func syncWidgets() {
        guard syncsWidgets, !isDemo, phase == .ready else { return }
        WidgetSync.show(disabledModules: Module.allCases.filter { !isEnabled($0) }.map(\.rawValue))
    }

    /// The server a link brought in the demo, once.
    func takePendingServer() -> URL? {
        defer { pendingServer = nil }
        return pendingServer
    }

    /// What the server calls this device, shown in the account's token list.
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    // MARK: Links

    /// Opens a link into a family: `ohana://f/{familyId}/meals/recipes/{id}` or the same path on
    /// the server (`https://ohana.example/f/{id}/…`, e.g. from a notification). Switches to the
    /// family when it is one of the account's. An invite (`ohana://invite/{code}`, the server's
    /// `/invite/{code}`) waits in `InviteInbox` for the family picker or the no-family screen to
    /// show it. Signed out, a server's link (an invite, any page) leads to signing in there
    /// (`openSignedOut`). A photo or PDF shared to Ohana goes to the letter review
    /// (`LetterScanInbox`), in the demo too. False for links it can't open.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if url.isFileURL {
            guard LetterScanInbox.accepts(url) else { return false }
            LetterScanInbox.shared.receive(url)
            return true
        }
        if isDemo { return openSignedOut(url) }
        var path = url.path(percentEncoded: false)
        if url.scheme == DevicePairing.callbackScheme {
            // ohana://f/{id}/…: "f" is the host.
            path = "/" + (url.host() ?? "") + path
        } else if let server = serverURL, url.host() != server.host() {
            return false
        }
        if let code = InviteCode.code(in: url) {
            InviteInbox.shared.receive(code)
            return true
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let (familyID, route) = AppRoute.parse(webPath: path, tab: value("tab"), day: value("day"), page: value("page")),
              let family = families.first(where: { $0.id == familyID }) else { return false }
        selectedFamilyID = family.id
        context(for: family)?.open(route)
        return true
    }

    /// In the demo: a server's link names the server, so the connect sheet signs in there right
    /// away (`pendingServer`); an invite's code waits in `InviteInbox` to be joined once signed
    /// in. `ohana://invite/{code}` carries no server: the connect sheet asks for it.
    private func openSignedOut(_ url: URL) -> Bool {
        if url.scheme == DevicePairing.callbackScheme {
            guard let code = InviteCode.code(in: url) else { return false }
            InviteInbox.shared.receive(code)
            showsConnect = true
            return true
        }
        guard let link = ServerLink(url: url) else { return false }
        if let code = link.inviteCode { InviteInbox.shared.receive(code) }
        pendingServer = link.server
        showsConnect = true
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

    /// The server's modules (`AppModel.serverInfo`), kept up to date by the app model.
    var serverInfo: ServerInfo?

    /// Whether the server has `module` on (all of them while that isn't known yet). Screens hide
    /// what belongs to a module that is off. The knowledge base only where it's available
    /// (`knowledgeAvailable`: an editor, not the demo).
    func isEnabled(_ module: Module) -> Bool {
        if module == .knowledge { return knowledgeAvailable }
        return serverInfo?.isEnabled(module) ?? true
    }

    private(set) var revisions: [DataArea: Int] = [:]

    /// A counter per area that grows with every change; views reload with `.task(id:)` on it.
    func revision(_ area: DataArea) -> Int { revisions[area, default: 0] }

    /// Something changed `areas` (the assistant, another screen): views showing them reload.
    func didChange(_ areas: DataArea...) {
        didChange(areas)
    }

    /// The widgets reload too (`WidgetSync`).
    func didChange(_ areas: [DataArea]) {
        for area in areas { revisions[area, default: 0] += 1 }
        if !api.client.isDemo { WidgetSync.reloadSoon() }
        if areas.contains(.events) || areas.contains(.calendar) { AppleCalendarSync.shared.ohanaChanged(self) }
    }

    fileprivate func adoptRevisions(from other: FamilyContext) {
        revisions = other.revisions
        if let store = other.choresStore { adopt(store) }
        knowledgeIndexer = other.knowledgeIndexer
    }

    // MARK: Chores

    @ObservationIgnored private var choresStore: ChoresStore?

    /// The family's chores, kept on the device; made when first needed, kept while the family's
    /// context is (a newer context of the family takes it over).
    var chores: ChoresStore {
        if let choresStore { return choresStore }
        let store = ChoresStore(api: api, canEdit: canEdit, queueFile: ChoresStore.queueFile(for: api))
        adopt(store)
        return store
    }

    private func adopt(_ store: ChoresStore) {
        store.familyCanEdit = canEdit
        store.notify = { [weak self] in self?.didChange($0) }
        choresStore = store
    }

    /// Sends the chores' changes left waiting (from before the app quit, or offline).
    func sendQueuedChanges(me: String?) {
        guard isEnabled(.chores), choresStore != nil || ChoresStore.hasQueue(for: api) else { return }
        if chores.me == nil { chores.me = me }
        chores.retryNow()
    }

    // MARK: Knowledge

    @ObservationIgnored private var knowledgeIndexer: KnowledgeIndexer?

    /// The family's knowledge indexer on this device; made when first needed, kept while the
    /// family's context is (a newer context of the family takes it over).
    var knowledge: KnowledgeIndexer {
        if let knowledgeIndexer { return knowledgeIndexer }
        let indexer = KnowledgeIndexer(api: api)
        knowledgeIndexer = indexer
        return indexer
    }

    /// The knowledge base is this device's to read: the server has it on, the account edits the
    /// family (viewers don't see it), and it isn't the demo.
    var knowledgeAvailable: Bool {
        !api.client.isDemo && canEdit && serverInfo?.hasKnowledge == true
    }

    /// Where the family's scans go on this device (`ScanFiling`): the knowledge folder while the
    /// knowledge base is available and its folder is linked here; nil: the scan folder.
    var scanKnowledge: ScanKnowledge? {
        guard knowledgeAvailable else { return nil }
        let location = KnowledgeLocation(server: api.client.baseURL, familyID: api.familyID)
        guard knowledgeIndexer != nil || KnowledgeFolder(location: location).isLinked else { return nil }
        let indexer = knowledge, tags = api.knowledgeTags()
        return ScanKnowledge(state: { indexer.folder.state() },
                             enqueue: { try await indexer.enqueue(file: $0, pages: $1) },
                             tags: { await ScanKnowledge.serverTags(tags) })
    }

    /// Reads the family's knowledge folder when one is linked on this device: `force` (*Read now*)
    /// at once, else unless it was read a few minutes ago.
    func indexKnowledge(force: Bool = false) {
        guard knowledgeAvailable, knowledge.folder.isLinked else { return }
        let indexer = knowledge
        Task { force ? await indexer.run() : await indexer.runIfDue() }
    }

    // MARK: Routes

    /// Where the user is being sent (`open`); the shell switches to its module, whose root takes
    /// it (`takeRoute`).
    private(set) var pendingRoute: AppRoute?

    /// Sends the user to `route`: from a card, a link in another module, a web link. A route
    /// into a module the server has off is ignored.
    func open(_ route: AppRoute) {
        guard isEnabled(route.requiredModule) else { return }
        pendingRoute = route
    }

    // MARK: Searching

    /// Grows each time the search should take the keyboard (⌘K); the search page focuses its
    /// field when it changes.
    private(set) var searchRequest = 0

    /// What is searched for. On the Mac the toolbar's field (`ShellSearchField`, on every page)
    /// and the search page share it; elsewhere the search page keeps its own.
    var searchQuery = ""

    /// Grows with each Return in the Mac's toolbar field: the search page opens its first hit.
    private(set) var searchSubmitRequest = 0

    func submitSearch() { searchSubmitRequest += 1 }

    /// Set when typing in a page's toolbar field switched to the search page: its own field takes
    /// the keyboard as it appears.
    var searchHandoff = false

    /// Shows the search ready to type: on the Mac the toolbar's field takes the keyboard where it
    /// is (typing then shows the search page), elsewhere the shell switches to the search tab.
    func startSearch() {
        searchRequest += 1
        #if !os(macOS)
        open(.module(.search))
        #endif
    }

    // MARK: Asking the assistant

    /// What the assistant should do when it shows next (`ask`): the panel or the assistant's page
    /// takes it with `takeAssistantRequest()`.
    private(set) var assistantRequest: AssistantRequest?

    /// Opens the assistant with the composer focused, from anywhere: optionally on a new chat,
    /// with `prompt` typed in and `attachments` attached (a scanned letter), and sent right away
    /// with `send`. The shell shows the panel (or the assistant's page when it's on screen).
    func ask(_ prompt: String? = nil, send: Bool = false, newChat: Bool = false,
             attachments: [AssistantPendingAttachment] = []) {
        guard isEnabled(.assistant) else { return }
        assistantRequest = AssistantRequest(prompt: prompt, send: send, newChat: newChat, attachments: attachments)
    }

    func takeAssistantRequest() -> AssistantRequest? {
        defer { assistantRequest = nil }
        return assistantRequest
    }

    // MARK: Scanning a letter

    /// Set by `scanLetter()`; the shell takes it (`takeLetterScanRequest`) and opens the scanner.
    private(set) var letterScanRequest: UUID?

    /// Opens the letter scanner over whatever shows (the shell hosts it: `ShellLetterScan`), from
    /// the family menu or "Scan Letter" in Spotlight, Siri and Shortcuts. Needs no server: the
    /// PDF is saved on the device; the assistant is offered where it can help.
    func scanLetter() {
        letterScanRequest = UUID()
    }

    func takeLetterScanRequest() -> Bool {
        defer { letterScanRequest = nil }
        return letterScanRequest != nil
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
    /// Attached to the message (added to what the composer has).
    var attachments: [AssistantPendingAttachment] = []
}

extension Notification.Name {
    /// The server's modules changed (`AppModel.serverInfo`): for what isn't a view, like the Mac's
    /// menu bar item.
    static let serverModulesChanged = Notification.Name("OhanaServerModulesChanged")
}

/// What a change can touch, for `FamilyContext.didChange`.
enum DataArea: String, CaseIterable, Hashable {
    case family, calendar, events, finance, meals, recipes, mealPlan, appointments, chores, settings
    /// The knowledge base's documents (read again, left out, the indexer's runs).
    case knowledge
    /// The week ahead's dismissed issues.
    case digest
}

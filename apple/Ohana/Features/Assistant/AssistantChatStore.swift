import Foundation
import Observation

/// The open chat (web: chat-store.ts `Chat`). `id` is "" until the server named a new chat.
struct AssistantChat: Equatable {
    var id: String
    var title: String
    var status: String
    var items: [AssistantItem]
    /// The items are saved up to this revision (the server sends what changed since).
    var rev: Int
    var usage: AssistantUsage?
    /// The page the chat belongs to; nil: it takes the page of its next message.
    var page: String?
    /// Messages waiting for the running turn to end ("local-" ids are on their way).
    var queued: [AssistantQueued]

    var isRunning: Bool { status == "running" }
}

/// The open chat is its copy on the device from `date`: `updating` while the server is asked,
/// false once it couldn't be reached.
struct AssistantSavedCopy: Equatable {
    var date: Date
    var updating: Bool
}

/// What a running turn does, and since when this device knows it.
struct AssistantActivityState: Equatable {
    var activity: AssistantActivity
    var at: Date
}

/// The AI chats of one family (web: components/assistant/chat-store.ts). They live on the
/// server, whose worker runs the turns (they go on when the app is closed, and every device sees
/// the same chats). The store lists the chats, shows the open one and follows it while a turn
/// runs: the server streams what changed from its database (server-sent events, `since` a
/// revision), and the stream is simply asked for again when it ends or breaks off. The settings,
/// the list and the chats' states are kept on the device (`CachedGet`): with nothing loaded yet
/// they show from there, so past chats can be read offline.
@Observable
final class AssistantChatStore {
    private(set) var settings: AssistantSettings?
    private(set) var settingsError: String?
    /// The user's chats, the latest first.
    private(set) var chats: [AssistantChatSummary] = []
    private(set) var chatsLoaded = false
    private(set) var currentID: String?
    /// The open chat, once loaded (or a new one being started).
    private(set) var current: AssistantChat?
    /// Set while `current` is the copy on the device, until the server or the chat's stream
    /// answers: its changes can't be undone and its question not answered meanwhile.
    private(set) var savedCopy: AssistantSavedCopy?
    /// Set while a turn runs.
    private(set) var activity: AssistantActivityState?
    /// A message is on its way to the server.
    private(set) var sending = false

    @ObservationIgnored let api: FamilyAPI
    /// Called after the assistant (or an undo) changed something, so the screens reload it.
    @ObservationIgnored var onChange: ([DataArea]) -> Void = { _ in }
    /// The page the user looks at (overview | calendar | finance | meals | appointments |
    /// settings), sent along with every message (with this year).
    @ObservationIgnored var page = "overview"

    private func context() -> (page: String, year: Int) {
        (page, Calendar.current.component(.year, from: .now))
    }

    /// Changes and tool calls this device has seen, so it reloads the data only for new ones.
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var followID = 0
    /// How many views show the store (the panel and the page may both); the last one to go
    /// stops following.
    @ObservationIgnored private var viewers = 0
    /// The latest chat was opened once (the panel opens on it rather than on an empty chat).
    @ObservationIgnored private var restoredLatest = false
    /// Grows with every chat the user opens or starts.
    @ObservationIgnored private var picks = 0

    init(api: FamilyAPI) {
        self.api = api
    }

    /// One store per family and session, so the open chat survives closing the panel.
    private static var stores: [String: AssistantChatStore] = [:]

    static func shared(for api: FamilyAPI) -> AssistantChatStore {
        let key = "\(ObjectIdentifier(api.client).hashValue):\(api.familyID)"
        if let store = stores[key] { return store }
        let store = AssistantChatStore(api: api)
        stores[key] = store
        return store
    }

    /// A turn runs in the open chat (or a message is on its way).
    var busy: Bool { sending || current?.isRunning == true }

    var isFollowing: Bool { following != nil }

    var ready: Bool { settings?.configured == true }

    // MARK: Loading

    func loadSettings() async {
        let get = Self.settingsRequest(api)
        if settings == nil { settings = get.saved()?.value }
        do {
            settings = try await get.fetch()
            settingsError = nil
        } catch is CancellationError {
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func setSettings(_ s: AssistantSettings) { settings = s }

    /// The settings' and the chat list's GETs (the prefetch asks the same).
    static func settingsRequest(_ api: FamilyAPI) -> CachedGet<AssistantSettings> {
        api.cached("/ai/settings")
    }

    static func chatsRequest(_ api: FamilyAPI) -> CachedGet<AssistantChatList> {
        api.cached("/ai/chats")
    }

    /// Before the assistant first shows: its settings, the chats and the latest chat, so the
    /// panel has them drawn before it slides in (a running turn isn't followed: no one looks yet).
    func preload() async {
        if settings == nil { await loadSettings() }
        if !chatsLoaded { await loadChats() }
        await restoreLatest(follow: false)
    }

    func loadChats() async {
        let get = Self.chatsRequest(api)
        // Only into an empty list: the server's chats are never replaced by the copy.
        if !chatsLoaded, chats.isEmpty, let copy = get.saved() { chats = copy.value.chats }
        do {
            chats = try await get.fetch().chats
            chatsLoaded = true
        } catch {
            // Offline or not allowed: the list stays as it is.
        }
    }

    /// Back in the app (another device may have chatted meanwhile): the list and the open chat
    /// catch up.
    func refresh() async {
        if let id = currentID, savedCopy?.updating == false { await fetch(id, follow: false) }
        if let id = current?.id, !id.isEmpty, following == nil { follow(id) }
        await loadChats()
    }

    /// Tries again to reach the server for the open chat's copy and the list (the badge over it).
    func retrySaved() async {
        if let id = currentID, savedCopy?.updating == false { await fetch(id, follow: true) }
        await loadChats()
    }

    /// Shows a chat as given, marking what it changed so far as seen (previews and tests).
    func show(_ chat: AssistantChat) {
        unfollow()
        for item in chat.items { markSeen(item) }
        currentID = chat.id.isEmpty ? nil : chat.id
        current = chat
        savedCopy = nil
    }

    func newChat() {
        picks += 1
        unfollow()
        currentID = nil
        current = nil
        savedCopy = nil
        activity = nil
    }

    /// Opens a chat (a running turn goes on either way); `follow`: its running turn too.
    func open(_ id: String, follow following: Bool = true) async {
        if id == currentID, current != nil {
            // Its copy on the device, the server out of reach before: ask again.
            if savedCopy?.updating == false { await fetch(id, follow: following) }
            return
        }
        picks += 1
        unfollow()
        currentID = id
        current = nil
        savedCopy = nil
        activity = nil
        if let copy = chatState(id).saved() {
            for item in copy.value.items { markSeen(item) }
            var chat = Self.chat(id, copy.value)
            // A turn that ran then has ended or goes on without this device: the server says.
            chat.status = "idle"
            chat.queued = []
            current = chat
            savedCopy = .init(date: copy.date, updating: true)
        }
        await fetch(id, follow: following)
    }

    private func chatState(_ id: String) -> CachedGet<AssistantChatState> {
        api.cached("/ai/chats/\(Self.enc(id))")
    }

    private static func chat(_ id: String, _ s: AssistantChatState) -> AssistantChat {
        AssistantChat(
            id: id, title: s.chat.title, status: s.chat.status, items: s.items, rev: s.rev,
            usage: s.chat.usage, page: s.chat.page, queued: s.chat.queued ?? []
        )
    }

    /// Asks the server for the open chat. Its answer replaces what's shown unless that changed
    /// meanwhile (a message was sent: the chat's stream brings the rest); the copy on the device
    /// stays while the server can't be reached.
    private func fetch(_ id: String, follow following: Bool) async {
        let shown = current
        savedCopy?.updating = true
        do {
            let s = try await chatState(id).fetch()
            guard currentID == id, current == shown else { return }
            for item in s.items { markSeen(item) }
            current = Self.chat(id, s)
            savedCopy = nil
            summary(s.chat)
            if s.chat.isRunning, following { follow(id) }
        } catch {
            guard currentID == id, !(error is CancellationError) else { return }
            if savedCopy != nil, APIError.isTemporary(error) {
                savedCopy?.updating = false
                return
            }
            if (error as? APIError)?.status == 404 {
                chats.removeAll { $0.id == id }
                currentID = nil
            }
            if savedCopy != nil {
                current = nil
                savedCopy = nil
            }
            ErrorBanner.shared.show(error)
        }
    }

    func remove(_ id: String) async {
        do {
            try await api.perform(.delete, "/ai/chats/\(Self.enc(id))")
        } catch {
            if (error as? APIError)?.status != 404 {
                ErrorBanner.shared.show(error)
                return
            }
        }
        chats.removeAll { $0.id == id }
        if currentID == id { newChat() }
    }

    /// Stops the open chat's turn; it ends with what it did so far.
    func stop() async {
        guard let id = current?.id, !id.isEmpty else { return }
        do {
            try await api.perform(.post, "/ai/chats/\(Self.enc(id))/stop", body: Empty())
            if following == nil { follow(id) }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// Moves the open chat to the page the user looks at: its next turns are about that page.
    func moveHere() async {
        guard var c = current, let before = c.page, !c.id.isEmpty else { return }
        let page = context().page
        c.page = page
        current = c
        do {
            struct Body: Encodable { let page: String }
            let r = try await api.send(.post, "/ai/chats/\(Self.enc(c.id))/page", body: Body(page: page),
                                       as: AssistantQueueResult.self)
            summary(r.chat)
        } catch {
            if current?.id == c.id { current?.page = before }
            ErrorBanner.shared.show(error)
        }
    }

    // MARK: Sending

    private var language: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier
        return preferred?.hasPrefix("de") == true ? "de" : "en"
    }

    private func input(text: String, attachments: [AssistantOutgoingAttachment]) -> AssistantChatInput {
        let here = context()
        return AssistantChatInput(
            text: text, attachments: attachments, page: current?.page ?? here.page, year: here.year,
            lang: language, today: AssistantDates.day()
        )
    }

    /// Sends a message; while a turn runs, it waits on the server and goes next. Throws when it
    /// couldn't wait (the composer gets the text back).
    func send(_ text: String, attachments: [AssistantOutgoingAttachment] = []) async throws {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !attachments.isEmpty else { return }
        let input = input(text: message, attachments: attachments)
        if busy {
            let shown = AssistantQueued(
                id: "local-\(UUID().uuidString)", text: message,
                attachments: attachments.isEmpty ? nil : attachments.map { .init(kind: $0.kind, name: $0.name) }
            )
            try await enqueue(shown, input: input)
            return
        }
        let item = AssistantItem.user(
            text: message,
            attachments: attachments.map { .init(kind: $0.kind, name: $0.name, url: $0.kind == "image" ? $0.url : nil) }
        )
        if current == nil {
            current = AssistantChat(
                id: "", title: String((message.isEmpty ? attachments[0].name : message).prefix(60)),
                status: "idle", items: [], rev: 0, usage: nil, page: input.page, queued: []
            )
        }
        guard var c = current else { return }
        // A new message instead of an answer: the question stays unanswered.
        if let open = openQuestion() {
            var skipped = open.question
            skipped.skipped = true
            c.items[open.index] = .question(skipped)
        }
        c.items.append(item)
        current = c
        let path = c.id.isEmpty ? "/ai/chats" : "/ai/chats/\(Self.enc(c.id))/messages"
        let request = try jsonRequest(.post, path, body: input)
        start(c.id.isEmpty ? nil : c.id, request: request)
    }

    /// A message while the open chat's turn runs: shown as waiting right away, kept on the
    /// server, which sends it once the turn is over.
    private func enqueue(_ shown: AssistantQueued, input: AssistantChatInput) async throws {
        guard let id = current?.id, !id.isEmpty else {
            // A new chat gets its id with the first answer: nothing to wait in yet.
            let message = String(localized: "Just a moment, the chat is starting.")
            ErrorBanner.shared.show(message)
            throw AssistantStoreError.notYet(message)
        }
        current?.queued.append(shown)
        do {
            let r = try await api.send(.post, "/ai/chats/\(Self.enc(id))/queue", body: input, as: AssistantQueueResult.self)
            summary(r.chat)
            guard current?.id == id else { return }
            current?.queued = Self.queued(r.chat, before: current?.queued.filter { $0.id != shown.id } ?? [])
            current?.status = r.chat.status
            // The turn was over by then: the message started the next one.
            if r.chat.isRunning, following == nil { follow(id) }
        } catch {
            if current?.id == id { current?.queued.removeAll { $0.id == shown.id } }
            ErrorBanner.shared.show(error)
            throw error
        }
    }

    /// Takes back a waiting message of the open chat (unless its turn started already).
    func unqueue(_ entry: String) async {
        guard let id = current?.id, !id.isEmpty, !entry.hasPrefix("local-") else { return }
        current?.queued.removeAll { $0.id == entry }
        do {
            struct Body: Encodable { let id: String }
            let r = try await api.send(.post, "/ai/chats/\(Self.enc(id))/unqueue", body: Body(id: entry),
                                       as: AssistantQueueResult.self)
            if current?.id == id { current?.queued = Self.queued(r.chat, before: current?.queued ?? []) }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// The open chat's question that waits for an answer, with its position.
    func openQuestion() -> (index: Int, question: AssistantQuestion)? {
        guard let items = current?.items, !busy, savedCopy == nil,
              let index = items.lastIndex(where: { if case .question = $0 { true } else { false } }),
              case let .question(q) = items[index], q.answer == nil, !q.skipped,
              !items[(index + 1)...].contains(where: \.isUser)
        else { return nil }
        return (index, q)
    }

    /// Answers the open question of the current chat, and the assistant goes on.
    func answer(selected: [String], text: String) {
        let own = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = current, !c.id.isEmpty, let open = openQuestion(), !busy,
              !selected.isEmpty || !own.isEmpty else { return }
        let (index, q) = open
        var answered = q
        answered.answer = .init(selected: selected, text: own.isEmpty ? nil : own)
        current?.items[index] = .question(answered)
        let here = context()
        let body = AssistantAnswerInput(
            id: q.id, selected: selected, text: own.isEmpty ? nil : own, page: c.page ?? here.page,
            year: here.year, lang: language, today: AssistantDates.day()
        )
        do {
            start(c.id, request: try jsonRequest(.post, "/ai/chats/\(Self.enc(c.id))/answer", body: body))
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    private func jsonRequest(_ method: HTTPMethod, _ sub: String, body: some Encodable) throws -> URLRequest {
        let data = try APIClient.encoder.encode(body)
        var req = api.client.request(method, api.path(sub), body: data)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return req
    }

    /// Sends a message (or an answer) with `request`, then follows the turn.
    private func start(_ id: String?, request: URLRequest) {
        sending = true
        activity = .init(activity: .init(kind: "thinking"), at: .now)
        follow(id, first: request)
    }

    // MARK: Following

    func unfollow() {
        following?.cancel()
        following = nil
    }

    /// A view shows the store (`onAppear`).
    func addViewer() { viewers += 1 }

    /// A view showing the store went away; the last one stops following (the turn goes on on
    /// the server).
    func removeViewer() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { unfollow() }
    }

    /// The first time the assistant shows in a session, it opens on the latest chat if that was
    /// active in the last `within` (or still runs), so the conversation goes on where it was.
    func restoreLatest(within: TimeInterval = 12 * 3600, now: Date = .now, follow: Bool = true) async {
        guard !restoredLatest else { return }
        restoredLatest = true
        let before = picks
        if !chatsLoaded { await loadChats() }
        // Meanwhile the user picked a chat or asked for a new one.
        guard picks == before, current == nil, currentID == nil, let latest = chats.first,
              latest.isRunning || (latest.updatedDate.map { now.timeIntervalSince($0) < within } ?? false)
        else { return }
        await open(latest.id, follow: follow)
    }

    /// Starts a new chat unless the open one is still empty (no duplicates of empty chats).
    func newChatUnlessEmpty() {
        restoredLatest = true
        if currentID != nil || !isEmptyChat { newChat() } else { picks += 1 }
    }

    /// The open chat has nothing in it yet.
    var isEmptyChat: Bool { current?.items.isEmpty ?? true }

    /// Follows a chat until no turn runs in it: with `first` (a message being sent), then with
    /// follow requests from what this device has. The server runs the turn either way, so a
    /// stream that breaks off is simply asked for again.
    private func follow(_ id: String?, first: URLRequest? = nil) {
        unfollow()
        followID += 1
        let token = followID
        following = Task { [weak self] in
            await self?.followLoop(id, first: first, token: token)
        }
    }

    private func followLoop(_ id: String?, first: URLRequest?, token: Int) async {
        var chatID = id
        var request = first
        var failures = 0
        var finished = false
        while !Task.isCancelled {
            var ended = false
            var heard = false
            do {
                let req: URLRequest
                if let r = request {
                    req = r
                    request = nil
                } else if let chatID {
                    var r = api.client.request(.get, api.path("/ai/chats/\(Self.enc(chatID))/events"),
                                               query: ["since": String(current?.id == chatID ? current?.rev ?? 0 : 0)])
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req = r
                } else {
                    break
                }
                var parser = AssistantSSEParser()
                for try await line in try await api.client.lines(req) {
                    if Task.isCancelled { break }
                    guard let (name, data) = parser.feed(line), name != "ping" else { continue }
                    heard = true
                    guard let event = try? AssistantChatEvent.parse(event: name, data: data) else { continue }
                    if case let .chat(s) = event, chatID == nil { chatID = s.id }
                    if case .end = event { ended = true }
                    if let chatID { apply(chatID, event) }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                if first != nil, !heard, sending {
                    // The message didn't get through: the chat says so (it stays visible).
                    sending = false
                    failed(error.localizedDescription)
                    if (error as? APIError)?.status == nil { await loadChats() } // maybe it did
                    break
                }
                // Refused (the chat is gone, or no longer ours): following won't help.
                if let status = (error as? APIError)?.status, status < 500, status != 429 { break }
                failures += 1
            }
            sending = false
            finished = ended
            if Task.isCancelled || ended { break }
            // Reconnect at once after a good stream, else a little later each time.
            if heard {
                failures = 0
            } else {
                try? await Task.sleep(for: .milliseconds(min(10_000, 1000 << min(failures, 4))))
            }
        }
        if followID == token {
            following = nil
            sending = false
            if current?.id == chatID, current?.isRunning != true { activity = nil }
        }
        // The copy on the device is the state the chat was opened in: after a turn, the new one.
        if finished, let chatID, api.client.cache != nil {
            _ = try? await chatState(chatID).fetch()
        }
    }

    private func failed(_ text: String) {
        if current != nil {
            current?.items.append(.error(text: text))
            if current?.id.isEmpty == true { current?.status = "idle" }
        }
        activity = nil
    }

    /// Keeps a chat's summary in the list (the latest first).
    private func summary(_ s: AssistantChatSummary) {
        var list = chats.filter { $0.id != s.id }
        list.append(s)
        chats = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The messages that wait as the server says, then the ones still on their way to it.
    static func queued(_ chat: AssistantChatSummary, before: [AssistantQueued]) -> [AssistantQueued] {
        (chat.queued ?? []) + before.filter(\.isLocal)
    }

    /// Marks an item as seen; returns the areas it changed if it is new to this device.
    @discardableResult
    private func markSeen(_ item: AssistantItem) -> [DataArea] {
        switch item {
        case let .change(change):
            guard seen.insert("change:" + change.id).inserted else { return [] }
            return AssistantChangeAreas.areas(change: change.change, undo: change.undo)
        case let .tool(tool) where tool.status == "ok":
            guard seen.insert("tool:" + tool.id).inserted else { return [] }
            return AssistantChangeAreas.areas(tool: tool.name)
        default:
            return []
        }
    }

    /// What a chat's stream says (exposed for tests).
    func apply(_ id: String, _ event: AssistantChatEvent) {
        // A new chat gets its id with the first event.
        if var c = current, c.id.isEmpty, case .chat = event, currentID == nil {
            c.id = id
            current = c
            currentID = id
        }
        let isOpen = current?.id == id
        switch event {
        case let .chat(s):
            summary(s)
            guard isOpen, var c = current else { break }
            c.title = s.title
            c.status = s.status
            c.usage = s.usage ?? c.usage
            c.page = s.page ?? c.page
            c.queued = Self.queued(s, before: c.queued)
            current = c
            // From the server: with the items since the copy's revision, the chat is up to date.
            savedCopy = nil
            if let a = s.activity, s.isRunning {
                if activity?.activity != a { activity = .init(activity: a, at: .now) }
            } else {
                activity = nil
            }
        case let .items(rev, items):
            guard isOpen, var c = current else { break }
            var changed: [DataArea] = []
            for (seq, item) in items where seq >= 0 {
                while c.items.count <= seq { c.items.append(.unknown(kind: "")) }
                c.items[seq] = item
                changed += markSeen(item)
            }
            if let rev { c.rev = max(c.rev, rev) }
            current = c
            let areas = AssistantChangeAreas.unique(changed)
            if !areas.isEmpty { onChange(areas) }
        case let .delta(seq, text):
            guard isOpen, var c = current, c.items.indices.contains(seq),
                  case let .assistant(before) = c.items[seq] else { break }
            c.items[seq] = .assistant(text: before + text)
            current = c
            activity = .init(activity: .init(kind: "writing"), at: .now)
        case let .end(deleted):
            if deleted {
                chats.removeAll { $0.id == id }
                if isOpen { newChat() }
            } else if isOpen {
                current?.status = "idle"
                activity = nil
            }
        case .reconnect:
            break
        }
    }

    /// A tool call's result, as far as the chat keeps it.
    func toolResult(_ id: String) -> String? {
        for item in current?.items ?? [] {
            if case let .tool(t) = item, t.id == id { return t.result }
        }
        return nil
    }

    // MARK: Undo

    /// Undoes a change of the open chat: replays its undo requests on the family API, then tells
    /// the chat (the model hears it with the next message).
    func undo(_ changeID: String) async {
        guard let chat = current, !chat.id.isEmpty, savedCopy == nil,
              let index = chat.items.firstIndex(where: { if case let .change(c) = $0 { c.id == changeID } else { false } }),
              case let .change(change) = chat.items[index], !change.undone else { return }
        do {
            for step in change.undo { try await replay(step) }
            if current?.id == chat.id, current?.items.indices.contains(index) == true {
                var done = change
                done.undone = true
                current?.items[index] = .change(done)
            }
            onChange(AssistantChangeAreas.areas(change: change.change, undo: change.undo))
            ErrorBanner.shared.success(String(localized: "Undone"))
        } catch {
            ErrorBanner.shared.show(String(localized: "Couldn’t undo: \(error.localizedDescription)"))
            return
        }
        struct Body: Encodable { let id: String }
        try? await api.perform(.post, "/ai/chats/\(Self.enc(chat.id))/undone", body: Body(id: changeID))
    }

    /// One undo request, relative to the family.
    private func replay(_ step: AssistantUndoStep) async throws {
        guard let method = HTTPMethod(rawValue: step.method.uppercased()) else { return }
        let body = try step.body.map { try APIClient.encoder.encode($0) }
        let req = api.client.request(method, api.path(step.path), body: body)
        _ = try await api.client.data(for: req)
    }

    /// A chat id in a path (uuids; `APIClient.url` encodes what needs it).
    static func enc(_ id: String) -> String { id }
}

enum AssistantStoreError: LocalizedError {
    case notYet(String)

    var errorDescription: String? {
        switch self { case let .notYet(message): message }
    }
}

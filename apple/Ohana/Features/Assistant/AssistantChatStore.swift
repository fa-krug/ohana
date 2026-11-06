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

/// What a running turn does, and since when this device knows it. While the model writes,
/// `at` is moved on at most every `AssistantChatStore.activityRefresh` (not with every piece of
/// text shown), so what reads it is drawn again about once a second, not with each piece; the
/// time of the last piece is `AssistantChatStore.lastTextAt`.
struct AssistantActivityState: Equatable {
    var activity: AssistantActivity
    var at: Date
}

/// What a turn in the open chat does, for what shows it outside the chat (the floating
/// button): assigned only when it changes, so they aren't drawn again with each piece of text.
struct AssistantTurn: Equatable {
    /// A turn runs (or a message is on its way).
    var running = false
    /// What it does right now ("Thinking…", a tool's label); empty while none runs.
    var status = ""
    /// The chat's title (empty for a new chat).
    var title = ""

    static let idle = AssistantTurn()
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
    private(set) var chats: [AssistantChatSummary] = [] { didSet { updateTurn() } }
    private(set) var chatsLoaded = false
    private(set) var currentID: String? { didSet { updateTurn() } }
    /// The open chat, once loaded (or a new one being started).
    private(set) var current: AssistantChat? { didSet { updateTurn() } }
    /// Grows each time another chat is shown (opened, or a new one started); not when a new chat
    /// gets its id from the server. The chat view starts its window, its animations and its
    /// cross-fade from it.
    private(set) var session = 0
    /// The chat `currentID` names couldn't be loaded, and there is no copy on the device to show.
    private(set) var openError: String?
    /// Set while `current` is the copy on the device, until the server or the chat's stream
    /// answers: its changes can't be undone and its question not answered meanwhile.
    private(set) var savedCopy: AssistantSavedCopy?
    /// Set while a turn runs.
    private(set) var activity: AssistantActivityState? { didSet { updateTurn() } }
    /// When the stream last wrote a piece of text into the open chat (not observed: it changes
    /// with every piece; `activity.at` moves on more slowly).
    @ObservationIgnored private(set) var lastTextAt: Date?
    /// A message is on its way to the server.
    private(set) var sending = false { didSet { updateTurn() } }
    /// Notes or suggestions are being written / added on this device (they're marked answered
    /// only after that): busy meanwhile, so the card can't be applied twice.
    private var applying = false
    /// What the turn in the open chat does, as far as this device follows it (`AssistantTurn`).
    private(set) var turn = AssistantTurn.idle
    /// `turn.running` alone, for what shows only that (the floating button): not drawn again with each step.
    private(set) var turnRunning = false
    /// Which suggestions the user ticked, per suggestions item (until they're answered; kept here
    /// so a card rebuilt while scrolling keeps them).
    private(set) var suggestionPicks: [String: Set<Int>] = [:]
    /// The options ticked on a question with several to pick, per question (until it's answered;
    /// the composer's Send answers with them too).
    private(set) var questionPicks: [String: [String]] = [:]

    @ObservationIgnored let api: FamilyAPI
    /// Called after the assistant (or an undo) changed something, so the screens reload it.
    @ObservationIgnored var onChange: ([DataArea]) -> Void = { _ in }
    /// The page the user looks at (overview | calendar | finance | meals | appointments |
    /// chores | settings), sent along with every message (with this year).
    @ObservationIgnored var page = "overview"

    private func context() -> (page: String, year: Int) {
        (page, Calendar.current.component(.year, from: .now))
    }

    /// Changes and tool calls this device has seen, so it reloads the data only for new ones.
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var following: Task<Void, Never>? { didSet { updateTurn() } }
    @ObservationIgnored private var followID = 0
    /// Text the stream wrote that isn't shown yet: pieces arrive many times a second, and each
    /// shown one draws the chat again, so they're shown together, at most every `deltaInterval`.
    @ObservationIgnored private var pendingDeltas: [(chat: String, seq: Int, text: String)] = []
    @ObservationIgnored private var deltaFlush: Task<Void, Never>?
    static let deltaInterval: Duration = .milliseconds(80)
    /// While the model writes, `activity` (its `at`) is assigned again at most this often.
    static let activityRefresh: TimeInterval = 1
    /// How many views show the store (the panel and the page may both); the last one to go
    /// stops following.
    @ObservationIgnored private var viewers = 0
    /// The latest chat was opened once (the panel opens on it rather than on an empty chat).
    @ObservationIgnored private var restoredLatest = false
    /// The chat `restoreLatest` opened, and `picks` then: while the user hasn't picked another,
    /// it gives way to a new chat once it has gone quiet.
    @ObservationIgnored private var restored: (id: String, picks: Int)?
    /// Grows with every chat the user opens or starts.
    @ObservationIgnored private var picks = 0

    /// What every request of a turn tells about the user's Reminders (nil: nothing, so the
    /// Reminders tools are off); tests replace it.
    @ObservationIgnored var remindersContext: () async -> AssistantRemindersContext?
    /// The same for the device's calendars (nil: the Apple Calendar tools are off); tests replace it.
    @ObservationIgnored var calendarContext: () async -> AssistantCalendarContext?
    /// The family's knowledge folder on this device, for the notes the assistant writes (nil: the
    /// demo, no knowledge base, a viewer); every request carries its id while it's linked here
    /// (without it, the notes tool is off). The chat view sets it; tests replace it.
    @ObservationIgnored var knowledgeNotes: () -> AssistantKnowledgeNotes? = { nil }
    /// Reads a chat's answers ahead, off the main thread, before it's shown
    /// (`AssistantMarkdownCache.prewarm`); tests replace it.
    @ObservationIgnored var prewarm: ([AssistantItem]) async -> Void = { await AssistantMarkdownCache.prewarm($0) }
    /// The knowledge folder the last request named: notes are only written into that one.
    @ObservationIgnored private var sentKnowledgeFolder: String?

    init(api: FamilyAPI) {
        self.api = api
        remindersContext = { await AssistantRemindersContext.current(for: api) }
        calendarContext = { await AssistantCalendarContext.current(for: api) }
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

    /// A turn runs in the open chat (or a message is on its way). A question or edit that waits
    /// for the user ends the turn on the server, so once one shows the chat isn't busy any more,
    /// even before the stream says the turn ended (up to a poll later): the card can be answered
    /// at once, without "Thinking…" under it.
    var busy: Bool { applying || ((sending || current?.isRunning == true) && pendingWaiting() == nil) }

    var isFollowing: Bool { following != nil }

    var ready: Bool { settings?.configured == true }

    // MARK: Loading

    func loadSettings() async {
        let get = Self.settingsRequest(api)
        if settings == nil {
            // The copy on the device, read and decoded off the main thread.
            let copy = await get.savedOffMain()
            if settings == nil { settings = copy?.value }
        }
        do {
            let fetched = try await get.fetch()
            if settings != fetched { settings = fetched }
            if settingsError != nil { settingsError = nil }
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

    /// Before the assistant first shows: its settings, the chats and, only when the assistant
    /// will open on it (`restoreLatest`), the latest chat with its answers' Markdown read, so the
    /// panel has them drawn before it slides in (a running turn isn't followed: no one looks yet).
    /// Most of the time it opens on a new chat: then there's nothing heavy to prepare.
    func preload() async {
        // The settings beside the chats and the latest chat: neither waits for the other.
        async let settingsLoaded: Void = loadSettingsIfNeeded()
        // Decided on the list's copy on the device; the server's list after it (the welcome's
        // recent chats).
        await restoreLatest(follow: false)
        if !chatsLoaded { await loadChats() }
        await settingsLoaded
    }

    private func loadSettingsIfNeeded() async {
        if settings == nil { await loadSettings() }
    }

    func loadChats() async {
        let get = Self.chatsRequest(api)
        await loadSavedChats()
        do {
            let fetched = try await get.fetch().chats
            if chats != fetched { chats = fetched }
            if !chatsLoaded { chatsLoaded = true }
        } catch {
            // Offline or not allowed: the list stays as it is.
        }
    }

    /// The list's copy on the device, read and decoded off the main thread. Only into an empty
    /// list: the server's chats are never replaced by the copy.
    private func loadSavedChats() async {
        guard !chatsLoaded, chats.isEmpty else { return }
        let copy = await Self.chatsRequest(api).savedOffMain()
        if !chatsLoaded, chats.isEmpty, let copy { chats = copy.value.chats }
    }

    /// Back in the app (another device may have chatted meanwhile): the list and the open chat
    /// catch up.
    func refresh() async {
        // The list beside the open chat.
        async let listed: Void = loadChats()
        if let id = currentID, savedCopy?.updating == false { await fetch(id, follow: false) }
        if let id = current?.id, !id.isEmpty, following == nil { follow(id) }
        await listed
    }

    /// Tries again to reach the server for the open chat's copy and the list (the connection is
    /// back).
    func retrySaved() async {
        async let listed: Void = loadChats()
        if let id = currentID, savedCopy?.updating == false {
            await fetch(id, follow: true)
        } else if let id = currentID, openError != nil {
            await open(id)
        }
        await listed
    }

    /// Shows a chat as given, marking what it changed so far as seen (previews and tests).
    func show(_ chat: AssistantChat) {
        unfollow()
        for item in chat.items { markSeen(item) }
        currentID = chat.id.isEmpty ? nil : chat.id
        current = chat
        savedCopy = nil
        openError = nil
        session += 1
    }

    func newChat() {
        picks += 1
        unfollow()
        currentID = nil
        current = nil
        savedCopy = nil
        openError = nil
        activity = nil
        session += 1
    }

    /// Opens a chat (a running turn goes on either way); `follow`: its running turn too.
    func open(_ id: String, follow following: Bool = true) async {
        if id == currentID, current != nil {
            // Its copy on the device, the server out of reach before: ask again.
            if savedCopy?.updating == false { await fetch(id, follow: following) }
            return
        }
        picks += 1
        let pick = picks
        unfollow()
        // Asked again for the chat that couldn't load: the same one, still (no new session).
        if id != currentID || openError == nil { session += 1 }
        currentID = id
        current = nil
        savedCopy = nil
        openError = nil
        activity = nil
        // The copy on the device, read and decoded off the main thread (a long chat's items take a
        // while); meanwhile another chat may have been picked, which then loads itself.
        let copy = await chatState(id).savedOffMain()
        guard picks == pick, currentID == id else { return }
        // Its answers' Markdown read off the main thread before it's drawn.
        if let copy {
            await prewarm(copy.value.items)
            guard picks == pick, currentID == id else { return }
        }
        if current == nil, let copy {
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
            // Read off the main thread before it's drawn (what the copy had is read already).
            await prewarm(s.items)
            guard currentID == id, current == shown else { return }
            for item in s.items { markSeen(item) }
            // The same as shown (nothing new since): the chat isn't drawn again.
            let chat = Self.chat(id, s)
            if current != chat { current = chat }
            if savedCopy != nil { savedCopy = nil }
            summary(s.chat)
            if s.chat.isRunning, following { follow(id) }
        } catch {
            guard currentID == id, !(error is CancellationError) else { return }
            if savedCopy != nil, APIError.isTemporary(error) {
                // The copy stays: silently, unless the server answered with an error.
                savedCopy?.updating = false
                ErrorBanner.shared.showUnlessUnreachable(error)
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
            // Nothing to show: the chat says so (and tries again), not a placeholder for good.
            if currentID == id, current == nil {
                openError = error.localizedDescription
                if APIError.isUnreachable(error) { return }
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

    /// The id of the knowledge folder linked here, for a request (remembered as the one named).
    private func knowledgeFolder() -> String? {
        let id = knowledgeNotes()?.folderID
        sentKnowledgeFolder = id
        return id
    }

    private func input(text: String, attachments: [AssistantOutgoingAttachment]) async -> AssistantChatInput {
        let reminders = await remindersContext()
        let calendar = await calendarContext()
        let here = context()
        return AssistantChatInput(
            text: text, attachments: attachments, page: current?.page ?? here.page, year: here.year,
            lang: language, today: AssistantDates.day(), reminders: reminders, appleCalendar: calendar,
            knowledgeFolder: knowledgeFolder()
        )
    }

    /// The open question the composer answers: a message without attachments answers it (with
    /// the options ticked on it), one with attachments goes as a new message and leaves it unanswered.
    var composerAnswers: Bool { openQuestion() != nil }

    /// Sends a message; while a turn runs, it waits on the server and goes next. Throws when it
    /// couldn't wait (the composer gets the text back). While a question waits, a message without
    /// attachments is its answer.
    func send(_ text: String, attachments: [AssistantOutgoingAttachment] = []) async throws {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !attachments.isEmpty else { return }
        if attachments.isEmpty, !message.isEmpty, !busy, let open = openQuestion(), current?.id.isEmpty == false {
            answer(selected: open.question.multiple ? picks(open.question) : [], text: message)
            return
        }
        let input = await input(text: message, attachments: attachments)
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
        // A new message instead of an answer: the question (or Reminders, calendar or notes edit,
        // or the suggestions) stays unanswered.
        if let open = openWaiting() {
            switch c.items[open] {
            case var .question(q):
                q.skipped = true
                c.items[open] = .question(q)
            case var .reminders(edit):
                edit.skipped = true
                c.items[open] = .reminders(edit)
            case var .calendar(edit):
                edit.skipped = true
                c.items[open] = .calendar(edit)
            case var .suggestions(edit):
                edit.skipped = true
                c.items[open] = .suggestions(edit)
            case var .notes(edit):
                edit.skipped = true
                c.items[open] = .notes(edit)
            default:
                break
            }
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
            // Worked out before the assignment: reading `current` inside `current?.queued = …`
            // overlaps its modification (a fatal exclusivity conflict).
            let queued = Self.queued(r.chat, before: current?.queued.filter { $0.id != shown.id } ?? [])
            current?.queued = queued
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
            if current?.id == id {
                let queued = Self.queued(r.chat, before: current?.queued ?? [])
                current?.queued = queued
            }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// The position of the open chat's question, Reminders, calendar or notes edit or suggestions
    /// that wait for the user (the last of them, as on the server: one waits at a time).
    private func openWaiting() -> Int? { pendingWaiting() }

    /// See `openWaiting`; `busy` rests on it (an answer sent marks the item answered first).
    private func pendingWaiting() -> Int? {
        guard let items = current?.items, savedCopy == nil,
              let index = items.lastIndex(where: \.canWait),
              !items[(index + 1)...].contains(where: \.isUser)
        else { return nil }
        switch items[index] {
        case let .question(q) where q.answer == nil && !q.skipped: return index
        case let .reminders(edit) where edit.answer == nil && !edit.skipped: return index
        case let .calendar(edit) where edit.answer == nil && !edit.skipped: return index
        case let .suggestions(edit) where edit.answer == nil && !edit.skipped: return index
        case let .notes(edit) where edit.answer == nil && !edit.skipped: return index
        default: return nil
        }
    }

    /// The position of the item that waits for the user (the chat works it out once for its items).
    var waitingIndex: Int? { openWaiting() }

    /// The open chat's question that waits for an answer, with its position.
    func openQuestion() -> (index: Int, question: AssistantQuestion)? {
        guard let index = openWaiting(), case let .question(q) = current?.items[index] else { return nil }
        return (index, q)
    }

    /// The open chat's Reminders edit that waits for the user to apply or decline it.
    func openRemindersEdit() -> (index: Int, edit: AssistantRemindersEdit)? {
        guard let index = openWaiting(), case let .reminders(edit) = current?.items[index] else { return nil }
        return (index, edit)
    }

    /// The open chat's calendar edit that waits for the user to apply or decline it.
    func openCalendarEdit() -> (index: Int, edit: AssistantCalendarEdit)? {
        guard let index = openWaiting(), case let .calendar(edit) = current?.items[index] else { return nil }
        return (index, edit)
    }

    /// The open chat's suggestions that wait for the user to add (some of) them or none.
    func openSuggestions() -> (index: Int, edit: AssistantSuggestions)? {
        guard let index = openWaiting(), case let .suggestions(edit) = current?.items[index] else { return nil }
        return (index, edit)
    }

    /// The open chat's notes edit that waits for the user to apply or decline it.
    func openNotesEdit() -> (index: Int, edit: AssistantNotesEdit)? {
        guard let index = openWaiting(), case let .notes(edit) = current?.items[index] else { return nil }
        return (index, edit)
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
        questionPicks[q.id] = nil
        // Nothing else is sent while the Reminders and calendars are read.
        sending = true
        Task {
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            let here = context()
            let body = AssistantAnswerInput(
                id: q.id, selected: selected, text: own.isEmpty ? nil : own, page: c.page ?? here.page,
                year: here.year, lang: language, today: AssistantDates.day(), reminders: reminders,
                appleCalendar: calendar, knowledgeFolder: knowledgeFolder()
            )
            post(c.id, "answer", body: body)
        }
    }

    /// How applying a Reminders (or calendar) edit started.
    enum RemindersApplyStart: Equatable {
        /// Applied (as far as it went) and answered; the assistant goes on.
        case answered
        /// Ohana may not use Reminders (asked, and the user said no, or not allowed before), or
        /// the calendars.
        case noAccess
        /// It doesn't wait any more (answered elsewhere, a turn runs).
        case notWaiting
    }

    /// Applies the open Reminders edit `id` on this device (asking for the access first when it
    /// wasn't asked for yet), then answers with each op's result and the Reminders after it.
    func applyReminders(_ id: String, store: RemindersStore = .shared) async -> RemindersApplyStart {
        guard let open = openRemindersEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else {
            return .notWaiting
        }
        store.refreshAccess()
        if store.access == .notDetermined {
            do {
                try await store.requestAccess()
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
        guard store.access.isGranted else { return .noAccess }
        // Asking for the access took a while: still the same chat, still waiting?
        guard current?.id == chatID, let again = openRemindersEdit(), again.edit.id == id else { return .notWaiting }
        sending = true
        let results = AssistantRemindersApply.perform(again.edit.ops, on: store)
        answerReminders(again, chatID: chatID, answer: .init(applied: true, results: results))
        return .answered
    }

    /// Declines the open Reminders edit `id`: nothing changes, and the assistant hears so.
    func declineReminders(_ id: String) {
        guard let open = openRemindersEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        sending = true
        answerReminders(open, chatID: chatID, answer: .init(applied: false, results: nil))
    }

    private func answerReminders(_ open: (index: Int, edit: AssistantRemindersEdit), chatID: String,
                                 answer: AssistantRemindersEdit.Answer) {
        var answered = open.edit
        answered.answer = answer
        current?.items[open.index] = .reminders(answered)
        let here = context()
        let page = current?.page ?? here.page
        Task {
            // After the change: what the assistant reads next is how the Reminders are now.
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            post(chatID, "reminders", body: Self.remindersAnswer(
                id: open.edit.id, answer: answer, page: page, year: here.year, lang: language,
                today: AssistantDates.day(), reminders: reminders, appleCalendar: calendar,
                knowledgeFolder: knowledgeFolder()
            ))
        }
    }

    /// The body of POST /ai/chats/{id}/reminders.
    static func remindersAnswer(id: String, answer: AssistantRemindersEdit.Answer, page: String, year: Int,
                                lang: String, today: String, reminders: AssistantRemindersContext?,
                                appleCalendar: AssistantCalendarContext? = nil,
                                knowledgeFolder: String? = nil) -> AssistantRemindersAnswerInput {
        AssistantRemindersAnswerInput(
            id: id, applied: answer.applied, results: answer.applied ? answer.results ?? [] : nil, page: page,
            year: year, lang: lang, today: today, reminders: reminders, appleCalendar: appleCalendar,
            knowledgeFolder: knowledgeFolder
        )
    }

    /// Applies the open calendar edit `id` on this device, then answers with each op's result and
    /// the calendars after it. The access isn't asked for here: without it there were no tools.
    func applyCalendar(_ id: String, store: DeviceCalendarStore = .shared) -> RemindersApplyStart {
        guard let open = openCalendarEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else {
            return .notWaiting
        }
        store.refreshAccess()
        guard store.hasAccess else { return .noAccess }
        sending = true
        let results = AssistantCalendarApply.perform(open.edit.ops, on: store)
        answerCalendar(open, chatID: chatID, answer: .init(applied: true, results: results))
        return .answered
    }

    /// Declines the open calendar edit `id`: nothing changes, and the assistant hears so.
    func declineCalendar(_ id: String) {
        guard let open = openCalendarEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        sending = true
        answerCalendar(open, chatID: chatID, answer: .init(applied: false, results: nil))
    }

    private func answerCalendar(_ open: (index: Int, edit: AssistantCalendarEdit), chatID: String,
                                answer: AssistantCalendarEdit.Answer) {
        var answered = open.edit
        answered.answer = answer
        current?.items[open.index] = .calendar(answered)
        let here = context()
        let page = current?.page ?? here.page
        Task {
            // After the change: what the assistant reads next is how the calendars are now.
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            post(chatID, "calendar", body: Self.calendarAnswer(
                id: open.edit.id, answer: answer, page: page, year: here.year, lang: language,
                today: AssistantDates.day(), reminders: reminders, appleCalendar: calendar,
                knowledgeFolder: knowledgeFolder()
            ))
        }
    }

    /// The body of POST /ai/chats/{id}/calendar.
    static func calendarAnswer(id: String, answer: AssistantCalendarEdit.Answer, page: String, year: Int,
                               lang: String, today: String, reminders: AssistantRemindersContext?,
                               appleCalendar: AssistantCalendarContext?,
                               knowledgeFolder: String? = nil) -> AssistantCalendarAnswerInput {
        AssistantCalendarAnswerInput(
            id: id, applied: answer.applied, results: answer.applied ? answer.results ?? [] : nil, page: page,
            year: year, lang: lang, today: today, reminders: reminders, appleCalendar: appleCalendar,
            knowledgeFolder: knowledgeFolder
        )
    }

    // MARK: Notes

    /// Writes the notes of the open notes edit `id` into the family's knowledge folder on this
    /// device, then answers with each op's result. Without the folder (or another one than the
    /// requests named) every op fails, and the assistant hears so.
    func applyNotes(_ id: String) async -> RemindersApplyStart {
        guard let open = openNotesEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else {
            return .notWaiting
        }
        sending = true
        applying = true
        defer { applying = false }
        let results = await AssistantNotesApply.perform(open.edit.ops, notes: knowledgeNotes(),
                                                        folderID: sentKnowledgeFolder)
        if results.contains(where: \.ok) { onChange([.knowledge]) }
        // Writing took a while: the item may have moved (a reload), so it's looked up again.
        let index = current?.id == chatID
            ? current?.items.firstIndex { if case let .notes(e) = $0 { e.id == id } else { false } }
            : nil
        answerNotes((index ?? open.index, open.edit), chatID: chatID, answer: .init(applied: true, results: results))
        return .answered
    }

    /// Declines the open notes edit `id`: nothing is written, and the assistant hears so.
    func declineNotes(_ id: String) {
        guard let open = openNotesEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        sending = true
        answerNotes(open, chatID: chatID, answer: .init(applied: false, results: nil))
    }

    private func answerNotes(_ open: (index: Int, edit: AssistantNotesEdit), chatID: String,
                             answer: AssistantNotesEdit.Answer) {
        if current?.id == chatID, let items = current?.items, open.index < items.count, case .notes = items[open.index] {
            var answered = open.edit
            answered.answer = answer
            current?.items[open.index] = .notes(answered)
        }
        let here = context()
        let page = current?.page ?? here.page
        Task {
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            post(chatID, "notes", body: Self.remindersAnswer(
                id: open.edit.id, answer: answer, page: page, year: here.year, lang: language,
                today: AssistantDates.day(), reminders: reminders, appleCalendar: calendar,
                knowledgeFolder: knowledgeFolder()
            ))
        }
    }

    /// The options ticked on a question with several to pick.
    func picks(_ question: AssistantQuestion) -> [String] {
        questionPicks[question.id] ?? []
    }

    /// Ticks or unticks `option` of a question with several to pick.
    func togglePick(_ question: AssistantQuestion, _ option: String) {
        var picks = picks(question)
        if let i = picks.firstIndex(of: option) { picks.remove(at: i) } else { picks.append(option) }
        questionPicks[question.id] = picks
    }

    // MARK: Suggestions

    /// The suggestions of `edit` the user ticked (at first every one this app can add).
    func picks(_ edit: AssistantSuggestions) -> Set<Int> {
        suggestionPicks[edit.id] ?? edit.initialPicks
    }

    /// Ticks or unticks suggestion `index` of `edit`.
    func togglePick(_ edit: AssistantSuggestions, _ index: Int) {
        var picks = picks(edit)
        if picks.contains(index) { picks.remove(index) } else { picks.insert(index) }
        suggestionPicks[edit.id] = picks
    }

    /// Adds the picked suggestions of the open suggestions `id` (asking for the access to
    /// Reminders first when a task or deadline is among them and it wasn't asked for yet), then
    /// answers with each one's result (the others declined) and the Reminders after it.
    func applySuggestions(_ id: String, selected: Set<Int>, reminders: RemindersStore = .shared,
                          events: (any AssistantEventCreating)? = nil) async -> RemindersApplyStart {
        guard let open = openSuggestions(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else {
            return .notWaiting
        }
        let needsReminders = open.edit.needsReminders(selected)
        if needsReminders {
            reminders.refreshAccess()
            if reminders.access == .notDetermined {
                do {
                    try await reminders.requestAccess()
                } catch {
                    ErrorBanner.shared.show(error)
                }
            }
            guard reminders.access.isGranted else { return .noAccess }
            // Asking for the access took a while: still the same chat, still waiting?
            guard current?.id == chatID, let again = openSuggestions(), again.edit.id == id else { return .notWaiting }
        }
        sending = true
        applying = true
        defer { applying = false }
        let results = await AssistantSuggestionsApply.perform(
            open.edit.ops, picks: selected, events: events ?? FamilyEventCreator(api: api),
            reminders: needsReminders ? reminders : nil, defaultListID: needsReminders ? reminders.defaultListID : nil
        )
        if results.indices.contains(where: { results[$0].ok && open.edit.ops[$0].kind == .event }) {
            onChange([.events])
        }
        // Adding took a while: the item may have moved (a reload), so it's looked up again.
        let index = current?.id == chatID
            ? current?.items.firstIndex { if case let .suggestions(e) = $0 { e.id == id } else { false } }
            : nil
        answerSuggestions((index ?? open.index, open.edit), chatID: chatID,
                          answer: .init(applied: true, results: results))
        return .answered
    }

    /// Adds none of the open suggestions `id`, and the assistant hears so.
    func declineSuggestions(_ id: String) {
        guard let open = openSuggestions(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        sending = true
        answerSuggestions(open, chatID: chatID, answer: .init(applied: false, results: nil))
    }

    private func answerSuggestions(_ open: (index: Int, edit: AssistantSuggestions), chatID: String,
                                   answer: AssistantSuggestions.Answer) {
        if current?.id == chatID, let items = current?.items, open.index < items.count,
           case .suggestions = items[open.index] {
            var answered = open.edit
            answered.answer = answer
            current?.items[open.index] = .suggestions(answered)
        }
        suggestionPicks[open.edit.id] = nil
        let here = context()
        let page = current?.page ?? here.page
        Task {
            // After the change: what the assistant reads next is how the Reminders are now.
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            post(chatID, "suggestions", body: Self.remindersAnswer(
                id: open.edit.id, answer: answer, page: page, year: here.year, lang: language,
                today: AssistantDates.day(), reminders: reminders, appleCalendar: calendar,
                knowledgeFolder: knowledgeFolder()
            ))
        }
    }

    /// Sends an answer (POST /ai/chats/{id}/{route}) and follows the turn it goes on with.
    private func post(_ chatID: String, _ route: String, body: some Encodable) {
        do {
            start(chatID, request: try jsonRequest(.post, "/ai/chats/\(Self.enc(chatID))/\(route)", body: body))
        } catch {
            sending = false
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
        flushDeltas()
    }

    /// A view shows the store (`onAppear`).
    func addViewer() { viewers += 1 }

    /// A view showing the store went away; the last one stops following (the turn goes on on
    /// the server).
    func removeViewer() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { unfollow() }
    }

    /// How recently the latest chat must have been active for the assistant to open on it.
    static let reopenWithin: TimeInterval = 15 * 60

    /// Each time the assistant shows. The first time in a session it opens on the latest chat if
    /// that still runs or was active in the last `within` (the conversation goes on where it
    /// was), else on a new chat with the recent chats on its welcome: a long chat isn't laid out
    /// only to be left. Later, a chat opened that way which the user hasn't left meanwhile gives
    /// way to a new chat once it has gone quiet.
    func restoreLatest(within: TimeInterval = reopenWithin, now: Date = .now, follow: Bool = true) async {
        guard !restoredLatest else {
            if let restored, restored.id == currentID, restored.picks == picks, !busy,
               let chat = chats.first(where: { $0.id == restored.id }), !Self.isRecent(chat, within: within, now: now) {
                self.restored = nil
                newChat()
            }
            return
        }
        restoredLatest = true
        let before = picks
        // The list on the device first: the latest chat opens without waiting for the server,
        // which is only asked when the copy has none to open.
        await loadSavedChats()
        if let latest = latest(within: within, now: now, picks: before) {
            await reopen(latest, follow: follow)
            return
        }
        guard !chatsLoaded else { return }
        await loadChats()
        if let latest = latest(within: within, now: now, picks: before) { await reopen(latest, follow: follow) }
    }

    private func reopen(_ id: String, follow: Bool) async {
        await open(id, follow: follow)
        if currentID == id { restored = (id, picks) }
    }

    /// The latest chat, if it is recent (`isRecent`) and the user hasn't picked a chat or asked
    /// for a new one meanwhile.
    private func latest(within: TimeInterval, now: Date, picks before: Int) -> String? {
        guard picks == before, current == nil, currentID == nil, let latest = chats.first,
              Self.isRecent(latest, within: within, now: now)
        else { return nil }
        return latest.id
    }

    /// The chat still runs or was active in the last `within`.
    static func isRecent(_ chat: AssistantChatSummary, within: TimeInterval, now: Date) -> Bool {
        chat.isRunning || (chat.updatedDate.map { now.timeIntervalSince($0) < within } ?? false)
    }

    // MARK: Turn

    /// Works out `turn` (and `turnRunning`) again after what it rests on changed; assigned only
    /// when different, so the bar and the toggle aren't drawn again with each piece of text.
    private func updateTurn() {
        let running = turnIsRunning
        let next = running ? AssistantTurn(running: true, status: turnStatus(), title: current?.title ?? "") : .idle
        if turn != next { turn = next }
        if turnRunning != running { turnRunning = running }
    }

    /// A turn runs in the open chat as far as this device follows it: the chat's copy may say
    /// "running" from before (a copy on the device, a stream that broke off), which isn't trusted.
    private var turnIsRunning: Bool {
        if sending { return true }
        guard following != nil, let id = currentID else { return false }
        return chats.first { $0.id == id }?.isRunning == true
    }

    /// As the chat's activity line says it, shorter.
    private func turnStatus() -> String {
        switch activity?.activity.kind {
        case "writing":
            return String(localized: "Writing…")
        case "tool":
            // The last tool call that runs: from the end, where it is.
            for item in (current?.items ?? []).reversed() {
                if case let .tool(t) = item, t.status == "running" { return AssistantToolLabels.label(t) + "…" }
            }
            return String(localized: "Thinking…")
        default:
            return String(localized: "Thinking…")
        }
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
                // Read and decoded off the main thread; only the events come here.
                for try await event in AssistantEventStream.events(try await api.client.lines(req)) {
                    if Task.isCancelled { break }
                    heard = true
                    guard let event else { continue }
                    if case let .chat(s) = event, chatID == nil { chatID = s.id }
                    if case .end = event { ended = true }
                    if let chatID { receive(chatID, event) }
                }
                flushDeltas()
            } catch {
                flushDeltas()
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
        list.sort { $0.updatedAt > $1.updatedAt }
        // Unchanged (the stream repeats the chat with every step): the list isn't drawn again.
        if list != chats { chats = list }
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

    /// An event of the stream being followed: text is gathered and shown every `deltaInterval`
    /// (`flushDeltas`), anything else after the text before it.
    private func receive(_ id: String, _ event: AssistantChatEvent) {
        guard case let .delta(seq, text) = event else {
            flushDeltas()
            apply(id, event)
            return
        }
        if let last = pendingDeltas.last, last.chat == id, last.seq == seq {
            pendingDeltas[pendingDeltas.count - 1].text += text
        } else {
            pendingDeltas.append((id, seq, text))
        }
        guard deltaFlush == nil else { return }
        deltaFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.deltaInterval)
            guard !Task.isCancelled else { return }
            self?.flushDeltas()
        }
    }

    /// Shows the text gathered from the stream (all of it in one change of the chat).
    private func flushDeltas() {
        deltaFlush?.cancel()
        deltaFlush = nil
        guard !pendingDeltas.isEmpty else { return }
        let pending = pendingDeltas
        pendingDeltas = []
        applyDeltas(pending)
    }

    /// Text written into answers of the open chat, as one change.
    private func applyDeltas(_ deltas: [(chat: String, seq: Int, text: String)]) {
        guard var c = current else { return }
        var changed = false
        for (chat, seq, text) in deltas where chat == c.id {
            guard c.items.indices.contains(seq), case let .assistant(before, sources) = c.items[seq] else { continue }
            c.items[seq] = .assistant(text: before + text, sources: sources)
            changed = true
        }
        guard changed else { return }
        current = c
        let now = Date.now
        lastTextAt = now
        // Not with every piece: what reads the activity would be drawn again with each.
        if let a = activity, a.activity.kind == "writing", now.timeIntervalSince(a.at) < Self.activityRefresh { return }
        activity = .init(activity: .init(kind: "writing"), at: now)
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
            applyDeltas([(id, seq, text)])
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

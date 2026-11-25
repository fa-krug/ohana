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
///
/// Its parts live in the `AssistantChatStore…` files beside this one, so what they write is
/// `internal(set)` and what they call is internal rather than private.
@Observable
final class AssistantChatStore {
    internal(set) var settings: AssistantSettings?
    internal(set) var settingsError: String?
    /// The user's chats, the latest first.
    internal(set) var chats: [AssistantChatSummary] = [] { didSet { updateTurn() } }
    internal(set) var chatsLoaded = false
    internal(set) var currentID: String? { didSet { updateTurn() } }
    /// The open chat, once loaded (or a new one being started).
    internal(set) var current: AssistantChat? { didSet { updateTurn() } }
    /// Grows each time another chat is shown (opened, or a new one started); not when a new chat
    /// gets its id from the server. The chat view starts its window, its animations and its
    /// cross-fade from it.
    internal(set) var session = 0
    /// The chat `currentID` names couldn't be loaded, and there is no copy on the device to show.
    internal(set) var openError: String?
    /// Set while `current` is the copy on the device, until the server or the chat's stream
    /// answers: its changes can't be undone and its question not answered meanwhile.
    internal(set) var savedCopy: AssistantSavedCopy?
    /// Set while a turn runs.
    internal(set) var activity: AssistantActivityState? { didSet { updateTurn() } }
    /// When the stream last wrote a piece of text into the open chat (not observed: it changes
    /// with every piece; `activity.at` moves on more slowly).
    @ObservationIgnored internal(set) var lastTextAt: Date?
    /// A message is on its way to the server.
    internal(set) var sending = false { didSet { updateTurn() } }
    /// Notes or suggestions are being written / added on this device (they're marked answered
    /// only after that): busy meanwhile, so the card can't be applied twice.
    var applying = false
    /// What the turn in the open chat does, as far as this device follows it (`AssistantTurn`).
    internal(set) var turn = AssistantTurn.idle
    /// `turn.running` alone, for what shows only that (the floating button): not drawn again with each step.
    internal(set) var turnRunning = false
    /// The pages requests this device is sending pages for right now (by id).
    internal(set) var pagesSending: Set<String> = []
    /// Which suggestions the user ticked, per suggestions item (until they're answered; kept here
    /// so a card rebuilt while scrolling keeps them).
    internal(set) var suggestionPicks: [String: Set<Int>] = [:]
    /// Which memory ops the user ticked, per memories item; the texts they changed; and how a
    /// Save that didn't go through for every op went (the card stays open, and the next Save
    /// tries only the rest). Kept until the item is answered.
    internal(set) var memoryPicks: [String: Set<Int>] = [:]
    internal(set) var memoryTexts: [String: [Int: String]] = [:]
    internal(set) var memoryResults: [String: [Int: AssistantReminderResult]] = [:]
    /// The options ticked on a question with several to pick, per question (until it's answered;
    /// the composer's Send answers with them too).
    internal(set) var questionPicks: [String: [String]] = [:]

    @ObservationIgnored let api: FamilyAPI
    /// Called after the assistant (or an undo) changed something, so the screens reload it.
    @ObservationIgnored var onChange: ([DataArea]) -> Void = { _ in }
    /// The page the user looks at (overview | calendar | finance | meals | appointments |
    /// chores | settings), sent along with every message (with this year).
    @ObservationIgnored var page = "overview"

    func context() -> (page: String, year: Int) {
        (page, Calendar.current.component(.year, from: .now))
    }

    /// Changes and tool calls this device has seen, so it reloads the data only for new ones.
    @ObservationIgnored var seen = Set<String>()
    @ObservationIgnored var following: Task<Void, Never>? { didSet { updateTurn() } }
    @ObservationIgnored var followID = 0
    /// Text the stream wrote that isn't shown yet: pieces arrive many times a second, and each
    /// shown one draws the chat again, so they're shown together, at most every `deltaInterval`.
    @ObservationIgnored var pendingDeltas: [(chat: String, seq: Int, text: String)] = []
    @ObservationIgnored var deltaFlush: Task<Void, Never>?
    static let deltaInterval: Duration = .milliseconds(80)
    /// While the model writes, `activity` (its `at`) is assigned again at most this often.
    static let activityRefresh: TimeInterval = 1
    /// How recently the latest chat must have been active for the assistant to open on it.
    static let reopenWithin: TimeInterval = 15 * 60
    /// How many views show the store (the panel and the page may both); the last one to go
    /// stops following.
    @ObservationIgnored var viewers = 0
    /// The latest chat was opened once (the panel opens on it rather than on an empty chat).
    @ObservationIgnored var restoredLatest = false
    /// The chat `restoreLatest` opened, and `picks` then: while the user hasn't picked another,
    /// it gives way to a new chat once it has gone quiet.
    @ObservationIgnored var restored: (id: String, picks: Int)?
    /// Grows with every chat the user opens or starts.
    @ObservationIgnored var picks = 0

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
    @ObservationIgnored var sentKnowledgeFolder: String?

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
}

enum AssistantStoreError: LocalizedError {
    case notYet(String)

    var errorDescription: String? {
        switch self { case let .notYet(message): message }
    }
}

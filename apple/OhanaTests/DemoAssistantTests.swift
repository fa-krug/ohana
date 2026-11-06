import Foundation
import Testing
@testable import Ohana

/// The demo's assistant: the settings (as a viewer gets them), the chat list and each chat, as
/// the screens decode them; and the chat store on the demo (no stream that never ends, sending
/// fails with the demo's note in the chat).
struct DemoAssistantTests {
    private let chatIDs = ["chat-dinner", "chat-pediatrician", "chat-groceries"]

    private func get(_ sub: String, query: [URLQueryItem] = []) -> (Data, HTTPURLResponse) {
        var url = DemoServer.baseURL.appending(path: "/api/v1/families/demo" + sub)
        if !query.isEmpty { url.append(queryItems: query) }
        return DemoServer().respond(to: URLRequest(url: url))
    }

    private func decode<T: Decodable>(_ sub: String, as type: T.Type) throws -> T {
        let (data, response) = get(sub)
        #expect(response.statusCode == 200, "\(sub)")
        #expect(!String(decoding: data, as: UTF8.self).contains("{{"), "\(sub) has an unfilled placeholder")
        return try APIClient.decoder.decode(T.self, from: data)
    }

    private func store() -> AssistantChatStore {
        AssistantChatStore(api: FamilyAPI(client: APIClient(demo: DemoServer()), familyID: DemoServer.familyID))
    }

    /// Waits (a little) until `done` holds.
    private func eventually(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func settingsAreSetUpAndReadOnly() throws {
        let settings = try decode("/ai/settings", as: AssistantSettings.self)
        #expect(settings.configured)
        #expect(!settings.canEdit)
        #expect(!settings.allowWrites)
        #expect(!settings.model.isEmpty)
        // The finances read the same route for whether to offer auto-categorize.
        #expect(try decode("/ai/settings", as: FinanceAIStatus.self).configured)
    }

    @Test func chatListIsIdleAndLatestFirst() throws {
        let chats = try decode("/ai/chats", as: AssistantChatList.self).chats
        #expect(chats.map(\.id) == chatIDs)
        #expect(chats.allSatisfy { !$0.isRunning && $0.activity == nil && ($0.queued ?? []).isEmpty })
        let dates = chats.compactMap(\.updatedDate)
        #expect(dates.count == chats.count)
        #expect(dates == dates.sorted(by: >))
        #expect(dates.allSatisfy { $0 < .now })
        // Today, but longer ago than the assistant reopens a chat: the demo opens on a new chat,
        // with these as its recent chats.
        #expect(dates[0] > Date.now.addingTimeInterval(-12 * 3600))
        #expect(dates[0] < Date.now.addingTimeInterval(-AssistantChatStore.reopenWithin))
    }

    @Test(arguments: ["chat-dinner", "chat-pediatrician", "chat-groceries"])
    func chatDecodesWithAToolCall(_ id: String) throws {
        let state = try decode("/ai/chats/\(id)", as: AssistantChatState.self)
        // The list says the same of it ({{time}} is filled in per request, to the millisecond).
        var summary = try decode("/ai/chats", as: AssistantChatList.self).chats.first { $0.id == id }
        summary?.updatedAt = state.chat.updatedAt
        #expect(state.chat == summary)
        #expect(state.items.first?.isUser == true)
        #expect(state.items.allSatisfy { $0.isVisible })
        if case .assistant = state.items.last {} else { Issue.record("\(id) doesn't end with an answer") }
        let tools = state.items.compactMap { if case let .tool(t) = $0 { t } else { nil } }
        #expect(tools.count == 1)
        #expect(tools.allSatisfy { $0.status == "ok" && !$0.interrupted })
        // A tool the app knows: shown by its label, not its name.
        #expect(tools.allSatisfy { AssistantToolLabels.label($0) != $0.name })
    }

    @Test func chatsReferToTheDemoFamily() throws {
        func text(_ id: String) throws -> String {
            try decode("/ai/chats/\(id)", as: AssistantChatState.self).items.map {
                switch $0 {
                case let .user(text, _), let .assistant(text, _): text
                default: ""
                }
            }.joined(separator: "\n")
        }
        let today = Day.today
        #expect(try text("chat-dinner").contains("Vegetable lasagne"))
        let pediatrician = try text("chat-pediatrician")
        #expect(pediatrician.contains(today.adding(days: 3).description))
        #expect(pediatrician.contains("Kinderarztpraxis Dr. Weber"))
        #expect(try text("chat-groceries").contains("groceries"))
    }

    @Test func aChatsStreamIsNotThereAndSendingIsRefused() {
        #expect(get("/ai/chats/chat-dinner/events", query: [URLQueryItem(name: "since", value: "6")]).1.statusCode == 404)
        var post = URLRequest(url: DemoServer.baseURL.appending(path: "/api/v1/families/demo/ai/chats"))
        post.httpMethod = "POST"
        #expect(DemoServer().respond(to: post).1.statusCode == 403)
    }

    @Test func storeOpensTheLatestChatAndStopsFollowing() async {
        let store = store()
        await store.loadSettings()
        #expect(store.ready)
        #expect(store.settingsError == nil)

        // The latest was active 45 minutes ago: within the hour asked for here.
        await store.restoreLatest(within: 3600)
        #expect(store.chats.map(\.id) == chatIDs)
        #expect(store.current?.id == "chat-dinner")
        #expect(store.current?.isRunning == false)
        #expect(!store.isFollowing)

        // Back in the app: the open chat is followed once, and the demo ends that at once.
        await store.refresh()
        await eventually { !store.isFollowing }
        #expect(!store.isFollowing)
        #expect(store.current?.id == "chat-dinner")
        #expect(store.current?.items.contains { if case .error = $0 { true } else { false } } == false)
    }

    @Test func opensOnANewChatWhenTheLatestIsQuiet() async {
        let store = store()
        await store.preload()
        // Nothing opened (nothing heavy prepared), the list there for the chat list.
        #expect(store.ready)
        #expect(store.currentID == nil)
        #expect(store.current == nil)
        #expect(store.chatsLoaded)
        #expect(store.chats.map(\.id) == chatIDs)
        // Showing it later doesn't open one either.
        await store.restoreLatest()
        #expect(store.currentID == nil)
    }

    @Test func aReopenedChatGivesWayOnceQuiet() async {
        let store = store()
        await store.restoreLatest(within: 3600)
        #expect(store.currentID == "chat-dinner")
        // Shown again while it's still recent: it stays.
        await store.restoreLatest(within: 3600, now: .now.addingTimeInterval(60))
        #expect(store.currentID == "chat-dinner")
        // Shown again after it went quiet: a new chat.
        await store.restoreLatest(within: 3600, now: .now.addingTimeInterval(3600))
        #expect(store.currentID == nil)
        #expect(store.current == nil)

        // A chat the user opened stays open, however old.
        await store.open("chat-groceries")
        await store.restoreLatest(within: 3600, now: .now.addingTimeInterval(7 * 86400))
        #expect(store.currentID == "chat-groceries")
    }

    @Test func openingAChatReadsItsAnswersAheadBeforeShowingIt() async throws {
        let store = store()
        var read: [[AssistantItem]] = []
        var shownWhenRead: [Bool] = []
        store.prewarm = { items in
            read.append(items)
            shownWhenRead.append(store.current != nil)
        }
        await store.open("chat-dinner")
        // The server's answer, read before it was shown.
        #expect(read.count == 1)
        #expect(shownWhenRead == [false])
        #expect(read.first == store.current?.items)
    }

    @Test func countsEachChatShownOnce() async {
        let store = store()
        let start = store.session
        await store.open("chat-dinner")
        #expect(store.session == start + 1)
        #expect(store.openError == nil)
        // The open one again: the same chat, no cross-fade.
        await store.open("chat-dinner")
        #expect(store.session == start + 1)
        store.newChat()
        #expect(store.session == start + 2)
        // A chat that's gone: an empty chat, not an error that stays.
        await store.open("chat-gone")
        #expect(store.currentID == nil)
        #expect(store.openError == nil)
    }

    @Test func sendingShowsTheDemosNoteInTheChat() async throws {
        let store = store()
        await store.open("chat-pediatrician")
        let before = store.current?.items.count ?? 0
        #expect(store.turn == .idle)
        try await store.send("Can you move it to Friday?")
        // On its way: the bar and the toggle say so.
        #expect(store.turnRunning)
        #expect(store.turn.running && store.turn.status == String(localized: "Thinking…"))
        await eventually { !store.busy && !store.isFollowing }
        #expect(!store.busy)
        #expect(!store.isFollowing)
        #expect(store.activity == nil)
        #expect(store.turn == .idle)
        #expect(!store.turnRunning)
        let items = store.current?.items ?? []
        #expect(items.count == before + 2)
        #expect(items.dropLast().last == .user(text: "Can you move it to Friday?", attachments: []))
        #expect(items.last == .error(text: DemoServer.readOnlyMessage))

        // A new chat likewise keeps the message and says why it went nowhere.
        store.newChat()
        try await store.send("Hello")
        await eventually { !store.busy && !store.isFollowing }
        #expect(store.current?.items == [.user(text: "Hello", attachments: []), .error(text: DemoServer.readOnlyMessage)])
        #expect(store.current?.isRunning == false)
    }
}

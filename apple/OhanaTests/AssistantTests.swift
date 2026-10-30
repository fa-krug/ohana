import Foundation
import Testing
@testable import Ohana

/// The assistant's API types against JSON as the server sends it (web/lib/assistant).
struct AssistantDecodingTests {
    static let chatJSON = """
    {
      "chat": {
        "id": "8c1d6f3e-1111-4c4c-9d9d-000000000001",
        "title": "Plan the holidays",
        "status": "running",
        "activity": { "kind": "retrying", "attempt": 2, "max": 5 },
        "usage": { "used": 12345, "max": 128000 },
        "page": "calendar",
        "queued": [ { "id": "q1", "text": "And next year?", "attachments": [ { "kind": "image", "name": "shot.png" } ] } ],
        "updatedAt": "2026-10-30T08:15:00.123Z"
      },
      "rev": 7,
      "items": [
        { "kind": "user", "text": "Add the holidays", "attachments": [ { "kind": "image", "name": "a.jpg", "url": "data:image/jpeg;base64,AAAA" }, { "kind": "file", "name": "b.csv" } ] },
        { "kind": "tool", "id": "call_1", "name": "change_entries", "args": { "ops": [ { "action": "set", "type": "Holiday", "dates": ["2026-12-24", "2026-12-26"] } ] }, "status": "ok", "summary": "3 days", "result": "{\\"ok\\":true}" },
        { "kind": "change", "id": "chg_1", "change": "entries", "summary": "Added 3 holidays", "undo": [ { "method": "POST", "path": "/entries", "body": { "ops": [ { "action": "clear", "dates": ["2026-12-24"] } ] } } ] },
        { "kind": "tool", "id": "call_2", "name": "web_search", "args": { "query": "Ferien Bayern" }, "status": "running", "interrupted": true },
        { "kind": "question", "id": "call_3", "question": "Which state?", "options": ["Bavaria", "Berlin"], "multiple": false },
        { "kind": "question", "id": "call_4", "question": "Which days?", "options": ["Mon", "Tue"], "multiple": true, "answer": { "selected": ["Mon"], "text": "and Fri" } },
        { "kind": "compacted" },
        { "kind": "assistant", "text": "Done: **3 days** added." },
        { "kind": "assistant", "text": "" },
        { "kind": "error", "text": "The model didn't answer" },
        { "kind": "hologram", "beam": 3 },
        null
      ]
    }
    """

    @Test func decodesAChatWithEveryKindOfItem() throws {
        let state = try JSONDecoder().decode(AssistantChatState.self, from: Data(Self.chatJSON.utf8))
        #expect(state.rev == 7)
        #expect(state.chat.isRunning)
        #expect(state.chat.activity == AssistantActivity(kind: "retrying", attempt: 2, max: 5))
        #expect(state.chat.usage == AssistantUsage(used: 12345, max: 128000))
        #expect(state.chat.page == "calendar")
        #expect(state.chat.queued?.first?.attachments?.first?.name == "shot.png")
        #expect(state.chat.updatedDate != nil)
        #expect(state.items.count == 12)

        guard case let .user(text, attachments) = state.items[0] else { Issue.record("user"); return }
        #expect(text == "Add the holidays")
        #expect(attachments.map(\.kind) == ["image", "file"])
        #expect(attachments[0].url == "data:image/jpeg;base64,AAAA")

        guard case let .tool(tool) = state.items[1] else { Issue.record("tool"); return }
        #expect(tool.name == "change_entries")
        #expect(tool.status == "ok")
        #expect(tool.result == "{\"ok\":true}")
        #expect(tool.args["ops"]?.arrayValue?.count == 1)

        guard case let .change(change) = state.items[2] else { Issue.record("change"); return }
        #expect(change.change == "entries")
        #expect(!change.undone)
        #expect(change.undo == [AssistantUndoStep(
            method: "POST", path: "/entries",
            body: .object(["ops": .array([.object(["action": .string("clear"), "dates": .array([.string("2026-12-24")])])])])
        )])

        guard case let .tool(search) = state.items[3] else { Issue.record("search"); return }
        #expect(search.interrupted)
        #expect(search.status == "running")

        guard case let .question(open) = state.items[4], case let .question(answered) = state.items[5] else {
            Issue.record("questions"); return
        }
        #expect(open.options == ["Bavaria", "Berlin"])
        #expect(open.answer == nil && !open.multiple)
        #expect(answered.multiple && answered.answer == .init(selected: ["Mon"], text: "and Fri"))

        #expect(state.items[6] == .compacted)
        #expect(state.items[7] == .assistant(text: "Done: **3 days** added."))
        #expect(state.items[9] == .error(text: "The model didn't answer"))
        // New kinds never break decoding: they are kept, and not shown.
        #expect(state.items[10] == .unknown(kind: "hologram"))
        #expect(state.items[11] == .unknown(kind: ""))
        #expect(state.items.filter(\.isVisible).count == 9)
    }

    @Test func decodesTheChatListAndSettings() throws {
        let list = try JSONDecoder().decode(AssistantChatList.self, from: Data("""
        { "chats": [ { "id": "c1", "title": "Old", "status": "idle", "activity": null, "usage": null,
                       "page": null, "queued": [], "updatedAt": "2026-01-02T03:04:05.000Z" } ] }
        """.utf8))
        #expect(list.chats.count == 1)
        #expect(!list.chats[0].isRunning && list.chats[0].page == nil && list.chats[0].usage == nil)

        let editor = try JSONDecoder().decode(AssistantSettings.self, from: Data("""
        { "configured": true, "canEdit": true, "baseUrl": "https://mock.test/v1", "model": "gpt-x",
          "hasKey": true, "keyHint": "abcd", "searchProvider": "tavily", "hasSearchKey": false,
          "searchKeyHint": "", "allowWrites": true, "contextWindow": 0, "imageModel": "", "serverReady": true }
        """.utf8))
        #expect(editor.configured && editor.keyHint == "abcd" && editor.searchProvider == "tavily")
        let viewer = try JSONDecoder().decode(AssistantSettings.self, from: Data("""
        { "configured": false, "canEdit": false, "model": "", "allowWrites": false, "serverReady": true }
        """.utf8))
        #expect(!viewer.configured && viewer.baseUrl == nil && viewer.hasKey == nil)
    }

    @Test func encodesOnlyTheFieldsOfAPatch() throws {
        let data = try JSONEncoder().encode(AssistantSettingsPatch(apiKey: "", allowWrites: false))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["apiKey", "allowWrites"])
    }

    @Test func readsServerSentEvents() throws {
        // As sseResponse writes them: "event: x\ndata: {…}\n\n", pings among them.
        let stream = """
        event: chat
        data: {"id":"c1","title":"Hi","status":"running","activity":{"kind":"thinking"},"usage":null,"page":"overview","queued":[],"updatedAt":"2026-10-30T08:00:00.000Z"}

        event: ping
        data: {}

        event: items
        data: {"rev":3,"items":[{"seq":0,"item":{"kind":"user","text":"Hi"}},{"seq":1,"item":{"kind":"assistant","text":""}}]}

        event: delta
        data: {"seq":1,"text":"Hel"}

        event: reconnect
        data: {}

        event: end
        data: {"deleted":true}
        """
        var parser = AssistantSSEParser()
        var events: [AssistantChatEvent] = []
        for line in stream.components(separatedBy: "\n") {
            guard let (name, data) = parser.feed(line) else { continue }
            if let event = try AssistantChatEvent.parse(event: name, data: data) { events.append(event) }
        }
        #expect(events.count == 5)
        guard case let .chat(summary) = events[0] else { Issue.record("chat"); return }
        #expect(summary.activity?.kind == "thinking")
        #expect(events[1] == .items(rev: 3, items: [(0, .user(text: "Hi", attachments: [])), (1, .assistant(text: ""))]))
        #expect(events[2] == .delta(seq: 1, text: "Hel"))
        #expect(events[3] == .reconnect)
        #expect(events[4] == .end(deleted: true))

        // Without blank lines between events (URLSession's lines may drop them) too.
        var tight = AssistantSSEParser()
        let lines = ["event: delta", "data: {\"seq\":0,\"text\":\"a\"}", "event: end", "data: {}"]
        let names = lines.compactMap { tight.feed($0)?.event }
        #expect(names == ["delta", "end"])
    }
}

/// What the assistant's changes make reload.
struct AssistantChangeAreaTests {
    @Test func mapsChangeKinds() {
        #expect(AssistantChangeAreas.areas(kind: "entries") == [.calendar])
        #expect(AssistantChangeAreas.areas(kind: "notes") == [.calendar])
        #expect(AssistantChangeAreas.areas(kind: "types") == [.calendar])
        #expect(AssistantChangeAreas.areas(kind: "events") == [.events, .calendar])
        #expect(AssistantChangeAreas.areas(kind: "transactions") == [.finance])
        #expect(AssistantChangeAreas.areas(kind: "categories") == [.finance])
        #expect(AssistantChangeAreas.areas(kind: "benchmark") == [.finance])
        #expect(AssistantChangeAreas.areas(kind: "recipes") == [.recipes, .meals])
        #expect(AssistantChangeAreas.areas(kind: "plan") == [.mealPlan, .shopping, .meals])
        #expect(AssistantChangeAreas.areas(kind: "shopping") == [.shopping, .meals])
        #expect(AssistantChangeAreas.areas(kind: "appointments") == [.appointments])
        #expect(AssistantChangeAreas.areas(kind: "something-new").isEmpty)
    }

    @Test func mapsUndoPaths() {
        #expect(AssistantChangeAreas.areas(path: "/entries") == [.calendar])
        #expect(AssistantChangeAreas.areas(path: "/types/abc?year=2027") == [.calendar])
        #expect(AssistantChangeAreas.areas(path: "/events/e1") == [.events, .calendar])
        #expect(AssistantChangeAreas.areas(path: "/finance/transactions") == [.finance])
        #expect(AssistantChangeAreas.areas(path: "/finance/settings") == [.finance])
        #expect(AssistantChangeAreas.areas(path: "/meals/recipes/r1") == [.recipes, .meals])
        #expect(AssistantChangeAreas.areas(path: "/meals/shopping/check") == [.shopping, .meals])
        #expect(AssistantChangeAreas.areas(path: "/meals/plan/restore") == [.mealPlan, .shopping, .meals])
        #expect(AssistantChangeAreas.areas(path: "/appointments/searches/s1") == [.appointments])
        #expect(AssistantChangeAreas.areas(path: "/ai/chats").isEmpty)
    }

    @Test func combinesKindAndUndo() {
        // Booking a slot: the event, and the search it stopped.
        let undo = [
            AssistantUndoStep(method: "DELETE", path: "/events/e1"),
            AssistantUndoStep(method: "PATCH", path: "/appointments/searches/s1", body: .object(["enabled": .bool(true)])),
        ]
        #expect(AssistantChangeAreas.areas(change: "events", undo: undo) == [.events, .calendar, .appointments])
    }

    @Test func mapsToolNames() {
        #expect(AssistantChangeAreas.areas(tool: "change_entries") == [.calendar])
        #expect(AssistantChangeAreas.areas(tool: "add_event") == [.events, .calendar])
        #expect(AssistantChangeAreas.areas(tool: "change_transactions") == [.finance])
        #expect(AssistantChangeAreas.areas(tool: "save_recipe") == [.recipes, .meals])
        #expect(AssistantChangeAreas.areas(tool: "plan_meals") == [.mealPlan, .shopping, .meals])
        #expect(AssistantChangeAreas.areas(tool: "add_shopping_items") == [.shopping, .meals])
        #expect(AssistantChangeAreas.areas(tool: "run_appointment_search") == [.appointments])
        #expect(AssistantChangeAreas.areas(tool: "book_appointment_slot") == [.appointments, .events, .calendar])
        for reading in ["get_calendar", "list_transactions", "web_search", "fetch_page", "list_recipes", "ask_user", "calculate"] {
            #expect(AssistantChangeAreas.areas(tool: reading).isEmpty)
        }
    }
}

/// The store applying a chat's stream: items, deltas, and the change signals.
struct AssistantStoreTests {
    private func store() -> AssistantChatStore {
        AssistantChatStore(api: FamilyAPI(client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil),
                                          familyID: "f1"))
    }

    @Test func appliesStreamEventsAndSignalsNewChanges() {
        let store = store()
        var signalled: [[DataArea]] = []
        store.onChange = { signalled.append($0) }
        store.show(AssistantChat(id: "c1", title: "Hi", status: "running", items: [.user(text: "Hi", attachments: [])],
                                 rev: 1, usage: nil, page: "overview", queued: []))

        store.apply("c1", .items(rev: 2, items: [(1, .assistant(text: ""))]))
        store.apply("c1", .delta(seq: 1, text: "Hel"))
        store.apply("c1", .delta(seq: 1, text: "lo"))
        #expect(store.current?.items[1] == .assistant(text: "Hello"))
        #expect(store.activity?.activity.kind == "writing")
        #expect(signalled.isEmpty)

        let change = AssistantItem.change(AssistantChange(
            id: "chg", change: "shopping", summary: "Added milk",
            undo: [AssistantUndoStep(method: "DELETE", path: "/meals/shopping/items/i1")], undone: false
        ))
        let tool = AssistantItem.tool(AssistantToolCall(id: "t1", name: "add_shopping_items", args: [:], status: "ok",
                                                        summary: nil, result: nil, interrupted: false))
        store.apply("c1", .items(rev: 4, items: [(2, tool), (4, change)]))
        #expect(store.current?.rev == 4)
        #expect(store.current?.items.count == 5)
        #expect(store.current?.items[3] == .unknown(kind: ""))
        #expect(signalled == [[.shopping, .meals]])

        // Seen once: the same change again (a reconnect) doesn't reload anything.
        store.apply("c1", .items(rev: 4, items: [(4, change)]))
        #expect(signalled.count == 1)

        store.apply("c1", .end(deleted: false))
        #expect(store.current?.status == "idle")
        #expect(store.activity == nil)
        #expect(!store.busy)
    }

    @Test func aNewChatTakesItsIDFromTheFirstEvent() {
        let store = store()
        store.show(AssistantChat(id: "", title: "Hi", status: "idle", items: [.user(text: "Hi", attachments: [])],
                                 rev: 0, usage: nil, page: "finance", queued: []))
        let summary = AssistantChatSummary(id: "new", title: "Hi", status: "running", activity: .init(kind: "tool"),
                                           usage: .init(used: 10, max: 100), page: "finance",
                                           queued: [.init(id: "q1", text: "next")], updatedAt: "2026-10-30T08:00:00.000Z")
        store.apply("new", .chat(summary))
        #expect(store.currentID == "new")
        #expect(store.current?.id == "new")
        #expect(store.current?.isRunning == true)
        #expect(store.current?.usage == AssistantUsage(used: 10, max: 100))
        #expect(store.current?.queued.map(\.id) == ["q1"])
        #expect(store.chats.map(\.id) == ["new"])
        #expect(store.activity?.activity.kind == "tool")

        store.apply("new", .end(deleted: true))
        #expect(store.current == nil)
        #expect(store.chats.isEmpty)
    }

    @Test func findsTheOpenQuestion() {
        let store = store()
        let q = AssistantQuestion(id: "q", question: "Which?", options: ["A", "B"], multiple: false, answer: nil, skipped: false)
        store.show(AssistantChat(id: "c1", title: "Q", status: "idle", items: [.user(text: "Hi", attachments: []), .question(q)],
                                 rev: 2, usage: nil, page: nil, queued: []))
        #expect(store.openQuestion()?.question.id == "q")
        store.show(AssistantChat(id: "c2", title: "Q", status: "idle",
                                 items: [.question(q), .user(text: "Something else", attachments: [])],
                                 rev: 2, usage: nil, page: nil, queued: []))
        #expect(store.openQuestion() == nil)
    }
}

struct AssistantRenderingTests {
    @Test func parsesMarkdownBlocks() {
        let blocks = AssistantMarkdownBlock.parse("""
        ## Plan
        Line one
        line two

        - a
        - b

        1. first
        | Day | Amount |
        | --- | ---: |
        | Mon | 3 |
        ```
        code
        ```
        """)
        #expect(blocks == [
            .heading("Plan"),
            .paragraph("Line one\nline two"),
            .list(ordered: false, items: ["a", "b"]),
            .list(ordered: true, items: ["first"]),
            .table(header: ["Day", "Amount"], alignments: [], rows: [["Mon", "3"]]),
            .code("code"),
        ])
    }

    @Test func dropsLinksThatArentWeb() {
        let s = AssistantMarkdownBlock.inline("[ok](https://x.example) [bad](javascript:alert(1))")
        let links = s.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://x.example")!])
    }

    @Test func namesToolCalls() {
        let tool = AssistantToolCall(id: "1", name: "list_recipes",
                                     args: ["query": .string("Pasta"), "tags": .array([.string("quick")])],
                                     status: "ok", summary: nil, result: nil, interrupted: false)
        #expect(AssistantToolLabels.detail(tool).contains("Pasta"))
        #expect(AssistantToolLabels.detail(tool).hasSuffix("quick"))
        let unknown = AssistantToolCall(id: "2", name: "future_tool", args: [:], status: "ok", summary: nil, result: nil,
                                        interrupted: false)
        #expect(AssistantToolLabels.label(unknown) == "future_tool")
        #expect(AssistantToolLabels.span("2026-01-01", "2026-12-31") == "2026")
        #expect(AssistantToolLabels.span("2026-01-01", "2027-12-31") == "2026 – 2027")
    }

    @Test func copiesATranscript() {
        let items: [AssistantItem] = [
            .user(text: "Hi", attachments: [.init(kind: "file", name: "a.csv")]),
            .tool(.init(id: "t", name: "calculate", args: ["expressions": .array([.string("1+1")])], status: "ok",
                        summary: nil, result: "{\"a\":2}", interrupted: false)),
            .assistant(text: "2"),
        ]
        let text = AssistantTranscript.markdown(items) { $0 == "t" ? "{\"a\":2}" : nil }
        #expect(text.contains("📎 a.csv"))
        #expect(text.contains("```json"))
        #expect(text.hasSuffix("\n\n2"))
    }
}

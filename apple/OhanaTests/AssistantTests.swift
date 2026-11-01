import Foundation
import Testing
@testable import Ohana

/// The assistant's API types against JSON as the server sends it (server/lib/assistant).
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
        #expect(AssistantChangeAreas.areas(kind: "plan") == [.mealPlan, .meals])
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
        #expect(AssistantChangeAreas.areas(path: "/meals/plan/restore") == [.mealPlan, .meals])
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
        #expect(AssistantChangeAreas.areas(tool: "plan_meals") == [.mealPlan, .meals])
        #expect(AssistantChangeAreas.areas(tool: "run_appointment_search") == [.appointments])
        #expect(AssistantChangeAreas.areas(tool: "book_appointment_slot") == [.appointments, .events, .calendar])
        for reading in ["get_calendar", "list_transactions", "web_search", "fetch_page", "list_recipes", "ask_user", "calculate",
                        "get_shopping_items", "get_reminders"] {
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
            id: "chg", change: "recipes", summary: "Saved Lasagne",
            undo: [AssistantUndoStep(method: "DELETE", path: "/meals/recipes/r1")], undone: false
        ))
        let tool = AssistantItem.tool(AssistantToolCall(id: "t1", name: "save_recipe", args: [:], status: "ok",
                                                        summary: nil, result: nil, interrupted: false))
        store.apply("c1", .items(rev: 4, items: [(2, tool), (4, change)]))
        #expect(store.current?.rev == 4)
        #expect(store.current?.items.count == 5)
        #expect(store.current?.items[3] == .unknown(kind: ""))
        #expect(signalled == [[.recipes, .meals]])

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

    @Test func namesTheShoppingAndRemindersTools() {
        func call(_ name: String, _ args: [String: JSONValue] = [:]) -> AssistantToolCall {
            AssistantToolCall(id: "t", name: name, args: args, status: "ok", summary: nil, result: nil, interrupted: false)
        }
        #expect(AssistantToolLabels.label(call("get_shopping_items")) == "Reading what the meal plan needs")
        #expect(AssistantToolLabels.label(call("get_reminders")) == "Reading your reminders")
        #expect(AssistantToolLabels.label(call("edit_reminders")) == "Suggesting changes to your reminders")
        #expect(AssistantToolLabels.icon("get_shopping_items") == "cart")
        #expect(AssistantToolLabels.icon("edit_reminders") == "checklist")
        #expect(AssistantToolLabels.detail(call("get_shopping_items", ["from": .string("2026-11-07")])).hasPrefix("from "))
        #expect(AssistantToolLabels.detail(call("get_reminders", ["list": .string("Groceries")])) == "“Groceries”")
        let edit = call("edit_reminders", ["ops": .array([
            .object(["op": .string("add"), "list": .string("shopping"), "title": .string("Milk")]),
            .object(["op": .string("complete"), "id": .string("r1")]),
        ])])
        #expect(AssistantToolLabels.detail(edit) == "2 changes · Milk")
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

/// The assistant's Reminders tools on the device: the edit item, the snapshot every request
/// carries, applying an edit and its answer.
struct AssistantRemindersTests {
    static let itemsJSON = """
    {
      "chat": { "id": "c1", "title": "Groceries", "status": "idle", "updatedAt": "2026-11-01T08:00:00.000Z" },
      "rev": 3,
      "items": [
        { "kind": "reminders", "id": "call_1", "summary": "Add 1 reminder, change 1 reminder, complete 1 reminder, delete 1 reminder",
          "ops": [
            { "op": "add", "list": "L1", "listTitle": "Groceries", "title": "Milk", "due": "2026-11-07", "notes": "2 l" },
            { "op": "update", "id": "r1", "itemTitle": "Call dentist", "list": "L2", "listTitle": "Work", "due": null, "notes": "" },
            { "op": "complete", "id": "r2", "itemTitle": "Pay rent", "list": "L2", "listTitle": "Work" },
            { "op": "delete", "id": "r3", "itemTitle": "Old note", "list": "L1", "listTitle": "Groceries" },
            { "op": "teleport", "id": "r4" }
          ] },
        { "kind": "reminders", "id": "call_2", "summary": "Delete “X”",
          "ops": [ { "op": "delete", "id": "r9", "itemTitle": "X", "list": "L1", "listTitle": "Groceries" } ],
          "answer": { "applied": true, "results": [ { "ok": false, "error": "The reminder is gone." } ] } },
        { "kind": "reminders", "id": "call_3", "summary": "S", "ops": [], "answer": { "applied": false } },
        { "kind": "reminders", "id": "call_4", "summary": "S", "ops": [], "skipped": true }
      ]
    }
    """

    private func store(_ items: [AssistantItem]) -> AssistantChatStore {
        let store = AssistantChatStore(api: FamilyAPI(client: APIClient(baseURL: URL(string: "https://x.example")!, token: nil),
                                                      familyID: "f1"))
        store.remindersContext = { nil }
        store.show(AssistantChat(id: "c1", title: "R", status: "idle", items: items, rev: 1, usage: nil, page: "meals",
                                 queued: []))
        return store
    }

    @Test func decodesTheRemindersItem() throws {
        let state = try JSONDecoder().decode(AssistantChatState.self, from: Data(Self.itemsJSON.utf8))
        #expect(state.items.count == 4)
        guard case let .reminders(open) = state.items[0] else { Issue.record("reminders"); return }
        #expect(open.id == "call_1")
        #expect(open.answer == nil)
        #expect(!open.skipped)
        #expect(open.ops.map(\.op) == ["add", "update", "complete", "delete", "teleport"])
        #expect(open.ops[0] == AssistantReminderOp(op: "add", list: "L1", listTitle: "Groceries", title: "Milk", notes: "2 l",
                                                   due: .set(ReminderDue(day: Day(year: 2026, month: 11, day: 7)))))
        #expect(open.ops[1].due == .clear)
        #expect(open.ops[1].notes == "")
        #expect(open.ops[1].itemTitle == "Call dentist")
        #expect(open.ops[2].due == .keep)
        #expect(open.ops[4].list == "")
        #expect(open.outcome == nil)

        guard case let .reminders(failed) = state.items[1], case let .reminders(declined) = state.items[2],
              case let .reminders(skipped) = state.items[3] else { Issue.record("answered"); return }
        #expect(failed.answer?.applied == true)
        #expect(failed.answer?.results == [.failed("The reminder is gone.")])
        #expect(failed.outcome == "Applied, 1 of 1 failed")
        #expect(declined.answer == .init(applied: false, results: nil))
        #expect(declined.outcome == "Not applied")
        #expect(skipped.skipped)
        #expect(skipped.outcome == "Not answered")
    }

    @Test func findsTheWaitingEdit() {
        let edit = AssistantRemindersEdit(id: "e1", summary: "Add “Milk”", ops: [], answer: nil, skipped: false)
        let q = AssistantQuestion(id: "q", question: "Which?", options: ["A"], multiple: false, answer: nil, skipped: false)
        // Only the last of them waits.
        let s = store([.question(q), .reminders(edit)])
        #expect(s.openRemindersEdit()?.edit.id == "e1")
        #expect(s.openQuestion() == nil)
        #expect(store([.reminders(edit), .question(q)]).openRemindersEdit() == nil)
        #expect(store([.reminders(edit), .user(text: "No", attachments: [])]).openRemindersEdit() == nil)
        var answered = edit
        answered.answer = .init(applied: false, results: nil)
        #expect(store([.reminders(answered)]).openRemindersEdit() == nil)
    }

    @Test func describesTheOps() {
        let add = AssistantReminderOp(op: "add", list: "L1", listTitle: "Groceries", title: "Milk",
                                      due: .set(ReminderDue(day: Day(year: 2026, month: 11, day: 7))))
        let line = AssistantReminderOpLine.make(add, locale: Locale(identifier: "en_GB"))
        #expect(line.text.hasPrefix("Add “Milk” to Groceries · due "))
        #expect(line.text.contains("7"))
        #expect(line.text.contains("Nov"))
        #expect(!line.destructive)

        let move = AssistantReminderOp(op: "update", id: "r1", itemTitle: "X", list: "L2", listTitle: "Work")
        #expect(AssistantReminderOpLine.make(move).text == "Move “X” to Work")

        let change = AssistantReminderOp(op: "update", id: "r1", itemTitle: "X", list: "L2", listTitle: "Work",
                                         title: "Y", notes: "", due: .clear)
        let changed = AssistantReminderOpLine.make(change)
        #expect(changed.text == "Change “X”")
        #expect(changed.detail == "rename to “Y”, no due date, remove the notes")
        #expect(AssistantReminderOpLine.make(change, currentListID: "L1").detail?.hasSuffix("move to Work") == true)
        #expect(AssistantReminderOpLine.make(change, currentListID: "L2").detail == "rename to “Y”, no due date, remove the notes")

        let complete = AssistantReminderOp(op: "complete", id: "r2", itemTitle: "Call dentist", list: "L2", listTitle: "Work")
        #expect(AssistantReminderOpLine.make(complete).text == "Complete “Call dentist”")
        #expect(AssistantReminderOpLine.make(complete).detail == "Work")
        let delete = AssistantReminderOp(op: "delete", id: "r3", itemTitle: "Y", list: "L1", listTitle: "Groceries")
        #expect(AssistantReminderOpLine.make(delete).text == "Delete “Y”")
        #expect(AssistantReminderOpLine.make(delete).destructive)

        let timed = AssistantReminderOpLine.dueText(ReminderDue(day: Day(year: 2026, month: 11, day: 7), hour: 18, minute: 30),
                                                   locale: Locale(identifier: "en_GB"))
        #expect(timed.contains("18:30"))
    }

    @Test func buildsTheSnapshot() throws {
        let lists = (0..<105).map { ReminderList(id: "L\($0)", title: "List \($0)", source: "iCloud", isWritable: true) }
            + [ReminderList(id: "RO", title: "Holidays", source: "Subscribed", isWritable: false)]
        let long = String(repeating: "a", count: 250)
        var reminders = (0..<520).map {
            ReminderSnapshot(id: "r\($0)", listID: "L0", title: "Item \($0)", due: nil)
        }
        reminders += [
            ReminderSnapshot(id: "soon", listID: "L1", title: "  \(long)  ", notes: String(repeating: "n", count: 1200),
                             due: ReminderDue(day: Day(year: 2026, month: 11, day: 7), hour: 18, minute: 30)),
            ReminderSnapshot(id: "done", listID: "L1", title: "Done", due: ReminderDue(day: Day(year: 2026, month: 1, day: 1)),
                             isCompleted: true),
            ReminderSnapshot(id: "ro", listID: "RO", title: "Read only", due: ReminderDue(day: Day(year: 2026, month: 1, day: 1))),
            ReminderSnapshot(id: "far", listID: "L104", title: "Beyond the lists",
                             due: ReminderDue(day: Day(year: 2026, month: 1, day: 1))),
        ]
        let snapshot = AssistantRemindersContext.build(lists: lists, reminders: reminders, shoppingListID: "L3")
        #expect(snapshot.lists.count == 100)
        #expect(!snapshot.lists.contains { $0.id == "RO" })
        #expect(snapshot.shoppingListId == "L3")
        #expect(snapshot.items.count == 500)
        #expect(snapshot.items[0].id == "soon") // nearest due first
        #expect(snapshot.items[0].title.count == 200)
        #expect(snapshot.items[0].title.first == "a")
        #expect(snapshot.items[0].notes?.count == 1000)
        #expect(!snapshot.items.contains { ["done", "ro", "far"].contains($0.id) })
        #expect(AssistantRemindersContext.build(lists: lists, reminders: [], shoppingListID: "RO").shoppingListId == nil)

        let small = AssistantRemindersContext.build(
            lists: [ReminderList(id: "L1", title: "Groceries", source: "iCloud", isWritable: true)],
            reminders: [ReminderSnapshot(id: "r1", listID: "L1", title: "Milk", notes: "  ", due: nil),
                        ReminderSnapshot(id: "r2", listID: "L1", title: "Call", notes: "Dr. Weber",
                                         due: ReminderDue(day: Day(year: 2026, month: 11, day: 7), hour: 9, minute: 5))],
            shoppingListID: nil
        )
        let json = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(small)) as? [String: Any]
        #expect(json?["shoppingListId"] is NSNull)
        #expect((json?["lists"] as? [[String: Any]])?.first?["title"] as? String == "Groceries")
        let items = json?["items"] as? [[String: Any]] ?? []
        #expect(items.count == 2)
        #expect(items[0]["id"] as? String == "r2")
        #expect(items[0]["due"] as? String == "2026-11-07T09:05")
        #expect(items[0]["notes"] as? String == "Dr. Weber")
        #expect(items[0]["completed"] as? Bool == false)
        #expect(items[1]["due"] is NSNull)
        #expect(items[1]["notes"] == nil)
    }

    @Test func encodesTheAnswer() throws {
        let context = AssistantRemindersContext(shoppingListId: "L1", lists: [.init(id: "L1", title: "Groceries")], items: [])
        let applied = AssistantChatStore.remindersAnswer(
            id: "call_1", answer: .init(applied: true, results: [.done("new"), .failed("The reminder is gone.")]),
            page: "meals", year: 2026, lang: "en", today: "2026-11-01", reminders: context
        )
        let a = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(applied)) as? [String: Any]
        #expect(a?["id"] as? String == "call_1")
        #expect(a?["applied"] as? Bool == true)
        #expect(a?["page"] as? String == "meals")
        #expect(a?["today"] as? String == "2026-11-01")
        let results = a?["results"] as? [[String: Any]] ?? []
        #expect(results.count == 2)
        #expect(results[0]["ok"] as? Bool == true)
        #expect(results[0]["id"] as? String == "new")
        #expect(results[0]["error"] == nil)
        #expect(results[1]["ok"] as? Bool == false)
        #expect(results[1]["error"] as? String == "The reminder is gone.")
        #expect(results[1]["id"] == nil)
        #expect((a?["reminders"] as? [String: Any])?["shoppingListId"] as? String == "L1")

        let declined = AssistantChatStore.remindersAnswer(
            id: "call_1", answer: .init(applied: false, results: nil), page: "meals", year: 2026, lang: "de",
            today: "2026-11-01", reminders: nil
        )
        let d = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(declined)) as? [String: Any]
        #expect(d?["applied"] as? Bool == false)
        #expect(d?["results"] == nil)
        #expect(d?["reminders"] == nil)

        let message = AssistantChatInput(text: "Hi", attachments: nil, page: "overview", year: 2026, lang: "en",
                                         today: "2026-11-01", reminders: context)
        let m = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(message)) as? [String: Any]
        #expect((m?["reminders"] as? [String: Any])?["lists"] is [Any])
    }

    /// Records what applying does; ids in `missing` are gone, and `commitFails` breaks the save.
    final class FakeReminders: RemindersWriting {
        var calls: [String] = []
        var missing: Set<String> = []
        var commitFails = false
        var lists = ["L1": ReminderList(id: "L1", title: "Groceries", source: "", isWritable: true),
                     "L2": ReminderList(id: "L2", title: "Work", source: "", isWritable: true)]

        func list(_ id: String) -> ReminderList? { lists[id] }
        func add(_ draft: ReminderDraft, to listID: String, commit: Bool) throws -> String {
            #expect(!commit)
            calls.append("add \(draft.title) \(listID) \(draft.due?.description ?? "-") \(draft.notes ?? "-")")
            return "new-\(draft.title)"
        }
        func update(_ id: String, _ change: ReminderChange, commit: Bool) throws {
            guard !missing.contains(id) else { throw RemindersError.reminderNotFound }
            let due = change.due.map { $0?.description ?? "clear" } ?? "keep"
            let notes = change.notes.map { $0 ?? "clear" } ?? "keep"
            calls.append("update \(id) \(change.title ?? "-") \(due) \(notes) \(change.listID ?? "-")")
        }
        func setCompleted(_ id: String, _ completed: Bool, commit: Bool) throws {
            guard !missing.contains(id) else { throw RemindersError.reminderNotFound }
            calls.append("\(completed ? "complete" : "uncomplete") \(id)")
        }
        func delete(_ id: String, commit: Bool) throws {
            guard !missing.contains(id) else { throw RemindersError.reminderNotFound }
            calls.append("delete \(id)")
        }
        func commit() throws {
            calls.append("commit")
            if commitFails { throw RemindersError.noAccess }
        }
        func reset() { calls.append("reset") }
    }

    @Test func appliesEachOpAndReportsFailures() {
        let ops = [
            AssistantReminderOp(op: "add", list: "L1", listTitle: "Groceries", title: "Milk",
                                due: .set(ReminderDue(day: Day(year: 2026, month: 11, day: 7)))),
            AssistantReminderOp(op: "update", id: "r1", itemTitle: "X", list: "L2", listTitle: "Work", notes: "", due: .clear),
            AssistantReminderOp(op: "complete", id: "gone", itemTitle: "Gone", list: "L1", listTitle: "Groceries"),
            AssistantReminderOp(op: "update", id: "r2", itemTitle: "Y", list: "L9", listTitle: "Nowhere", title: "Z"),
            AssistantReminderOp(op: "uncomplete", id: "r3", itemTitle: "W", list: "L1", listTitle: "Groceries"),
            AssistantReminderOp(op: "delete", id: "r4", itemTitle: "V", list: "L1", listTitle: "Groceries"),
            AssistantReminderOp(op: "teleport", list: "", listTitle: ""),
        ]
        let fake = FakeReminders()
        fake.missing = ["gone"]
        let results = AssistantRemindersApply.perform(ops, on: fake)
        #expect(fake.calls == [
            "add Milk L1 2026-11-07 -",
            "update r1 - clear clear L2",
            "uncomplete r3",
            "delete r4",
            "commit",
        ])
        #expect(results.map(\.ok) == [true, true, false, false, true, true, false])
        #expect(results[0].id == "new-Milk")
        #expect(results[1].id == "r1")
        #expect(results[2].error == RemindersError.reminderNotFound.errorDescription)
        #expect(results[3].error == RemindersError.listNotFound.errorDescription)

        let broken = FakeReminders()
        broken.commitFails = true
        let none = AssistantRemindersApply.perform(Array(ops.prefix(2)), on: broken)
        #expect(broken.calls.suffix(2) == ["commit", "reset"])
        #expect(none.allSatisfy { !$0.ok && $0.error == RemindersError.noAccess.errorDescription })

        // Nothing went through: nothing to save.
        let nothing = FakeReminders()
        nothing.missing = ["gone"]
        _ = AssistantRemindersApply.perform([ops[2]], on: nothing)
        #expect(nothing.calls.isEmpty)
    }
}

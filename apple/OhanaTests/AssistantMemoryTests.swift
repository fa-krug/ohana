import Foundation
import Testing
@testable import Ohana

/// The assistant's memory: GET /ai/memories as the page decodes and groups it, the demo's copy,
/// the chat's tool row and memories card (decoding, applying, answering).
struct AssistantMemoryTests {
    private func decode(_ json: String) throws -> AssistantMemoryList {
        try APIClient.decoder.decode(AssistantMemoryList.self, from: Data(json.utf8))
    }

    private func tool(_ name: String, args: [String: JSONValue] = [:]) -> AssistantToolCall {
        AssistantToolCall(id: "t", name: name, args: args, status: "ok", summary: nil, result: #"{"ok":true,"waiting":true}"#,
                          interrupted: false)
    }

    @Test func decodesWithAndWithoutAuthorAndUnknownModules() throws {
        let list = try decode("""
        {"memories": [
          {"id": "m1", "module": "finance", "text": "H&M goes to Kids.", "createdAt": "2026-11-01T10:00:00.000Z",
           "updatedAt": "2026-11-02T10:00:00.000Z", "createdBy": {"id": "u1", "name": "Anna"}},
          {"id": "m2", "module": "general", "text": "Call me Ben.", "createdAt": "2026-11-01T10:00:00.000Z",
           "updatedAt": "2026-11-01T10:00:00.000Z", "createdBy": null},
          {"id": "m3", "module": "garden", "text": "Water on Mondays.", "createdAt": "2026-11-01T10:00:00.000Z",
           "updatedAt": "2026-11-01T10:00:00.000Z"}
        ]}
        """)
        #expect(list.memories.map(\.id) == ["m1", "m2", "m3"])
        #expect(list.memories[0].module == .finance)
        #expect(list.memories[0].createdBy == .init(id: "u1", name: "Anna"))
        #expect(list.memories[1].createdBy == nil)
        #expect(list.memories[2].createdBy == nil)
        #expect(list.memories[2].module == .other("garden"))
        #expect(list.memories[2].module.rawValue == "garden")
    }

    @Test func modulesRoundTrip() throws {
        for module in AssistantMemoryModule.known + [.other("x")] {
            #expect(AssistantMemoryModule(rawValue: module.rawValue) == module)
            let data = try JSONEncoder().encode(module)
            #expect(try JSONDecoder().decode(AssistantMemoryModule.self, from: data) == module)
        }
    }

    @Test func groupsByModuleInTheServersOrder() {
        func memory(_ id: String, _ module: AssistantMemoryModule) -> AssistantMemory {
            AssistantMemory(id: id, module: module, text: id, createdAt: "", updatedAt: "", createdBy: nil)
        }
        let list = AssistantMemoryList(memories: [
            memory("a", .meals), memory("b", .other("zoo")), memory("c", .finance), memory("d", .meals),
            memory("e", .general), memory("f", .other("attic")),
        ])
        let sections = list.sections
        #expect(sections.map(\.module) == [.general, .finance, .meals, .other("attic"), .other("zoo")])
        // Each module's in the order they came (the server's: oldest first).
        #expect(sections.first { $0.module == .meals }?.memories.map(\.id) == ["a", "d"])
        #expect(list.count(of: .meals) == 2)
        #expect(list.count(of: .chores) == 0)
        #expect(AssistantMemoryList(memories: []).sections.isEmpty)
    }

    @Test func demoHasMemories() throws {
        let url = DemoServer.baseURL.appending(path: "/api/v1/families/demo/ai/memories")
        let (data, response) = DemoServer().respond(to: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(!String(decoding: data, as: UTF8.self).contains("{{"))
        let list = try APIClient.decoder.decode(AssistantMemoryList.self, from: data)
        #expect(!list.memories.isEmpty)
        #expect(list.memories.allSatisfy { !$0.text.isEmpty && $0.text.count <= AssistantMemoryModule.maxLength })
        #expect(list.sections.map(\.module).allSatisfy { AssistantMemoryModule.known.contains($0) })
    }

    @Test func namesAndLinksTheTool() {
        let ops: JSONValue = .array([
            .object(["action": .string("add"), "module": .string("finance"), "text": .string("H&M goes to Kids.")]),
            .object(["action": .string("remove"), "id": .string("m1")]),
        ])
        let call = tool("edit_memories", args: ["ops": ops])
        #expect(AssistantToolLabels.label(call) == "Suggesting what to remember")
        #expect(AssistantToolLabels.icon("edit_memories") == "brain")
        #expect(AssistantToolLabels.detail(call).hasPrefix("2 changes"))
        #expect(AssistantToolLabels.detail(call).contains("H&M goes to Kids."))
        #expect(AssistantToolLinks.route(call, familyID: "fam") == .settings(.assistantMemory))
        // It writes nothing itself: the card's Save reloads the memory page.
        #expect(AssistantChangeAreas.areas(tool: "edit_memories").isEmpty)
    }

    @Test func decodesTheMemoriesItem() throws {
        let json = """
        {"kind": "memories", "id": "call_1", "summary": "Remember 3 things", "ops": [
          {"action": "add", "module": "finance", "text": "H&M goes to Kids."},
          {"action": "update", "id": "m2", "module": "meals", "text": "No fish on weekdays.",
           "old": {"module": "meals", "text": "No fish."}},
          {"action": "remove", "id": "m3", "module": "garden", "text": "Water on Mondays."},
          {"action": "shout", "text": "?"}
        ]}
        """
        let item = try JSONDecoder().decode(AssistantItem.self, from: Data(json.utf8))
        guard case let .memories(edit) = item else {
            Issue.record("not a memories item: \(item)")
            return
        }
        #expect(item.canWait)
        #expect(edit.id == "call_1")
        #expect(edit.summary == "Remember 3 things")
        #expect(edit.ops.map(\.action) == [.add, .update, .remove, .unknown])
        #expect(edit.ops[0].module == .finance)
        #expect(edit.ops[1].id == "m2")
        #expect(edit.ops[1].old == .init(module: .meals, text: "No fish."))
        #expect(edit.ops[2].module == .other("garden"))
        #expect(edit.ops[3].module == .general)
        #expect(edit.ops.map(\.editable) == [true, true, false, false])
        #expect(edit.initialPicks == [0, 1, 2])
        #expect(edit.answer == nil && !edit.skipped)
        #expect(edit.outcome == nil)

        let answered = """
        {"kind": "memories", "id": "call_1", "summary": "x", "ops": [{"action": "add", "text": "a"}, {"action": "add", "text": "b"}],
         "answer": {"applied": true, "results": [{"ok": true, "id": "m9"}, {"ok": false, "declined": true}]}}
        """
        guard case let .memories(done) = try JSONDecoder().decode(AssistantItem.self, from: Data(answered.utf8)) else {
            Issue.record("not a memories item")
            return
        }
        #expect(done.answer?.results == [.done("m9"), .declined])
        #expect(done.outcome == "Saved 1 of 2")
    }

    /// The memory routes, faked: what was called, failing for the texts in `failing`.
    private final class FakeWriter: AssistantMemoryWriting {
        var calls: [String] = []
        var failing: Set<String> = []

        struct Failure: LocalizedError { var errorDescription: String? { "Nope" } }

        func add(module: AssistantMemoryModule, text: String) async throws -> String {
            calls.append("add \(module.rawValue) \(text)")
            if failing.contains(text) { throw Failure() }
            return "new-\(calls.count)"
        }

        func update(id: String, module: AssistantMemoryModule, text: String) async throws {
            calls.append("update \(id) \(module.rawValue) \(text)")
            if failing.contains(text) { throw Failure() }
        }

        func remove(id: String) async throws {
            calls.append("remove \(id)")
        }
    }

    @Test func appliesTickedOpsAndRetriesTheFailedOnes() async {
        let ops = [
            AssistantMemoryOp(action: "add", module: .finance, text: "H&M goes to Kids."),
            AssistantMemoryOp(action: "update", id: "m2", module: .meals, text: "No fish.", old: .init(module: .meals, text: "x")),
            AssistantMemoryOp(action: "remove", id: "m3", module: .general, text: "Old"),
            AssistantMemoryOp(action: "add", module: .chores, text: "Unticked"),
            AssistantMemoryOp(action: "add", module: .general, text: "Too long"),
        ]
        let writer = FakeWriter()
        writer.failing = ["No fish on weekdays."]
        let first = await AssistantMemoriesApply.perform(
            ops, picks: [0, 1, 2, 4], texts: [1: " No fish on weekdays. ", 4: String(repeating: "x", count: 301)],
            writer: writer
        )
        #expect(first[0] == .done("new-1"))
        #expect(first[1] == .failed("Nope"))
        #expect(first[2] == .done("m3"))
        #expect(first[3] == .declined)
        #expect(first[4] == .failed(AssistantMemoriesApply.ApplyError.length.localizedDescription))
        // The user's text, trimmed; the unticked one and the one too long never reach the server.
        #expect(writer.calls == ["add finance H&M goes to Kids.", "update m2 meals No fish on weekdays.", "remove m3"])

        // Save again: only what failed is tried, what went through stays.
        writer.calls = []
        writer.failing = []
        let previous = Dictionary(uniqueKeysWithValues: first.enumerated().filter { !$0.element.isDeclined }.map { ($0.offset, $0.element) })
        let second = await AssistantMemoriesApply.perform(
            ops, picks: [0, 1, 2], texts: [1: "No fish on weekdays."], previous: previous, writer: writer
        )
        #expect(second == [.done("new-1"), .done("m2"), .done("m3"), .declined, .declined])
        #expect(writer.calls == ["update m2 meals No fish on weekdays."])
    }

    @Test func notNowAnswersDeclinedOrWhatWentThrough() throws {
        let edit = AssistantMemoriesEdit(id: "call_1", summary: "x", ops: [
            AssistantMemoryOp(action: "add", text: "a"), AssistantMemoryOp(action: "add", text: "b"),
        ], answer: nil, skipped: false)
        #expect(AssistantChatStore.memoriesDeclined(edit, tried: [:]) == .init(applied: false, results: nil))
        #expect(AssistantChatStore.memoriesDeclined(edit, tried: [1: .failed("x")]) == .init(applied: false, results: nil))
        #expect(AssistantChatStore.memoriesDeclined(edit, tried: [0: .done("m1"), 1: .failed("x")])
                == .init(applied: true, results: [.done("m1"), .declined]))

        // The body of POST /ai/chats/{id}/memories: the suggestions' shape.
        let body = AssistantChatStore.remindersAnswer(
            id: "call_1", answer: .init(applied: true, results: [.done("m1"), .declined, .failed("No")]),
            page: "assistant", year: 2026, lang: "en", today: "2026-11-08", reminders: nil
        )
        let a = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(body)) as? [String: Any]
        #expect(a?["id"] as? String == "call_1")
        #expect(a?["applied"] as? Bool == true)
        let results = a?["results"] as? [[String: Any]] ?? []
        #expect(results.count == 3)
        #expect(results[0]["ok"] as? Bool == true)
        #expect(results[0]["id"] as? String == "m1")
        #expect(results[1]["ok"] as? Bool == false)
        #expect(results[1]["declined"] as? Bool == true)
        #expect(results[2]["ok"] as? Bool == false)
        #expect(results[2]["error"] as? String == "No")
    }

    @Test func memoryPageRoute() {
        #expect(AppRoute.settings(.assistantMemory).module == .settings)
        #expect(AppRoute.settings(.assistantMemory).requiredModule == .assistant)
        #expect(AppRoute.parse(link: "/f/fam/settings?tab=memory")?.route == .settings(.assistantMemory))
        #expect(FamilySettingsPageView.page(for: .settings(.assistantMemory)) == .assistantMemory)
    }
}

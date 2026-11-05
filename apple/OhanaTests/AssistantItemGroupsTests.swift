import Testing
@testable import Ohana

/// The chat's rows: tool calls one after the other are one row, keyed by the first one's position.
struct AssistantItemGroupsTests {
    private static func tool(_ id: String, _ status: String = "ok") -> AssistantToolCall {
        AssistantToolCall(id: id, name: "list_recipes", args: [:], status: status, summary: nil, result: nil,
                          interrupted: false)
    }

    @Test func groupsToolCallsBetweenOtherItems() {
        let items: [(offset: Int, item: AssistantItem)] = [
            (0, .user(text: "Plan meals", attachments: [])),
            (1, .tool(Self.tool("a"))),
            (3, .tool(Self.tool("b"))),
            (4, .tool(Self.tool("c"))),
            (5, .assistant(text: "Done.")),
            (6, .tool(Self.tool("d"))),
            (7, .change(AssistantChange(id: "x", change: "plan", summary: "Planned", undo: [], undone: false))),
            (8, .tool(Self.tool("e"))),
        ]
        let entries = AssistantItemGroups.make(items)
        #expect(entries.map(\.id) == [0, 1, 5, 6, 7, 8])
        #expect(entries.map(\.range) == [0..<1, 1..<4, 4..<5, 5..<6, 6..<7, 7..<8])
        #expect(entries.map(\.isTools) == [false, true, false, true, false, true])
        #expect(AssistantItemGroups.make([]).isEmpty)
    }

    @Test func aGrowingGroupKeepsItsKey() {
        var items: [(offset: Int, item: AssistantItem)] = [
            (0, .user(text: "Hi", attachments: [])),
            (1, .tool(Self.tool("a", "running"))),
        ]
        #expect(AssistantItemGroups.make(items).last == .init(id: 1, range: 1..<2, isTools: true))
        items.append((2, .tool(Self.tool("b", "running"))))
        #expect(AssistantItemGroups.make(items).last == .init(id: 1, range: 1..<3, isTools: true))
        // Two answers one after the other stay two rows.
        items.append((3, .assistant(text: "One")))
        items.append((4, .assistant(text: "Two")))
        #expect(AssistantItemGroups.make(items).map(\.id) == [0, 1, 3, 4])
    }

    @Test func summarisesAGroup() {
        // While one runs: the last one started.
        let running = [Self.tool("a"), Self.tool("b", "running"), Self.tool("c", "running")]
        #expect(AssistantItemGroups.summary(running) == .running(Self.tool("c", "running")))
        #expect(AssistantItemGroups.summary([Self.tool("a"), Self.tool("b")]) == .used(count: 2, failed: false))
        #expect(AssistantItemGroups.summary([Self.tool("a"), Self.tool("b", "error")]) == .used(count: 2, failed: true))
    }
}

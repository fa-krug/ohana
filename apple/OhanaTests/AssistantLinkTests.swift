import Foundation
#if os(macOS)
import AppKit
#endif
import Testing
@testable import Ohana

/// What a tool call links to (result shapes of server/lib/assistant/tools/*).
struct AssistantToolLinkTests {
    private func tool(_ name: String, args: [String: JSONValue] = [:], result: String? = nil,
                      status: String = "ok") -> AssistantToolCall {
        AssistantToolCall(id: "t", name: name, args: args, status: status, summary: nil, result: result, interrupted: false)
    }

    private func route(_ t: AssistantToolCall) -> AppRoute? { AssistantToolLinks.route(t, familyID: "fam") }

    @Test func recipes() {
        #expect(route(tool("save_recipe", result: #"{"ok":true,"id":"r1","title":"Soup","url":"/f/fam/meals/recipes/r1"}"#))
                == .recipe(id: "r1"))
        // Cut short by the chat (2,000 characters): the id is still found.
        #expect(route(tool("get_recipe", result: #"{"id":"r2","title":"Stew","ingredients":[{"name":"Sa…(truncated)"#))
                == .recipe(id: "r2"))
        // A failed call links nowhere.
        #expect(route(tool("save_recipe", result: #"{"error":"x"}"#, status: "error")) == nil)
    }

    @Test func calendarDays() {
        #expect(route(tool("add_event", result: #"{"id":"e1","date":"2026-11-03","title":"Dentist"}"#))
                == .calendarDay(Day(year: 2026, month: 11, day: 3)))
        let ops: JSONValue = .array([
            .object(["action": .string("set"), "type": .string("Holiday"), "dates": .array([.string("2026-12-26"), .string("2026-12-24")])]),
            .object(["action": .string("clear"), "from": .string("2027-01-02"), "to": .string("2027-01-05")]),
        ])
        #expect(route(tool("change_entries", args: ["ops": ops], result: #"{"ok":true,"days":4}"#))
                == .calendarDay(Day(year: 2026, month: 12, day: 24)))
        #expect(route(tool("get_calendar", args: ["from": .string("2026-01-01")])) == nil)
    }

    @Test func appointments() {
        let booked = #"{"ok":true,"event":{"id":"e1","date":"2026-11-04","start":"09:30","searchId":"s1"},"searchStopped":false}"#
        #expect(route(tool("book_appointment_slot", args: ["search": .string("Dermatologist"), "resultId": .number(42)],
                           result: booked)) == .appointmentSlot(searchID: "s1", resultID: "42"))
        #expect(route(tool("get_appointment_slot", args: ["resultId": .number(7)],
                           result: #"{"resultId":7,"doctorName":"Dr. A","page":"/f/fam/appointments/s2/slots/7"}"#))
                == .appointmentSlot(searchID: "s2", resultID: "7"))
        #expect(route(tool("create_appointment_search", result: #"{"ok":true,"id":"s3","name":"Skin","page":"/f/fam/appointments/s3"}"#))
                == .appointmentSearch(id: "s3"))
    }

    @Test func shoppingMealsAndFinance() {
        #expect(route(tool("add_shopping_items", result: #"{"ok":true,"listId":"l1","added":["Milk"]}"#)) == .shoppingList(id: "l1"))
        #expect(route(tool("tick_shopping_items", args: ["items": .array([.string("Milk")])], result: #"{"ok":true}"#))
                == .shoppingList(id: nil))
        #expect(route(tool("get_shopping_list", result: #"{"id":"l2","shoppingDate":"2026-11-01","items":[]}"#))
                == .shoppingList(id: "l2"))
        #expect(route(tool("plan_meals", result: #"{"ok":true}"#)) == .mealPlan)
        #expect(route(tool("manage_categories", args: ["action": .string("add")],
                           result: #"{"id":"c1","name":"Bakery","parentId":null}"#))
                == .financeTransactions(categoryID: "c1"))
        #expect(route(tool("manage_categories", args: ["action": .string("delete")], result: #"{"deleted":"c1"}"#)) == nil)
    }

    @Test func pagesOfOtherFamiliesAreNotLinked() {
        #expect(route(tool("future_tool", result: #"{"page":"/f/other/meals/recipes/r1"}"#)) == nil)
        #expect(route(tool("future_tool", result: #"{"page":"/f/fam/meals/recipes/r1"}"#)) == .recipe(id: "r1"))
        #expect(route(tool("web_search", result: #"{"results":[]}"#)) == nil)
    }

    @Test func appLinksInAnswersStay() {
        let s = AssistantMarkdownBlock.inline("[Soup](/f/fam/meals/recipes/r1) [bad](file:///etc/passwd)")
        #expect(s.runs.compactMap(\.link).map(\.path) == ["/f/fam/meals/recipes/r1"])
    }
}

/// Counted strings in English (the German ones are plural variants in the catalog).
struct AssistantPluralTests {
    @Test func inflectsCounts() {
        let one = AssistantToolCall(id: "t", name: "change_transactions",
                                    args: ["ops": .array([.object(["action": .string("update")])])],
                                    status: "ok", summary: nil, result: nil, interrupted: false)
        #expect(AssistantToolLabels.detail(one) == "1 change")
        let three = AssistantToolCall(id: "t", name: "change_transactions",
                                      args: ["ops": .array([.object(["action": .string("delete"),
                                                                      "ids": .array([.string("a"), .string("b"), .string("c")])])])],
                                      status: "ok", summary: nil, result: nil, interrupted: false)
        #expect(AssistantToolLabels.detail(three) == "3 changes")
        #expect(AssistantAttachments.limitMessage == "At most 4 attachments per message.")
    }
}

/// Attachments: limits as on the web (attachments.ts).
struct AssistantAttachmentTests {
    @Test func limitsAsOnTheWeb() {
        #expect(AssistantAttachments.maxCount == 4)
        #expect(AssistantAttachments.maxImageBytes == 20 * 1024 * 1024)
        #expect(AssistantAttachments.maxTextBytes == 2 * 1024 * 1024)
        #expect(AssistantAttachments.maxTextChars == 50_000)
    }

    @Test func cutsLongText() {
        let long = String(repeating: "a", count: 50_010)
        let cut = AssistantAttachments.cut(long)
        #expect(cut.hasPrefix(String(repeating: "a", count: 50_000)))
        #expect(AssistantAttachments.wasCut(AssistantPendingAttachment(kind: "file", name: "x.txt", text: cut)))
        #expect(!AssistantAttachments.wasCut(AssistantPendingAttachment(kind: "file", name: "x.txt", text: "short")))
    }

    @Test func kindsByExtension() {
        #expect(AssistantAttachments.kind(of: URL(fileURLWithPath: "/tmp/a.png")) == "image")
        #expect(AssistantAttachments.kind(of: URL(fileURLWithPath: "/tmp/a.csv")) == "file")
        #expect(AssistantAttachments.kind(of: URL(fileURLWithPath: "/tmp/a.md")) == "file")
        #expect(AssistantAttachments.kind(of: URL(fileURLWithPath: "/tmp/a.zip")) == nil)
    }

    @Test func readsAFileAndRefusesTooBigOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appending(path: "list.csv")
        try Data("a,b\n1,2\n".utf8).write(to: small)
        let read = try AssistantAttachments.read(small)
        #expect(read.kind == "file" && read.name == "list.csv" && read.text == "a,b\n1,2\n")
        let big = dir.appending(path: "big.txt")
        try Data(count: AssistantAttachments.maxTextBytes + 1).write(to: big)
        #expect(throws: AssistantAttachmentError.self) { try AssistantAttachments.read(big) }
    }

    @Test func dictationJoinsWhatItHeard() {
        #expect(AssistantDictation.joined("", "Hello") == "Hello")
        #expect(AssistantDictation.joined("Plan", "next week") == "Plan next week")
        #expect(AssistantDictation.joined("Plan ", "next week") == "Plan next week")
    }

    #if os(macOS)
    @Test func pastesPicturesNotText() {
        let board = NSPasteboard(name: NSPasteboard.Name("ohana-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("hello", forType: .string)
        #expect(AssistantPasteboard.content(board) == nil)
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        #expect(AssistantPasteboard.content(board) == .image(Data([1, 2, 3])))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a.zip") as NSURL])
        #expect(AssistantPasteboard.content(board) == nil)
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/shot.png") as NSURL])
        #expect(AssistantPasteboard.content(board) == .files([URL(fileURLWithPath: "/tmp/shot.png")]))
    }
    #endif
}

/// Answers every request with 204 (nothing leaves the test).
nonisolated final class AssistantStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The store's part in asking (new chats without empty duplicates) and undo's confirmation.
struct AssistantAskTests {
    private func store() -> AssistantChatStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssistantStubProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://x.example")!, token: nil, session: URLSession(configuration: config))
        return AssistantChatStore(api: FamilyAPI(client: client, familyID: "f1"))
    }

    @Test func aNewChatOnlyWhenTheOpenOneHasSomething() {
        let store = store()
        store.newChatUnlessEmpty()
        #expect(store.current == nil)
        store.show(AssistantChat(id: "c1", title: "Hi", status: "idle", items: [.user(text: "Hi", attachments: [])],
                                 rev: 1, usage: nil, page: "overview", queued: []))
        #expect(!store.isEmptyChat)
        store.newChatUnlessEmpty()
        #expect(store.current == nil)
        #expect(store.currentID == nil)
    }

    @Test func undoConfirmsInTheBanner() async {
        let store = store()
        store.show(AssistantChat(id: "c1", title: "Hi", status: "idle", items: [
            .change(AssistantChange(id: "chg", change: "entries", summary: "Added", undo: [], undone: false)),
        ], rev: 1, usage: nil, page: "overview", queued: []))
        await store.undo("chg")
        #expect(store.current?.items.first == .change(AssistantChange(id: "chg", change: "entries", summary: "Added",
                                                                       undo: [], undone: true)))
        #expect(ErrorBanner.shared.message == "Undone")
        #expect(ErrorBanner.shared.isSuccess)
    }
}

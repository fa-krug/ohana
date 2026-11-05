import Foundation
import Testing
@testable import Ohana

/// The assistant's notes in the knowledge folder: the edit item, its lines and the dialog before
/// writing, writing into a real folder, and the requests naming the folder.
struct AssistantNotesTests {
    static let itemsJSON = """
    {
      "chat": { "id": "c1", "title": "Car", "status": "idle", "updatedAt": "2026-11-01T08:00:00.000Z" },
      "rev": 3,
      "items": [
        { "kind": "notes", "id": "call_1", "summary": "Create 1 note, change 3 notes",
          "ops": [
            { "op": "create", "path": "Notes/Car.md", "title": "Car.md", "content": "# Car\\n", "tags": ["Car"] },
            { "op": "update", "documentId": "d1", "path": "Home.md", "title": "Home.md", "baseHash": "ABC",
              "change": "append", "content": "Old\\n\\nNew\\n", "added": "New" },
            { "op": "update", "documentId": "d2", "path": "A/B/Plan.md", "title": "Plan.md", "baseHash": "def",
              "change": "replace", "content": "Bus at 8", "replacements": [ { "find": "Train", "with": "Bus" } ] },
            { "op": "update", "documentId": "d3", "path": "Tags.md", "title": "Tags.md", "baseHash": "123",
              "change": "tags", "content": "Same", "tags": [] },
            { "op": "teleport", "path": "X.md" }
          ] },
        { "kind": "notes", "id": "call_2", "summary": "S", "ops": [ { "op": "create", "path": "Y.md", "content": "y" } ],
          "answer": { "applied": true, "results": [ { "ok": false, "error": "A file with this name already exists." } ] } },
        { "kind": "notes", "id": "call_3", "summary": "S", "ops": [], "answer": { "applied": false } },
        { "kind": "notes", "id": "call_4", "summary": "S", "ops": [], "skipped": true }
      ]
    }
    """

    @Test func decodesTheNotesItem() throws {
        let state = try JSONDecoder().decode(AssistantChatState.self, from: Data(Self.itemsJSON.utf8))
        #expect(state.items.count == 4)
        guard case let .notes(open) = state.items[0] else { Issue.record("notes"); return }
        #expect(open.id == "call_1")
        #expect(open.answer == nil)
        #expect(!open.skipped)
        #expect(open.ops.map(\.op) == ["create", "update", "update", "update", "teleport"])
        #expect(open.ops[0] == AssistantNoteOp(op: "create", path: "Notes/Car.md", title: "Car.md", content: "# Car\n",
                                               tags: ["Car"]))
        #expect(open.ops[0].folder == "Notes")
        #expect(open.ops[1] == AssistantNoteOp(op: "update", documentId: "d1", path: "Home.md", baseHash: "ABC",
                                               change: "append", content: "Old\n\nNew\n", added: "New"))
        #expect(open.ops[1].folder == "")
        #expect(open.ops[1].tags == nil)
        #expect(open.ops[2].replacements == [.init(find: "Train", with: "Bus")])
        #expect(open.ops[2].folder == "A/B")
        #expect(open.ops[3].tags == [])
        #expect(open.ops[3].tagsOnly)
        #expect(!open.ops[2].tagsOnly)
        // Without a title: the path's last part.
        #expect(open.ops[4].title == "X.md")
        #expect(open.outcome == nil)

        guard case let .notes(failed) = state.items[1], case let .notes(declined) = state.items[2],
              case let .notes(skipped) = state.items[3] else { Issue.record("answered"); return }
        #expect(failed.ops[0].title == "Y.md")
        #expect(failed.outcome == "Applied, 1 of 1 failed")
        #expect(declined.outcome == "Not applied")
        #expect(skipped.outcome == "Not answered")
    }

    @Test func findsTheWaitingEdit() {
        let edit = AssistantNotesEdit(id: "n1", summary: "Create “Car.md”", ops: [], answer: nil, skipped: false)
        let reminders = AssistantRemindersEdit(id: "r1", summary: "Add “Milk”", ops: [], answer: nil, skipped: false)
        func store(_ items: [AssistantItem]) -> AssistantChatStore {
            let store = AssistantChatStore(api: FamilyAPI(client: APIClient(baseURL: URL(string: "https://x.example")!,
                                                                            token: nil), familyID: "f1"))
            store.show(AssistantChat(id: "c1", title: "C", status: "idle", items: items, rev: 1, usage: nil, page: "overview",
                                     queued: []))
            return store
        }
        // Only the last of them waits.
        #expect(store([.reminders(reminders), .notes(edit)]).openNotesEdit()?.edit.id == "n1")
        #expect(store([.reminders(reminders), .notes(edit)]).openRemindersEdit() == nil)
        #expect(store([.notes(edit), .user(text: "No", attachments: [])]).openNotesEdit() == nil)
        var answered = edit
        answered.answer = .init(applied: true, results: [])
        #expect(store([.notes(answered)]).openNotesEdit() == nil)
    }

    @Test func describesTheOps() {
        let create = AssistantNoteOp(op: "create", path: "Insurance/Car/Car.md", content: "# Car", tags: ["Car", "Insurance"])
        let created = AssistantNoteOpLine.make(create)
        #expect(created.icon == "doc.badge.plus")
        #expect(created.text == "Create “Car.md” in Insurance › Car")
        #expect(created.detail == "Tags: Car, Insurance")
        #expect(created.preview == .text("# Car"))
        let top = AssistantNoteOpLine.make(AssistantNoteOp(op: "create", path: "Ideas.md", content: "x", tags: []))
        #expect(top.text == "Create “Ideas.md” in Knowledge")
        #expect(top.detail == nil)

        let rewrite = AssistantNoteOpLine.make(AssistantNoteOp(op: "update", path: "Notes/Car.md", baseHash: "h",
                                                               change: "content", content: "New"))
        #expect(rewrite.icon == "square.and.pencil")
        #expect(rewrite.text == "Change “Car.md”")
        #expect(rewrite.detail == "Notes · replaces the whole text")
        #expect(rewrite.preview == .text("New"))
        let append = AssistantNoteOpLine.make(AssistantNoteOp(op: "update", path: "Car.md", baseHash: "h", change: "append",
                                                              content: "Old\n\nNew\n", added: "New"))
        #expect(append.detail == "Knowledge")
        #expect(append.preview == .added("New"))
        let replace = AssistantNoteOpLine.make(AssistantNoteOp(op: "update", path: "Car.md", baseHash: "h", change: "replace",
                                                               content: "Bus", replacements: [.init(find: "Train", with: "Bus")],
                                                               tags: ["Car"]))
        #expect(replace.detail == "Knowledge · Tags: Car")
        #expect(replace.preview == .replacements([.init(find: "Train", with: "Bus")]))
        let tags = AssistantNoteOpLine.make(AssistantNoteOp(op: "update", path: "Car.md", baseHash: "h", change: "tags",
                                                            content: "Same", tags: []))
        #expect(tags.detail == "Knowledge · remove the tags")
        #expect(tags.preview == nil)

        // Long texts are collapsed.
        #expect(!AssistantNoteOpLine.Preview.text("One\nTwo\nThree\nFour").isLong)
        #expect(AssistantNoteOpLine.Preview.text("One\nTwo\nThree\nFour\nFive").isLong)
        #expect(AssistantNoteOpLine.Preview.added(String(repeating: "a", count: 400)).isLong)
        #expect(!AssistantNoteOpLine.Preview.replacements([.init(find: "a", with: "b")]).isLong)
        #expect(AssistantNoteOpLine.Preview.replacements([.init(find: "a\nb\nc", with: "b")]).isLong)
    }

    // MARK: Writing

    /// A folder of its own under the temporary directory, as the linked knowledge folder.
    private final class Folder {
        let root = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        var queued: [(path: String, pages: [String])] = []
        var reindexed = 0
        var folderID = "kf1"
        var linked = true

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var notes: AssistantKnowledgeNotes {
            AssistantKnowledgeNotes(
                state: { [unowned self] in self.linked ? .linked(url: self.root, folderID: self.folderID) : .none },
                enqueue: { [unowned self] file, pages in
                    let base = self.root.path(percentEncoded: false)
                    self.queued.append((file.path(percentEncoded: false).replacingOccurrences(of: base, with: ""), pages))
                },
                reindex: { [unowned self] in self.reindexed += 1 }
            )
        }

        func url(_ path: String) -> URL { root.appending(path: path, directoryHint: .notDirectory) }

        func text(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }

        func write(_ path: String, _ text: String) throws -> String {
            let file = url(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: file)
            return AssistantNotesApply.hash(data)
        }
    }

    @Test func createsNotes() async throws {
        let folder = try Folder()
        // A folder whose name the disk spells NFD is found, not made twice.
        let nfd = "Cafe\u{301}"
        try FileManager.default.createDirectory(at: folder.root.appending(path: nfd), withIntermediateDirectories: true)
        _ = try folder.write("Taken.md", "x")
        let ops = [
            AssistantNoteOp(op: "create", path: "Notes/Sub/Car.md", content: "# Car\n", tags: ["Car", "Family"]),
            AssistantNoteOp(op: "create", path: "Taken.md", content: "y"),
            AssistantNoteOp(op: "create", path: "Café/Menu.md", content: "Soup"),
            AssistantNoteOp(op: "create", path: "Ideas.md", content: "Plain"),
        ]
        let results = await AssistantNotesApply.perform(ops, notes: folder.notes, folderID: "kf1")
        #expect(results.map(\.ok) == [true, false, true, true])
        #expect(results[0].id == "Notes/Sub/Car.md")
        #expect(results[1].error == AssistantNotesError.exists.localizedDescription)
        #expect(folder.text("Notes/Sub/Car.md") == "# Car\n")
        #expect(FinderTags.read(folder.url("Notes/Sub/Car.md")) == ["Car", "Family"])
        #expect(folder.text("Taken.md") == "x")
        #expect(try String(contentsOf: folder.root.appending(path: nfd).appending(path: "Menu.md"), encoding: .utf8) == "Soup")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.root.path(percentEncoded: false))
        #expect(names.filter { $0.precomposedStringWithCanonicalMapping == "Café" }.count == 1)
        #expect(FinderTags.read(folder.url("Ideas.md")).isEmpty)
        #expect(folder.queued.map(\.pages) == [["# Car\n"], ["Soup"], ["Plain"]])
        #expect(folder.queued.first?.path.hasSuffix("Notes/Sub/Car.md") == true)
        #expect(folder.reindexed == 0)
    }

    @Test func updatesOnlyTheNoteTheAssistantRead() async throws {
        let folder = try Folder()
        let home = try folder.write("Home.md", "Old\n")
        try FinderTags.write(["House"], to: folder.url("Home.md"))
        let plan = try folder.write("Plan.md", "Train at 8")
        let tagged = try folder.write("Tags.md", "Same")
        let ops = [
            AssistantNoteOp(op: "update", documentId: "d1", path: "Home.md", baseHash: home.uppercased(), change: "append",
                            content: "Old\n\nNew\n", added: "New"),
            AssistantNoteOp(op: "update", documentId: "d2", path: "Plan.md", baseHash: "0000", change: "replace",
                            content: "Bus at 8", replacements: [.init(find: "Train", with: "Bus")]),
            AssistantNoteOp(op: "update", documentId: "d3", path: "Tags.md", baseHash: tagged, change: "tags",
                            content: "Ignored", tags: ["Car"]),
            AssistantNoteOp(op: "update", documentId: "d4", path: "Gone.md", baseHash: "x", change: "content", content: "z"),
        ]
        let results = await AssistantNotesApply.perform(ops, notes: folder.notes, folderID: nil)
        #expect(results.map(\.ok) == [true, false, true, false])
        // Written, its tags kept.
        #expect(folder.text("Home.md") == "Old\n\nNew\n")
        #expect(FinderTags.read(folder.url("Home.md")) == ["House"])
        // Changed since: left alone.
        #expect(results[1].error == AssistantNotesError.changed.localizedDescription)
        #expect(folder.text("Plan.md") == "Train at 8")
        #expect(AssistantNotesApply.hash(Data("Train at 8".utf8)) == plan)
        // Tags alone: the text isn't written, the folder is read again.
        #expect(folder.text("Tags.md") == "Same")
        #expect(FinderTags.read(folder.url("Tags.md")) == ["Car"])
        #expect(folder.reindexed == 1)
        #expect(results[3].error == AssistantNotesError.notFound.localizedDescription)
        #expect(folder.queued.map(\.pages) == [["Old\n\nNew\n"]])
    }

    @Test func staysInTheFolder() async throws {
        let folder = try Folder()
        let outside = folder.root.deletingLastPathComponent().appending(path: "evil-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        let paths = ["../\(outside.lastPathComponent)", ".hidden/x.md", "a//b.md", "/abs.md", "", "Notes/../x.md"]
        let results = await AssistantNotesApply.perform(paths.map { AssistantNoteOp(op: "create", path: $0, content: "x") },
                                                        notes: folder.notes, folderID: "kf1")
        #expect(results.allSatisfy { $0.error == AssistantNotesError.invalidPath.localizedDescription })
        #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.root.path(percentEncoded: false)).isEmpty)
        #expect(folder.queued.isEmpty)

        let update = AssistantNoteOp(op: "update", path: "../x.md", baseHash: "h", change: "content", content: "x")
        #expect(await AssistantNotesApply.perform([update], notes: folder.notes, folderID: "kf1")[0].error
            == AssistantNotesError.invalidPath.localizedDescription)
        let unknown = AssistantNoteOp(op: "delete", path: "x.md")
        #expect(await AssistantNotesApply.perform([unknown], notes: folder.notes, folderID: "kf1")[0].error
            == AssistantNotesError.unsupported.localizedDescription)
    }

    @Test func needsTheLinkedFolder() async throws {
        let folder = try Folder()
        let op = AssistantNoteOp(op: "create", path: "Car.md", content: "x")
        let notLinked = AssistantNotesError.notLinked.localizedDescription
        // Another folder than the requests named.
        #expect(await AssistantNotesApply.perform([op, op], notes: folder.notes, folderID: "other").map(\.error)
            == [notLinked, notLinked])
        #expect(await AssistantNotesApply.perform([op], notes: nil, folderID: nil)[0].error == notLinked)
        folder.linked = false
        #expect(await AssistantNotesApply.perform([op], notes: folder.notes, folderID: nil)[0].error == notLinked)
        #expect(folder.text("Car.md") == nil)
    }

    // MARK: Requests

    @Test func requestsNameTheFolder() throws {
        let message = AssistantChatInput(text: "Hi", attachments: nil, page: "overview", year: 2026, lang: "en",
                                         today: "2026-11-01", reminders: nil, appleCalendar: nil, knowledgeFolder: "kf1")
        let m = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(message)) as? [String: Any]
        #expect(m?["knowledgeFolder"] as? String == "kf1")
        let without = AssistantChatInput(text: "Hi", attachments: nil, page: "overview", year: 2026, lang: "en",
                                         today: "2026-11-01")
        let w = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(without)) as? [String: Any]
        #expect(w?.keys.contains("knowledgeFolder") == false)

        let answer = AssistantAnswerInput(id: "q", selected: ["A"], page: "overview", year: 2026, lang: "en",
                                          today: "2026-11-01", knowledgeFolder: "kf1")
        let a = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(answer)) as? [String: Any]
        #expect(a?["knowledgeFolder"] as? String == "kf1")

        let notes = AssistantChatStore.remindersAnswer(
            id: "call_1", answer: .init(applied: true, results: [.done("Notes/Car.md"), .failed("No")]), page: "overview",
            year: 2026, lang: "en", today: "2026-11-01", reminders: nil, knowledgeFolder: "kf1"
        )
        let n = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(notes)) as? [String: Any]
        #expect(n?["knowledgeFolder"] as? String == "kf1")
        let results = n?["results"] as? [[String: Any]] ?? []
        #expect(results.first?["id"] as? String == "Notes/Car.md")
        #expect(results.last?["error"] as? String == "No")
        let calendar = AssistantChatStore.calendarAnswer(
            id: "call_1", answer: .init(applied: false, results: nil), page: "overview", year: 2026, lang: "en",
            today: "2026-11-01", reminders: nil, appleCalendar: nil, knowledgeFolder: "kf1"
        )
        let c = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(calendar)) as? [String: Any]
        #expect(c?["knowledgeFolder"] as? String == "kf1")
    }

    private func store(_ items: [AssistantItem], folder: Folder) -> AssistantChatStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotesStubProtocol.self]
        let client = APIClient(baseURL: URL(string: "https://notes-\(UUID().uuidString).example")!, token: nil,
                               session: URLSession(configuration: config))
        let store = AssistantChatStore(api: FamilyAPI(client: client, familyID: "f1"))
        store.remindersContext = { nil }
        store.calendarContext = { nil }
        store.knowledgeNotes = { folder.notes }
        store.show(AssistantChat(id: "c1", title: "C", status: "idle", items: items, rev: 1, usage: nil, page: "overview",
                                 queued: []))
        return store
    }

    /// The body of the request to `path` on `host`, once it was sent.
    private func sent(_ path: String, host: String?) async throws -> [String: Any]? {
        for _ in 0..<200 {
            if let body = NotesStubProtocol.body(host: host, path: path) {
                return try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func appliesAndAnswers() async throws {
        let folder = try Folder()
        let edit = AssistantNotesEdit(id: "call_1", summary: "Create “Car.md”", ops: [
            AssistantNoteOp(op: "create", path: "Notes/Car.md", content: "# Car\n"),
            AssistantNoteOp(op: "update", path: "Gone.md", baseHash: "h", change: "content", content: "x"),
        ], answer: nil, skipped: false)
        let store = store([.notes(edit)], folder: folder)
        var changed: [[DataArea]] = []
        store.onChange = { changed.append($0) }
        #expect(await store.applyNotes("other") == .notWaiting)
        #expect(await store.applyNotes("call_1") == .answered)
        #expect(folder.text("Notes/Car.md") == "# Car\n")
        #expect(changed == [[.knowledge]])
        guard case let .notes(answered) = store.current?.items.first else { Issue.record("notes"); return }
        #expect(answered.answer?.applied == true)
        #expect(answered.answer?.results?.map(\.ok) == [true, false])
        let body = try await sent("/notes", host: store.api.client.baseURL.host())
        #expect(body?["id"] as? String == "call_1")
        #expect(body?["applied"] as? Bool == true)
        #expect(body?["knowledgeFolder"] as? String == "kf1")
        #expect((body?["results"] as? [[String: Any]])?.first?["id"] as? String == "Notes/Car.md")
        store.unfollow()
    }

    @Test func aNewMessageSkipsTheEdit() async throws {
        let folder = try Folder()
        let edit = AssistantNotesEdit(id: "call_1", summary: "S", ops: [], answer: nil, skipped: false)
        let store = store([.notes(edit)], folder: folder)
        try await store.send("Never mind")
        guard case let .notes(skipped) = store.current?.items.first else { Issue.record("notes"); return }
        #expect(skipped.skipped)
        let body = try await sent("/messages", host: store.api.client.baseURL.host())
        #expect(body?["text"] as? String == "Never mind")
        #expect(body?["knowledgeFolder"] as? String == "kf1")
        store.unfollow()

        // Not linked here: not named.
        folder.linked = false
        let other = self.store([], folder: folder)
        try await other.send("Hi")
        let first = try await sent("/messages", host: other.api.client.baseURL.host())
        #expect(first?["text"] as? String == "Hi")
        #expect(first?.keys.contains("knowledgeFolder") == false)
        other.unfollow()
    }

    @Test func namesTheTool() {
        let call = AssistantToolCall(id: "t", name: "edit_knowledge_notes", args: ["ops": .array([
            .object(["op": .string("create"), "path": .string("Notes/Car.md")]),
            .object(["op": .string("update"), "documentId": .string("d1"), "append": .string("x")]),
        ])], status: "ok", summary: nil, result: nil, interrupted: false)
        #expect(AssistantToolLabels.label(call) == "Suggesting notes for the knowledge folder")
        #expect(AssistantToolLabels.icon("edit_knowledge_notes") == "note.text")
        #expect(AssistantToolLabels.detail(call) == "2 changes · Car.md")
    }
}

/// Keeps the bodies of the requests (by host and path) and ends every stream at once.
nonisolated final class NotesStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func body(host: String?, path: String) -> Data? {
        lock.withLock { bodies.first { $0.key.hasPrefix("\(host ?? "")|") && $0.key.hasSuffix(path) }?.value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            stream.close()
            data = collected
        }
        if let data, let url = request.url {
            Self.lock.withLock { Self.bodies["\(url.host() ?? "")|\(url.path(percentEncoded: false))"] = data }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("event: end\ndata: {}\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

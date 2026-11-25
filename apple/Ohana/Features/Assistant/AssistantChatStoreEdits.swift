import Foundation

// What an edit the assistant offered does: the notes it writes into the knowledge folder, the
// pages it sends with a message, the suggestions to add and the memories to keep. Part of
// `AssistantChatStore` (AssistantChatStore.swift).

extension AssistantChatStore {
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
            ? current?.items.firstIndex { if case let .notes(found) = $0 { found.id == id } else { false } }
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
        if current?.id == chatID, let items = current?.items, open.index < items.count,
           case .notes = items[open.index] {
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

    // MARK: Pages

    /// The open chat's request for pages that waits for a device to send them.
    func openPages() -> (index: Int, request: AssistantPagesRequest)? {
        guard let index = openWaiting(), case let .pages(request) = current?.items[index] else { return nil }
        return (index, request)
    }

    /// This device has the family's knowledge folder linked: it can send a document's pages.
    var canSendPages: Bool { knowledgeNotes()?.folderID != nil }

    func isSendingPages(_ id: String) -> Bool { pagesSending.contains(id) }

    /// Renders the pages of the open pages request `id` from the knowledge folder here, uploads
    /// each, then answers with the pages sent (or why none could be). While the server can't be
    /// reached nothing is answered: the request keeps waiting, to be sent again.
    func sendPages(_ id: String) async {
        guard let open = openPages(), open.request.id == id, let chatID = current?.id, !chatID.isEmpty,
              !pagesSending.contains(id) else { return }
        pagesSending.insert(id)
        defer { pagesSending.remove(id) }
        var sent: [Int] = []
        var failure: (any Error)?
        if let notes = knowledgeNotes(), case let .linked(root, folderID) = notes.state(),
           sentKnowledgeFolder == nil || sentKnowledgeFolder == folderID {
            do {
                let pages = try await AssistantPagesRender.render(path: open.request.path, pages: open.request.pages,
                                                                  in: root)
                for page in pages {
                    do {
                        let request = api.client.request(
                            .put, api.path("/ai/chats/\(Self.enc(chatID))/pages"),
                            query: ["call": id, "page": String(page.page)], body: page.jpeg, contentType: "image/jpeg"
                        )
                        _ = try await api.client.data(for: request)
                        sent.append(page.page)
                    } catch {
                        failure = error
                        // Gone, or no longer asked for: the others won't go either.
                        if APIError.isUnreachable(error) || (error as? APIError)?.status == 409 { break }
                    }
                }
            } catch {
                failure = error
            }
        } else {
            failure = AssistantPagesError.notLinked
        }
        if sent.isEmpty, let failure, APIError.isUnreachable(failure) || failure is CancellationError {
            if !(failure is CancellationError) { ErrorBanner.shared.show(failure) }
            return
        }
        // Rendering took a while: the item may have moved (a reload), so it's looked up again.
        guard current?.id == chatID, let again = openPages(), again.request.id == id else { return }
        let error = failure.map { $0.localizedDescription }
        answerPages(again, chatID: chatID,
                    answer: sent.isEmpty
                        ? .failed(error ?? AssistantPagesError.noPages.localizedDescription)
                        : .sent(sent),
                    error: sent.isEmpty ? nil : error)
    }

    /// Declines the open pages request `id`: nothing is sent, and the assistant hears so.
    func declinePages(_ id: String) {
        guard let open = openPages(), open.request.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        answerPages(open, chatID: chatID, answer: .declined, error: nil)
    }

    private func answerPages(_ open: (index: Int, request: AssistantPagesRequest), chatID: String,
                             answer: AssistantPagesRequest.Answer, error: String?) {
        sending = true
        if current?.id == chatID, let items = current?.items, open.index < items.count,
           case .pages = items[open.index] {
            var answered = open.request
            answered.answer = answer
            current?.items[open.index] = .pages(answered)
        }
        let here = context()
        let page = current?.page ?? here.page
        Task {
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            var body = AssistantPagesAnswerInput(
                id: open.request.id, page: page, year: here.year, lang: language, today: AssistantDates.day(),
                reminders: reminders, appleCalendar: calendar, knowledgeFolder: knowledgeFolder()
            )
            switch answer {
            case let .sent(pages):
                body.sent = pages
                body.error = error
            case .declined:
                body.declined = true
            case let .failed(message):
                body.error = message
            }
            post(chatID, "pages", body: body)
        }
    }

    /// The options ticked on a question with several to pick.
    func picks(_ question: AssistantQuestion) -> [String] {
        questionPicks[question.id] ?? []
    }

    /// Ticks or unticks `option` of a question with several to pick.
    func togglePick(_ question: AssistantQuestion, _ option: String) {
        var picks = picks(question)
        if let found = picks.firstIndex(of: option) { picks.remove(at: found) } else { picks.append(option) }
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
            ? current?.items.firstIndex { if case let .suggestions(found) = $0 { found.id == id } else { false } }
            : nil
        answerSuggestions((index ?? open.index, open.edit), chatID: chatID,
                          answer: .init(applied: true, results: results))
        return .answered
    }

    /// Adds none of the open suggestions `id`, and the assistant hears so.
    func declineSuggestions(_ id: String) {
        guard let open = openSuggestions(), open.edit.id == id, let chatID = current?.id,
              !chatID.isEmpty else { return }
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

    // MARK: Memories

    /// The memory ops of `edit` the user ticked (at first every one this app can apply).
    func picks(_ edit: AssistantMemoriesEdit) -> Set<Int> {
        memoryPicks[edit.id] ?? edit.initialPicks
    }

    /// Ticks or unticks memory op `index` of `edit`.
    func togglePick(_ edit: AssistantMemoriesEdit, _ index: Int) {
        var picks = picks(edit)
        if picks.contains(index) { picks.remove(index) } else { picks.insert(index) }
        memoryPicks[edit.id] = picks
    }

    /// Op `index`'s text as the card shows it: the user's, else the assistant's.
    func memoryText(_ edit: AssistantMemoriesEdit, _ index: Int) -> String {
        memoryTexts[edit.id]?[index] ?? (index < edit.ops.count ? edit.ops[index].text : "")
    }

    func setMemoryText(_ edit: AssistantMemoriesEdit, _ index: Int, _ text: String) {
        memoryTexts[edit.id, default: [:]][index] = text
    }

    /// Saves the picked ops of the open memories `id` (those that went through before aren't
    /// repeated). When every one went through, answers with each op's result (the others
    /// declined); otherwise the card stays open with the errors, for another Save or Not Now.
    func applyMemories(_ id: String, writer: (any AssistantMemoryWriting)? = nil) async {
        guard let open = openMemories(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        applying = true
        defer { applying = false }
        let picks = picks(open.edit)
        let previous = memoryResults[id] ?? [:]
        let results = await AssistantMemoriesApply.perform(
            open.edit.ops, picks: picks, texts: memoryTexts[id] ?? [:], previous: previous,
            writer: writer ?? FamilyMemoryWriter(api: api)
        )
        if results.indices.contains(where: { results[$0].ok && previous[$0]?.ok != true }) { onChange([.memories]) }
        if results.contains(where: \.failed) {
            memoryResults[id] = Dictionary(uniqueKeysWithValues: results.enumerated().filter { !$0.element.isDeclined }
                .map { ($0.offset, $0.element) })
            return
        }
        // Saving took a while: the item may have moved (a reload), so it's looked up again.
        guard current?.id == chatID, let again = openMemories(), again.edit.id == id else { return }
        sending = true
        answerMemories(again, chatID: chatID, answer: .init(applied: true, results: results))
    }

    /// Saves none of the open memories `id` (but what an earlier Save got through), and the
    /// assistant hears so.
    func declineMemories(_ id: String) {
        guard let open = openMemories(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty else { return }
        sending = true
        answerMemories(open, chatID: chatID, answer: Self.memoriesDeclined(open.edit, tried: memoryResults[id] ?? [:]))
    }

    /// Not Now's answer: all declined, or with what an earlier Save got through (the rest declined).
    static func memoriesDeclined(_ edit: AssistantMemoriesEdit,
                                 tried: [Int: AssistantReminderResult]) -> AssistantMemoriesEdit.Answer {
        guard tried.values.contains(where: \.ok) else { return .init(applied: false, results: nil) }
        return .init(applied: true, results: edit.ops.indices.map {
            tried[$0].flatMap { $0.ok ? $0 : nil } ?? .declined
        })
    }

    private func answerMemories(_ open: (index: Int, edit: AssistantMemoriesEdit), chatID: String,
                                answer: AssistantMemoriesEdit.Answer) {
        if current?.id == chatID, let items = current?.items, open.index < items.count,
           case .memories = items[open.index] {
            var answered = open.edit
            answered.answer = answer
            current?.items[open.index] = .memories(answered)
        }
        memoryPicks[open.edit.id] = nil
        memoryTexts[open.edit.id] = nil
        memoryResults[open.edit.id] = nil
        let here = context()
        let page = current?.page ?? here.page
        Task {
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            post(chatID, "memories", body: Self.remindersAnswer(
                id: open.edit.id, answer: answer, page: page, year: here.year, lang: language,
                today: AssistantDates.day(), reminders: reminders, appleCalendar: calendar,
                knowledgeFolder: knowledgeFolder()
            ))
        }
    }

    /// Sends an answer (POST /ai/chats/{id}/{route}) and follows the turn it goes on with.
    func post(_ chatID: String, _ route: String, body: some Encodable) {
        do {
            start(chatID, request: try jsonRequest(.post, "/ai/chats/\(Self.enc(chatID))/\(route)", body: body))
        } catch {
            sending = false
            ErrorBanner.shared.show(error)
        }
    }

    func jsonRequest(_ method: HTTPMethod, _ sub: String, body: some Encodable) throws -> URLRequest {
        let data = try APIClient.encoder.encode(body)
        var req = api.client.request(method, api.path(sub), body: data)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return req
    }

    /// Sends a message (or an answer) with `request`, then follows the turn.
    func start(_ id: String?, request: URLRequest) {
        sending = true
        activity = .init(activity: .init(kind: "thinking"), at: .now)
        follow(id, first: request)
    }
}

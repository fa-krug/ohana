import Foundation
import Observation

/// Sending a message to the open chat: the item goes in at once, the server runs the turn, and a
/// message while a turn runs waits in its queue (AssistantChatStore).
extension AssistantChatStore {
    // MARK: Sending

    var language: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier
        return preferred?.hasPrefix("de") == true ? "de" : "en"
    }

    /// The id of the knowledge folder linked here, for a request (remembered as the one named).
    func knowledgeFolder() -> String? {
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
        guard var chat = current else { return }
        // A new message instead of an answer: the question (or Reminders, calendar or notes edit,
        // or the suggestions) stays unanswered.
        if let open = openWaiting() {
            switch chat.items[open] {
            case var .question(ask):
                ask.skipped = true
                chat.items[open] = .question(ask)
            case var .reminders(edit):
                edit.skipped = true
                chat.items[open] = .reminders(edit)
            case var .calendar(edit):
                edit.skipped = true
                chat.items[open] = .calendar(edit)
            case var .suggestions(edit):
                edit.skipped = true
                chat.items[open] = .suggestions(edit)
            case var .notes(edit):
                edit.skipped = true
                chat.items[open] = .notes(edit)
            case var .memories(edit):
                edit.skipped = true
                chat.items[open] = .memories(edit)
            case var .pages(request):
                request.skipped = true
                chat.items[open] = .pages(request)
            default:
                break
            }
        }
        chat.items.append(item)
        current = chat
        let path = chat.id.isEmpty ? "/ai/chats" : "/ai/chats/\(Self.enc(chat.id))/messages"
        let request = try jsonRequest(.post, path, body: input)
        start(chat.id.isEmpty ? nil : chat.id, request: request)
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
            let result = try await api.send(.post, "/ai/chats/\(Self.enc(id))/queue", body: input,
                                            as: AssistantQueueResult.self)
            summary(result.chat)
            guard current?.id == id else { return }
            // Worked out before the assignment: reading `current` inside `current?.queued = …`
            // overlaps its modification (a fatal exclusivity conflict).
            let queued = Self.queued(result.chat, before: current?.queued.filter { $0.id != shown.id } ?? [])
            current?.queued = queued
            current?.status = result.chat.status
            // The turn was over by then: the message started the next one.
            if result.chat.isRunning, following == nil { follow(id) }
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
            let result = try await api.send(.post, "/ai/chats/\(Self.enc(id))/unqueue", body: Body(id: entry),
                                            as: AssistantQueueResult.self)
            if current?.id == id {
                let queued = Self.queued(result.chat, before: current?.queued ?? [])
                current?.queued = queued
            }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// The position of the open chat's question, Reminders, calendar or notes edit or suggestions
    /// that wait for the user (the last of them, as on the server: one waits at a time).
    func openWaiting() -> Int? { pendingWaiting() }

    /// See `openWaiting`; `busy` rests on it (an answer sent marks the item answered first).
    func pendingWaiting() -> Int? {
        guard let items = current?.items, savedCopy == nil,
              let index = items.lastIndex(where: \.canWait),
              !items[(index + 1)...].contains(where: \.isUser)
        else { return nil }
        switch items[index] {
        case let .question(ask) where ask.answer == nil && !ask.skipped: return index
        case let .reminders(edit) where edit.answer == nil && !edit.skipped: return index
        case let .calendar(edit) where edit.answer == nil && !edit.skipped: return index
        case let .suggestions(edit) where edit.answer == nil && !edit.skipped: return index
        case let .notes(edit) where edit.answer == nil && !edit.skipped: return index
        case let .memories(edit) where edit.answer == nil && !edit.skipped: return index
        case let .pages(request) where request.answer == nil && !request.skipped: return index
        default: return nil
        }
    }

    /// The position of the item that waits for the user (the chat works it out once for its items).
    var waitingIndex: Int? { openWaiting() }

    /// The open chat's question that waits for an answer, with its position.
    func openQuestion() -> (index: Int, question: AssistantQuestion)? {
        guard let index = openWaiting(), case let .question(ask) = current?.items[index] else { return nil }
        return (index, ask)
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

    /// The open chat's memory changes that wait for the user to save (some of) them or none.
    func openMemories() -> (index: Int, edit: AssistantMemoriesEdit)? {
        guard let index = openWaiting(), case let .memories(edit) = current?.items[index] else { return nil }
        return (index, edit)
    }

    /// Answers the open question of the current chat, and the assistant goes on.
    func answer(selected: [String], text: String) {
        let own = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chat = current, !chat.id.isEmpty, let open = openQuestion(), !busy,
              !selected.isEmpty || !own.isEmpty else { return }
        let (index, ask) = open
        var answered = ask
        answered.answer = .init(selected: selected, text: own.isEmpty ? nil : own)
        current?.items[index] = .question(answered)
        questionPicks[ask.id] = nil
        // Nothing else is sent while the Reminders and calendars are read.
        sending = true
        Task {
            let reminders = await remindersContext()
            let calendar = await calendarContext()
            let here = context()
            let body = AssistantAnswerInput(
                id: ask.id, selected: selected, text: own.isEmpty ? nil : own, page: chat.page ?? here.page,
                year: here.year, lang: language, today: AssistantDates.day(), reminders: reminders,
                appleCalendar: calendar, knowledgeFolder: knowledgeFolder()
            )
            post(chat.id, "answer", body: body)
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
        guard let open = openRemindersEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty
        else { return }
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
        guard let open = openCalendarEdit(), open.edit.id == id, let chatID = current?.id, !chatID.isEmpty
        else { return }
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
}

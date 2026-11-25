import Foundation

// The turn the chat shows: which items belong to it, what it is doing right now and how long it
// has been at it. Part of `AssistantChatStore` (AssistantChatStore.swift).

extension AssistantChatStore {
    // MARK: Following

    func unfollow() {
        following?.cancel()
        following = nil
        flushDeltas()
    }

    /// A view shows the store (`onAppear`).
    func addViewer() { viewers += 1 }

    /// A view showing the store went away; the last one stops following (the turn goes on on
    /// the server).
    func removeViewer() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { unfollow() }
    }

    /// Each time the assistant shows. The first time in a session it opens on the latest chat if
    /// that still runs or was active in the last `within` (the conversation goes on where it
    /// was), else on a new chat: a long chat isn't laid out only to be left. Later, a chat opened
    /// that way which the user hasn't left meanwhile gives way to a new chat once it has gone
    /// quiet.
    func restoreLatest(within: TimeInterval = reopenWithin, now: Date = .now, follow: Bool = true) async {
        guard !restoredLatest else {
            if let restored, restored.id == currentID, restored.picks == picks, !busy,
               let chat = chats.first(where: { $0.id == restored.id }), !Self.isRecent(chat, within: within, now: now) {
                self.restored = nil
                newChat()
            }
            return
        }
        restoredLatest = true
        let before = picks
        // The list on the device first: the latest chat opens without waiting for the server,
        // which is only asked when the copy has none to open.
        await loadSavedChats()
        if let latest = latest(within: within, now: now, picks: before) {
            await reopen(latest, follow: follow)
            return
        }
        guard !chatsLoaded else { return }
        await loadChats()
        if let latest = latest(within: within, now: now, picks: before) { await reopen(latest, follow: follow) }
    }

    private func reopen(_ id: String, follow: Bool) async {
        await open(id, follow: follow)
        if currentID == id { restored = (id, picks) }
    }

    /// The latest chat, if it is recent (`isRecent`) and the user hasn't picked a chat or asked
    /// for a new one meanwhile.
    func latest(within: TimeInterval, now: Date, picks before: Int) -> String? {
        guard picks == before, current == nil, currentID == nil, let latest = chats.first,
              Self.isRecent(latest, within: within, now: now)
        else { return nil }
        return latest.id
    }

    /// The chat still runs or was active in the last `within`.
    static func isRecent(_ chat: AssistantChatSummary, within: TimeInterval, now: Date) -> Bool {
        chat.isRunning || (chat.updatedDate.map { now.timeIntervalSince($0) < within } ?? false)
    }

    // MARK: Turn

    /// Works out `turn` (and `turnRunning`) again after what it rests on changed; assigned only
    /// when different, so the bar and the toggle aren't drawn again with each piece of text.
    func updateTurn() {
        let running = turnIsRunning
        let next = running ? AssistantTurn(running: true, status: turnStatus(), title: current?.title ?? "") : .idle
        if turn != next { turn = next }
        if turnRunning != running { turnRunning = running }
    }

    /// A turn runs in the open chat as far as this device follows it: the chat's copy may say
    /// "running" from before (a copy on the device, a stream that broke off), which isn't trusted.
    private var turnIsRunning: Bool {
        if sending { return true }
        guard following != nil, let id = currentID else { return false }
        return chats.first { $0.id == id }?.isRunning == true
    }

    /// As the chat's activity line says it, shorter.
    private func turnStatus() -> String {
        switch activity?.activity.kind {
        case "writing":
            return String(localized: "Writing…")
        case "tool":
            // The last tool call that runs: from the end, where it is.
            for item in (current?.items ?? []).reversed() {
                if case let .tool(run) = item, run.status == "running" { return AssistantToolLabels.label(run) + "…" }
            }
            return String(localized: "Thinking…")
        default:
            return String(localized: "Thinking…")
        }
    }

    /// Starts a new chat unless the open one is still empty (no duplicates of empty chats).
    func newChatUnlessEmpty() {
        restoredLatest = true
        if currentID != nil || !isEmptyChat { newChat() } else { picks += 1 }
    }

    /// The open chat has nothing in it yet.
    var isEmptyChat: Bool { current?.items.isEmpty ?? true }

    /// Follows a chat until no turn runs in it: with `first` (a message being sent), then with
    /// follow requests from what this device has. The server runs the turn either way, so a
    /// stream that breaks off is simply asked for again.
    func follow(_ id: String?, first: URLRequest? = nil) {
        unfollow()
        followID += 1
        let token = followID
        following = Task { [weak self] in
            await self?.followLoop(id, first: first, token: token)
        }
    }

    private func followLoop(_ id: String?, first: URLRequest?, token: Int) async {
        var chatID = id
        var request = first
        var failures = 0
        var finished = false
        while !Task.isCancelled {
            var ended = false
            var heard = false
            do {
                let req: URLRequest
                if let firstRequest = request {
                    req = firstRequest
                    request = nil
                } else if let chatID {
                    var streamRequest = api.client.request(.get, api.path("/ai/chats/\(Self.enc(chatID))/events"),
                                               query: ["since": String(current?.id == chatID ? current?.rev ?? 0 : 0)])
                    streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req = streamRequest
                } else {
                    break
                }
                // Read and decoded off the main thread; only the events come here.
                for try await event in AssistantEventStream.events(try await api.client.lines(req)) {
                    if Task.isCancelled { break }
                    heard = true
                    guard let event else { continue }
                    if case let .chat(chatSummary) = event, chatID == nil { chatID = chatSummary.id }
                    if case .end = event { ended = true }
                    if let chatID { receive(chatID, event) }
                }
                flushDeltas()
            } catch {
                flushDeltas()
                if Task.isCancelled || error is CancellationError { break }
                if first != nil, !heard, sending {
                    // The message didn't get through: the chat says so (it stays visible).
                    sending = false
                    failed(error.localizedDescription)
                    if (error as? APIError)?.status == nil { await loadChats() } // maybe it did
                    break
                }
                // Refused (the chat is gone, or no longer ours): following won't help.
                if let status = (error as? APIError)?.status, status < 500, status != 429 { break }
                failures += 1
            }
            sending = false
            finished = ended
            if Task.isCancelled || ended { break }
            // Reconnect at once after a good stream, else a little later each time.
            if heard {
                failures = 0
            } else {
                try? await Task.sleep(for: .milliseconds(min(10_000, 1000 << min(failures, 4))))
            }
        }
        if followID == token {
            following = nil
            sending = false
            if current?.id == chatID, current?.isRunning != true { activity = nil }
        }
        // The copy on the device is the state the chat was opened in: after a turn, the new one.
        if finished, let chatID, api.client.cache != nil {
            _ = try? await chatState(chatID).fetch()
        }
    }

    func failed(_ text: String) {
        if current != nil {
            current?.items.append(.error(text: text))
            if current?.id.isEmpty == true { current?.status = "idle" }
        }
        activity = nil
    }

    /// Keeps a chat's summary in the list (the latest first).
    func summary(_ chatSummary: AssistantChatSummary) {
        var list = chats.filter { $0.id != chatSummary.id }
        list.append(chatSummary)
        list.sort { $0.updatedAt > $1.updatedAt }
        // Unchanged (the stream repeats the chat with every step): the list isn't drawn again.
        if list != chats { chats = list }
    }

    /// The messages that wait as the server says, then the ones still on their way to it.
    static func queued(_ chat: AssistantChatSummary, before: [AssistantQueued]) -> [AssistantQueued] {
        (chat.queued ?? []) + before.filter(\.isLocal)
    }

    /// Marks an item as seen; returns the areas it changed if it is new to this device.
    @discardableResult
    func markSeen(_ item: AssistantItem) -> [DataArea] {
        switch item {
        case let .change(change):
            guard seen.insert("change:" + change.id).inserted else { return [] }
            return AssistantChangeAreas.areas(change: change.change, undo: change.undo)
        case let .tool(tool) where tool.status == "ok":
            guard seen.insert("tool:" + tool.id).inserted else { return [] }
            return AssistantChangeAreas.areas(tool: tool.name)
        default:
            return []
        }
    }

    /// An event of the stream being followed: text is gathered and shown every `deltaInterval`
    /// (`flushDeltas`), anything else after the text before it.
    private func receive(_ id: String, _ event: AssistantChatEvent) {
        guard case let .delta(seq, text) = event else {
            flushDeltas()
            apply(id, event)
            return
        }
        if let last = pendingDeltas.last, last.chat == id, last.seq == seq {
            pendingDeltas[pendingDeltas.count - 1].text += text
        } else {
            pendingDeltas.append((id, seq, text))
        }
        guard deltaFlush == nil else { return }
        deltaFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.deltaInterval)
            guard !Task.isCancelled else { return }
            self?.flushDeltas()
        }
    }

    /// Shows the text gathered from the stream (all of it in one change of the chat).
    private func flushDeltas() {
        deltaFlush?.cancel()
        deltaFlush = nil
        guard !pendingDeltas.isEmpty else { return }
        let pending = pendingDeltas
        pendingDeltas = []
        applyDeltas(pending)
    }

    /// Text written into answers of the open chat, as one change.
    private func applyDeltas(_ deltas: [(chat: String, seq: Int, text: String)]) {
        guard var openChat = current else { return }
        var changed = false
        for (chat, seq, text) in deltas where chat == openChat.id {
            guard openChat.items.indices.contains(seq),
                  case let .assistant(before, sources) = openChat.items[seq] else { continue }
            openChat.items[seq] = .assistant(text: before + text, sources: sources)
            changed = true
        }
        guard changed else { return }
        current = openChat
        let now = Date.now
        lastTextAt = now
        // Not with every piece: what reads the activity would be drawn again with each.
        let writing = activity?.activity.kind == "writing"
        let since = now.timeIntervalSince(activity?.at ?? now)
        if writing, since < Self.activityRefresh { return }
        activity = .init(activity: .init(kind: "writing"), at: now)
    }

    /// What a chat's stream says (exposed for tests).
    func apply(_ id: String, _ event: AssistantChatEvent) {
        // A new chat gets its id with the first event.
        if var openChat = current, openChat.id.isEmpty, case .chat = event, currentID == nil {
            openChat.id = id
            current = openChat
            currentID = id
        }
        let isOpen = current?.id == id
        switch event {
        case let .chat(chatSummary): applyChat(chatSummary, isOpen: isOpen)
        case let .items(rev, items): applyItems(rev, items, isOpen: isOpen)
        case let .delta(seq, text): applyDeltas([(id, seq, text)])
        case let .end(deleted): applyEnd(deleted, id: id, isOpen: isOpen)
        case .reconnect:
            break
        }
    }

    /// The chat's own fields from the stream: title, status, usage, page, what's queued.
    private func applyChat(_ chatSummary: AssistantChatSummary, isOpen: Bool) {
        summary(chatSummary)
        guard isOpen, var openChat = current else { return }
        openChat.title = chatSummary.title
        openChat.status = chatSummary.status
        openChat.usage = chatSummary.usage ?? openChat.usage
        openChat.page = chatSummary.page ?? openChat.page
        openChat.queued = Self.queued(chatSummary, before: openChat.queued)
        current = openChat
        // From the server: with the items since the copy's revision, the chat is up to date.
        savedCopy = nil
        guard let reported = chatSummary.activity, chatSummary.isRunning else {
            activity = nil
            return
        }
        if activity?.activity != reported { activity = .init(activity: reported, at: .now) }
    }

    /// The items the stream brings: each into its place, with the areas they changed.
    private func applyItems(_ rev: Int?, _ items: [(seq: Int, item: AssistantItem)], isOpen: Bool) {
        guard isOpen, var openChat = current else { return }
        var changed: [DataArea] = []
        for (seq, item) in items where seq >= 0 {
            while openChat.items.count <= seq { openChat.items.append(.unknown(kind: "")) }
            openChat.items[seq] = item
            changed += markSeen(item)
        }
        if let rev { openChat.rev = max(openChat.rev, rev) }
        current = openChat
        let areas = AssistantChangeAreas.unique(changed)
        if !areas.isEmpty { onChange(areas) }
    }

    /// The stream's end: the chat out of the list when the server deleted it, else idle again.
    private func applyEnd(_ deleted: Bool, id: String, isOpen: Bool) {
        if deleted {
            chats.removeAll { $0.id == id }
            if isOpen { newChat() }
        } else if isOpen {
            current?.status = "idle"
            activity = nil
        }
    }

    /// A tool call's result, as far as the chat keeps it.
    func toolResult(_ id: String) -> String? {
        for item in current?.items ?? [] {
            if case let .tool(run) = item, run.id == id { return run.result }
        }
        return nil
    }
}

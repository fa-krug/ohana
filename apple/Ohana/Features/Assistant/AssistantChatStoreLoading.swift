import Foundation

// What the store reads from the server: the family's assistant settings, the chat list, one
// chat and its pages, and the status of what the assistant is doing. Part of
// `AssistantChatStore` (AssistantChatStore.swift).

extension AssistantChatStore {
    // MARK: Loading

    func loadSettings() async {
        let get = Self.settingsRequest(api)
        if settings == nil {
            // The copy on the device, read and decoded off the main thread.
            let copy = await get.savedOffMain()
            if settings == nil { settings = copy?.value }
        }
        do {
            let fetched = try await get.fetch()
            if settings != fetched { settings = fetched }
            if settingsError != nil { settingsError = nil }
        } catch is CancellationError {
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func setSettings(_ newSettings: AssistantSettings) { settings = newSettings }

    /// The settings' and the chat list's GETs (the prefetch asks the same).
    static func settingsRequest(_ api: FamilyAPI) -> CachedGet<AssistantSettings> {
        api.cached("/ai/settings")
    }

    static func chatsRequest(_ api: FamilyAPI) -> CachedGet<AssistantChatList> {
        api.cached("/ai/chats")
    }

    /// Before the assistant first shows: its settings, the chats and, only when the assistant
    /// will open on it (`restoreLatest`), the latest chat with its answers' Markdown read, so the
    /// panel has them drawn before it slides in (a running turn isn't followed: no one looks yet).
    /// Most of the time it opens on a new chat: then there's nothing heavy to prepare.
    func preload() async {
        // The settings beside the chats and the latest chat: neither waits for the other.
        async let settingsLoaded: Void = loadSettingsIfNeeded()
        // Decided on the list's copy on the device; the server's list after it (the chat list).
        await restoreLatest(follow: false)
        if !chatsLoaded { await loadChats() }
        await settingsLoaded
    }

    private func loadSettingsIfNeeded() async {
        if settings == nil { await loadSettings() }
    }

    func loadChats() async {
        let get = Self.chatsRequest(api)
        await loadSavedChats()
        do {
            let fetched = try await get.fetch().chats
            if chats != fetched { chats = fetched }
            if !chatsLoaded { chatsLoaded = true }
        } catch {
            // Offline or not allowed: the list stays as it is.
        }
    }

    /// The list's copy on the device, read and decoded off the main thread. Only into an empty
    /// list: the server's chats are never replaced by the copy.
    func loadSavedChats() async {
        guard !chatsLoaded, chats.isEmpty else { return }
        let copy = await Self.chatsRequest(api).savedOffMain()
        if !chatsLoaded, chats.isEmpty, let copy { chats = copy.value.chats }
    }

    /// Back in the app (another device may have chatted meanwhile): the list and the open chat
    /// catch up.
    func refresh() async {
        // The list beside the open chat.
        async let listed: Void = loadChats()
        if let id = currentID, savedCopy?.updating == false { await fetch(id, follow: false) }
        if let id = current?.id, !id.isEmpty, following == nil { follow(id) }
        await listed
    }

    /// Tries again to reach the server for the open chat's copy and the list (the connection is
    /// back).
    func retrySaved() async {
        async let listed: Void = loadChats()
        if let id = currentID, savedCopy?.updating == false {
            await fetch(id, follow: true)
        } else if let id = currentID, openError != nil {
            await open(id)
        }
        await listed
    }

    /// Shows a chat as given, marking what it changed so far as seen (previews and tests).
    func show(_ chat: AssistantChat) {
        unfollow()
        for item in chat.items { markSeen(item) }
        currentID = chat.id.isEmpty ? nil : chat.id
        current = chat
        savedCopy = nil
        openError = nil
        session += 1
    }

    func newChat() {
        picks += 1
        unfollow()
        currentID = nil
        current = nil
        savedCopy = nil
        openError = nil
        activity = nil
        session += 1
    }

    /// Opens a chat (a running turn goes on either way); `follow`: its running turn too.
    func open(_ id: String, follow following: Bool = true) async {
        if id == currentID, current != nil {
            // Its copy on the device, the server out of reach before: ask again.
            if savedCopy?.updating == false { await fetch(id, follow: following) }
            return
        }
        picks += 1
        let pick = picks
        unfollow()
        // Asked again for the chat that couldn't load: the same one, still (no new session).
        if id != currentID || openError == nil { session += 1 }
        currentID = id
        current = nil
        savedCopy = nil
        openError = nil
        activity = nil
        // The copy on the device, read and decoded off the main thread (a long chat's items take a
        // while); meanwhile another chat may have been picked, which then loads itself.
        let copy = await chatState(id).savedOffMain()
        guard picks == pick, currentID == id else { return }
        // Its answers' Markdown read off the main thread before it's drawn.
        if let copy {
            await prewarm(copy.value.items)
            guard picks == pick, currentID == id else { return }
        }
        if current == nil, let copy {
            for item in copy.value.items { markSeen(item) }
            var chat = Self.chat(id, copy.value)
            // A turn that ran then has ended or goes on without this device: the server says.
            chat.status = "idle"
            chat.queued = []
            current = chat
            savedCopy = .init(date: copy.date, updating: true)
        }
        await fetch(id, follow: following)
    }

    func chatState(_ id: String) -> CachedGet<AssistantChatState> {
        api.cached("/ai/chats/\(Self.enc(id))")
    }

    static func chat(_ id: String, _ snapshot: AssistantChatState) -> AssistantChat {
        AssistantChat(
            id: id, title: snapshot.chat.title, status: snapshot.chat.status, items: snapshot.items, rev: snapshot.rev,
            usage: snapshot.chat.usage, page: snapshot.chat.page, queued: snapshot.chat.queued ?? []
        )
    }

    /// Asks the server for the open chat. Its answer replaces what's shown unless that changed
    /// meanwhile (a message was sent: the chat's stream brings the rest); the copy on the device
    /// stays while the server can't be reached.
    func fetch(_ id: String, follow following: Bool) async {
        let shown = current
        savedCopy?.updating = true
        do {
            let snapshot = try await chatState(id).fetch()
            guard currentID == id, current == shown else { return }
            // Read off the main thread before it's drawn (what the copy had is read already).
            await prewarm(snapshot.items)
            guard currentID == id, current == shown else { return }
            for item in snapshot.items { markSeen(item) }
            // The same as shown (nothing new since): the chat isn't drawn again.
            let chat = Self.chat(id, snapshot)
            if current != chat { current = chat }
            if savedCopy != nil { savedCopy = nil }
            summary(snapshot.chat)
            if snapshot.chat.isRunning, following { follow(id) }
        } catch {
            tellFetchFailure(id, error)
        }
    }

    /// What a fetch of the open chat that failed leaves behind: the copy on the device for a
    /// while, the chat gone when the server no longer has it, and a message when nothing is left.
    private func tellFetchFailure(_ id: String, _ error: any Error) {
        guard currentID == id, !(error is CancellationError) else { return }
        if savedCopy != nil, APIError.isTemporary(error) {
            // The copy stays: silently, unless the server answered with an error.
            savedCopy?.updating = false
            ErrorBanner.shared.showUnlessUnreachable(error)
            return
        }
        if (error as? APIError)?.status == 404 {
            chats.removeAll { $0.id == id }
            currentID = nil
        }
        if savedCopy != nil {
            current = nil
            savedCopy = nil
        }
        // Nothing to show: the chat says so (and tries again), not a placeholder for good.
        if currentID == id, current == nil {
            openError = error.localizedDescription
            if APIError.isUnreachable(error) { return }
        }
        ErrorBanner.shared.show(error)
    }

    func remove(_ id: String) async {
        do {
            try await api.perform(.delete, "/ai/chats/\(Self.enc(id))")
        } catch {
            if (error as? APIError)?.status != 404 {
                ErrorBanner.shared.show(error)
                return
            }
        }
        chats.removeAll { $0.id == id }
        if currentID == id { newChat() }
    }

    /// Stops the open chat's turn; it ends with what it did so far.
    func stop() async {
        guard let id = current?.id, !id.isEmpty else { return }
        do {
            try await api.perform(.post, "/ai/chats/\(Self.enc(id))/stop", body: Empty())
            if following == nil { follow(id) }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    /// Moves the open chat to the page the user looks at: its next turns are about that page.
    func moveHere() async {
        guard var openChat = current, let before = openChat.page, !openChat.id.isEmpty else { return }
        let page = context().page
        openChat.page = page
        current = openChat
        do {
            struct Body: Encodable { let page: String }
            let reply = try await api.send(.post, "/ai/chats/\(Self.enc(openChat.id))/page", body: Body(page: page),
                                       as: AssistantQueueResult.self)
            summary(reply.chat)
        } catch {
            if current?.id == openChat.id { current?.page = before }
            ErrorBanner.shared.show(error)
        }
    }
}

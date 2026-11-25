import SwiftUI

// The chat's messages: the window of items it shows, how it follows the last turn, the menu of
// one item and picking text from it. Part of `AssistantChatView` (AssistantChatView.swift).

extension AssistantChatView {
    // MARK: Content

    @ViewBuilder var content: some View {
        if let settings = store.settings, !settings.configured {
            AssistantSetupView(canEdit: family.canEdit) { showSettings = true }
        } else if store.settings == nil, let error = store.settingsError, store.current == nil, store.currentID == nil {
            // Only with nothing else to show: a chat (read from the device) shows, the composer
            // offers to try again.
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("Try again") { Task { await store.loadSettings() } }
                    .buttonStyle(.glassProminent)
            }
        } else {
            // At once, before the settings are known: the chat shows and the composer waits.
            conversation
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .overlay { if dropping { dropHint } }
                .onDrop(of: AssistantAttachments.dropTypes, isTargeted: $dropping) { providers in
                    guard store.ready else { return false }
                    drop(providers)
                    return true
                }
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 20)
            .strokeBorder(ModuleTint.assistant, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .overlay {
                Label("Drop files to attach", systemImage: "paperclip")
                    .font(.headline)
                    .foregroundStyle(ModuleTint.assistant)
            }
            .padding(8)
            .allowsHitTesting(false)
    }

    private var visibleItems: [(offset: Int, item: AssistantItem)] {
        (store.current?.items ?? []).enumerated().filter { $0.element.isVisible }.map { ($0.offset, $0.element) }
    }

    /// The chat being opened (no copy of it here yet): a placeholder rather than an empty chat.
    var opening: Bool { store.currentID != nil && store.current == nil }

    /// The conversation, the placeholder while a chat opens, or why it couldn't. Another chat
    /// cross-fades in (the two overlap at the bottom, where the user reads).
    private var conversation: some View {
        ScrollView {
            ZStack(alignment: .bottom) {
                if opening {
                    if let error = store.openError {
                        openFailed(error)
                            .transition(.opacity)
                    } else {
                        AssistantChatSkeleton()
                            .transition(.opacity)
                    }
                } else {
                    chatItems
                        .id(store.session)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: FadeKey(session: store.session, opening: opening, failed: store.openError != nil))
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, AssistantScrollFollow.padding)
            // Exactly the width the scroll view offers its content, whatever the chat holds: nothing
            // in it can make it pan sideways. Never its measured frame (a Mac's scroll bar takes
            // from that room: the chat at the frame's width made the scroll view wider by the bar,
            // and so on without end) nor `containerRelativeFrame` (the window's, in the panel).
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollPosition($scroll)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: AssistantScrollFollow.Metrics.self) { geometry in
            AssistantScrollFollow.Metrics(geometry)
        } action: { old, new in
            scrolled(from: old, to: new)
        }
        .onChange(of: store.session) {
            sentPending = false
            jumpToEnd()
        }
        .onChange(of: TurnKey(session: store.session, start: lastTurnStart)) { old, new in
            if AssistantScrollFollow.scrollsToTurn(from: old.start, to: new.start, sameChat: old.session == new.session,
                                                   sent: sentPending, atEnd: atEnd) {
                // To the end, not to the message by its id (not laid out yet at this point): the
                // last turn is as tall as the chat's visible part, so the message then stands at
                // the top (`AssistantTurnLayout`).
                turnScrolling = true
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { scroll.scrollTo(edge: .bottom) }
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    turnScrolling = false
                }
            }
            if new.start != old.start { sentPending = false }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atEnd { jumpToLatest }
        }
        .reloadsWhenReconnected(stale: store.savedCopy?.updating == false || store.openError != nil, store.retrySaved)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: atEnd)
        #if os(iOS)
        .sheet(item: $selecting) { AssistantSelectTextSheet(text: $0.text) }
        #endif
    }

    /// The scroll view moved or changed size: is the end in view, how tall is the last turn, and
    /// (the keyboard came up, the window changed, the answer grew past the bottom) back to the end
    /// it showed. An answer within the last turn's room doesn't move the chat.
    func scrolled(from old: AssistantScrollFollow.Metrics, to new: AssistantScrollFollow.Metrics) {
        let height = AssistantScrollFollow.turnHeight(visible: new.visibleHeight)
        // The first measurement gives the last turn its room: still at the end it opened at.
        let measured = turnHeight == 0 && height > 0
        if height != turnHeight { turnHeight = height }
        if new.isAtBottom != atEnd { atEnd = new.isAtBottom }
        let pin = AssistantScrollFollow.pin(pending: pinning, from: old, to: new,
                                            scrolling: AssistantScrollFollow.userScrolls(scrollPhase),
                                            follows: !sentPending && !turnScrolling)
        if pin.pending != pinning { pinning = pin.pending }
        if pin.scroll || measured { scrollToEndSoon() }
    }

    /// To the end once this update is through: the keyboard shrinks the chat before its insets
    /// and the last turn follow, and an end worked out in between lies past the real one (the
    /// chat would spring back from there).
    func scrollToEndSoon() {
        guard !endQueued else { return }
        endQueued = true
        Task { @MainActor in
            endQueued = false
            jumpToEnd()
        }
    }

    /// To the end at once, never animated by the change that asked for it (a chat opening
    /// cross-fades).
    private func jumpToEnd() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scroll.scrollTo(edge: .bottom) }
    }

    /// The position of the user's last message: the last turn starts there.
    private var lastTurnStart: Int? {
        guard let items = store.current?.items else { return nil }
        return items.lastIndex { $0.isUser }
    }

    /// The chat's items, from the window's start on (`AssistantItemWindow`); a new chat welcomes.
    /// Tool calls one after the other are one row (`AssistantItemGroups`); the last turn is at
    /// least as tall as the chat's visible part (`AssistantTurnLayout`). New items come in
    /// animated (counted, not on every piece of a streaming answer), from the moment the chat has
    /// opened on.
    private var chatItems: some View {
        let all = visibleItems
        let positions = all.map(\.offset)
        let key = WindowKey(session: store.session, loaded: store.current != nil)
        let start = windowKey == key ? windowStart : AssistantItemWindow.start(positions)
        let hidden = AssistantItemWindow.hidden(positions, start: start)
        let shown = Array(all.dropFirst(hidden))
        let entries = AssistantItemGroups.make(shown)
        let turnStart = all.last { $0.item.isUser }?.offset
        // Worked out once here for every item (each card asking the store would draw every
        // card again with each piece of a streaming answer).
        let waiting = store.waitingIndex
        let busy = store.busy
        let saved = store.savedCopy != nil
        let queued = store.current?.queued ?? []
        let familyID = family.family.id
        let animates = !reduceMotion && settledSession == store.session
        return AssistantTurnLayout(turnHeight: turnHeight) {
            if store.current?.items.isEmpty ?? true {
                AssistantWelcome()
                    .transition(.opacity)
            }
            if hidden > 0 {
                Button {
                    showEarlier(positions, start: start, keeping: all[hidden].offset)
                } label: {
                    Label("Show earlier messages", systemImage: "arrow.up")
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            }
            ForEach(entries) { entry in
                Group {
                    if entry.isTools {
                        AssistantToolGroupRow(tools: shown[entry.range].compactMap(\.item.tool), familyID: familyID,
                                              open: open)
                            .equatable()
                    } else {
                        let item = shown[entry.range.lowerBound].item
                        AssistantItemView(item: item, store: store, saved: saved, waiting: entry.id == waiting,
                                          busy: busy, open: open)
                            .equatable()
                    }
                }
                // The whole list: an answer's start may lie before the window.
                .contextMenu { itemMenu(items: all, index: hidden + entry.range.lowerBound, group: entry.range.count) }
                .transition(.assistantTurnItem)
                .assistantTurnStart(entry.id == turnStart)
            }
            if busy {
                AssistantActivityLine(store: store)
                    .transition(.opacity)
            }
            ForEach(queued) { entry in
                AssistantQueuedRow(entry: entry, store: store)
                    .transition(.assistantTurnItem)
            }
        }
        .scrollTargetLayout()
        .animation(animates ? .easeOut(duration: 0.2) : nil,
                   value: ItemCounts(items: store.current?.items.count ?? 0, queued: queued.count, busy: busy))
    }

    /// A chat came on screen (another one, or the one being opened got its items): its window
    /// starts at its last items, and what comes from now on animates in. A new chat animates from
    /// its first message on.
    func startWindow(_ key: WindowKey) {
        windowStart = AssistantItemWindow.start(visibleItems.map(\.offset))
        windowKey = key
        if key.loaded || store.currentID == nil { settledSession = key.session }
        // Opened at its end, also once the items of a chat being opened are there.
        jumpToEnd()
    }

    /// Draws more of the earlier items, keeping the one at the top where it was.
    private func showEarlier(_ positions: [Int], start: Int, keeping first: Int) {
        windowStart = AssistantItemWindow.earlier(positions, start: start)
        windowKey = WindowKey(session: store.session, loaded: store.current != nil)
        scroll.scrollTo(id: first, anchor: .top)
    }

    private func openFailed(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t open the chat", systemImage: "exclamationmark.triangle")
        } description: {
            Text(verbatim: error)
        } actions: {
            Button("Try again") {
                if let id = store.currentID { Task { await store.open(id) } }
            }
            .buttonStyle(.glassProminent)
            .tint(ModuleTint.assistant)
        }
        .frame(minHeight: 280)
    }

    /// Floats over the chat while the user reads further up.
    private var jumpToLatest: some View {
        Button {
            scrollToLatest()
        } label: {
            Label("Jump to latest", systemImage: "arrow.down")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(Text("Jump to latest"))
        .padding(16)
        .transition(.opacity)
    }

    /// Back to the end of the chat (animated unless Reduce Motion is on).
    private func scrollToLatest() {
        withAnimation(reduceMotion ? nil : .smooth) { scroll.scrollTo(edge: .bottom) }
    }

    /// Copy: the message, or a whole answer (everything since the user's last message) with the
    /// tool results; on iOS the message's text to select. `group`: how many tool calls the row
    /// shows from `index` on.
    @ViewBuilder private func itemMenu(items: [(offset: Int, item: AssistantItem)], index: Int,
                                       group: Int = 1) -> some View {
        let item = items[index].item
        if case let .assistant(text, sources) = item {
            let plain = AssistantSourceMarkers.transcript(text, sources: sources)
            Button("Copy", systemImage: "doc.on.doc") { AssistantTranscript.copy(plain) }
            selectTextButton(plain)
        }
        if case let .user(text, _) = item, !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { AssistantTranscript.copy(text) }
            selectTextButton(text)
        }
        if !item.isUser {
            Button("Copy the answer, with all tool results", systemImage: "text.document") {
                var start = index
                while start > 0, !items[start - 1].item.isUser { start -= 1 }
                var end = index
                while end + 1 < items.count, !items[end + 1].item.isUser { end += 1 }
                copy(items[start...end].map(\.item))
            }
        }
        if group == 1, case let .tool(tool) = item,
           let route = AssistantToolLinks.route(tool, familyID: family.family.id) {
            Button("Show", systemImage: "arrow.up.forward.square") { open(route) }
        }
    }

    /// iOS: selecting text inside the chat would make every message costlier to lay out, so a
    /// message's text is selected in a sheet. The Mac selects in place.
    @ViewBuilder private func selectTextButton(_ text: String) -> some View {
        #if os(iOS)
        Button("Select Text", systemImage: "selection.pin.in.out") {
            selecting = AssistantSelectableText(text: text)
        }
        #endif
    }

    /// The chat `windowStart` was worked out for: another chat, or the one being opened once its
    /// items are there.
    struct WindowKey: Equatable {
        var session: Int
        var loaded: Bool
    }

    /// What cross-fades the conversation: another chat, its placeholder, why it couldn't open.
    private struct FadeKey: Equatable {
        var session: Int
        var opening: Bool
        var failed: Bool
    }

    /// Where the last turn starts (`lastTurnStart`), in which chat.
    private struct TurnKey: Equatable {
        var session: Int
        var start: Int?
    }

    /// What animates the chat's items: one more (or fewer), a turn starting or ending.
    private struct ItemCounts: Equatable {
        var items: Int
        var queued: Int
        var busy: Bool
    }
}

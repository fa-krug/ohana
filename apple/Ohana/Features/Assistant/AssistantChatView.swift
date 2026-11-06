import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where the chat is shown: the panel over a module (the shell's floating panel, a sheet on
/// iPhone), or the assistant's own page.
enum AssistantChatMode {
    case panel, page
}

/// The open chat (web: chat-panel.tsx `ChatView`): its messages (Markdown), tool activity with
/// links to what the tools touched, changes with undo, questions to answer, messages waiting for
/// the answer, attachments (picked, dropped or pasted), dictation, how full the model's context
/// is. The panel and the page show it over the same `AssistantChatStore`, so both show the same
/// chat. Put it into a `NavigationStack` (its toolbar and the pushed chat list need one).
struct AssistantChatView: View {
    @Environment(FamilyContext.self) private var family
    /// The sheet's dismiss action (iPhone), kept by `AssistantDismissReader`, not read here: on
    /// the iPad's page `\.dismiss` changes with every update, and read here each change drew the
    /// whole chat again, whose toolbar changed it again (a loop at full CPU).
    @State private var dismissBox = AssistantDismissBox()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: AssistantChatStore
    let mode: AssistantChatMode
    /// The chat list is a column beside the chat (the page when there is room): no history
    /// button then.
    var listBeside = false
    /// Takes the family's `ask` requests (only while this view is the one on screen).
    var takesRequests = true
    /// The page the user looks at (web: `pageOf`; the assistant's page counts as the overview).
    /// Given by the panel, which reads the shell: read here, the page's own menus (focused values
    /// it sets) would change what it reads and draw it again, endlessly.
    var here = "overview"
    /// On screen. The panel stays in the shell while it is closed (built once, it opens at
    /// once); closed, it has no toolbar, takes no requests, doesn't follow the chat (someone
    /// following counts as someone looking) and leaves ⌘V alone.
    var visible = true

    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var attachments: [AssistantPendingAttachment] = []
    @State private var preparing = 0
    @State private var showChats = false
    @State private var showSettings = false
    /// "Copy Prompt for AI Agent": the request runs (taps meanwhile do nothing), then the note.
    @State private var copyingAgentPrompt = false
    @State private var agentPromptCopied = false
    @State private var importing = false
    @State private var dropping = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var scanningLetter = false
    @State private var dictation = AssistantDictation()
    @FocusState private var composerFocused: Bool
    @State private var scroll = ScrollPosition(edge: .bottom)
    /// The end of the chat is in view; else "Jump to latest" floats over it. Sending scrolls the
    /// message to the top, the answer grows below it; past the bottom the chat follows it while the
    /// end is in view.
    @State private var atEnd = true
    @State private var scrollPhase: ScrollPhase = .idle
    /// How tall the last turn is at least (the visible height of the chat, `AssistantTurnLayout`).
    @State private var turnHeight: CGFloat = 0
    /// How wide the scroll view is (the chat is laid out to it).
    @State private var chatWidth: CGFloat = 0
    /// The visible height changed with the end in view: back to the end until it is there.
    @State private var pinning = false
    /// The user sent a message: it scrolls to the top once it is in the chat.
    @State private var sentPending = false
    /// The sent message is on its way to the top (animated): the chat growing doesn't jump meanwhile.
    @State private var turnScrolling = false
    /// A scroll to the end waits for the update to be through (`scrollToEndSoon`).
    @State private var endQueued = false
    /// iOS: the message whose text the "Select Text" sheet shows.
    @State private var selecting: AssistantSelectableText?
    /// Where the window of drawn items starts (`AssistantItemWindow`), worked out for the chat
    /// `windowKey` names.
    @State private var windowStart = 0
    @State private var windowKey: WindowKey?
    /// Items animate in from this chat (`AssistantChatStore.session`) on: not the ones it opened with.
    @State private var settledSession: Int?
    #if os(macOS)
    @State private var pasteMonitor: Any?
    #endif


    /// The panel on iPhone is a sheet: opening a place in another module closes it.
    private var isSheet: Bool {
        #if os(iOS)
        mode == .panel && sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AssistantDismissReader(box: dismissBox) }
            // A bar, not an inset: the chat scrolling under it fades out behind it (the scroll
            // edge effect), instead of running through the title and buttons.
            .safeAreaBar(edge: .top, spacing: 0) { if headerInPanel { panelHeader } }
            .navigationTitle(Text(verbatim: title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // The floating panel's header is its own.
            .toolbar(headerInPanel ? .hidden : .automatic, for: .navigationBar)
            #endif
            .toolbar { if visible && !headerInPanel { toolbar } }
            .navigationDestination(isPresented: $showChats) {
                AssistantChatListView(store: store, inPanel: headerInPanel) {
                    showChats = false
                } done: {
                    showChats = false
                    composerFocused = true
                }
            }
            .background { OhanaBackground(tint: ModuleTint.assistant) }
            .environment(\.openURL, OpenURLAction { url in openLink(url) })
            .task(id: family.revision(.settings)) { await store.loadSettings() }
            .task(id: visible) {
                guard visible else { return }
                await store.restoreLatest()
                // After the panel has slid in: what the refresh changes would be drawn while it slides.
                if mode == .panel { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled else { return }
                await store.refresh()
            }
            .onAppear { if visible { cameOnScreen() } }
            .onDisappear { if visible { wentOffScreen() } }
            .onChange(of: visible) {
                if visible { cameOnScreen() } else { wentOffScreen() }
                takeRequest()
            }
            .onChange(of: here, initial: true) { store.page = here }
            .onChange(of: WindowKey(session: store.session, loaded: store.current != nil), initial: true) { _, key in
                startWindow(key)
            }
            .onChange(of: family.assistantRequest?.id, initial: true) { takeRequest() }
            .onChange(of: takesRequests) { takeRequest() }
            .onChange(of: scenePhase) {
                if scenePhase == .active, visible { Task { await store.refresh() } } else if scenePhase == .background { store.unfollow() }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await store.loadSettings() } }) {
                NavigationStack {
                    AssistantSettingsView(inSheet: true)
                }
                .environment(family)
                .errorBanner()
                .frame(minWidth: 420, minHeight: 520)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: AssistantAttachments.contentTypes,
                          allowsMultipleSelection: true) { result in
                if case let .success(urls) = result { attach(urls) }
                else if case let .failure(error) = result { ErrorBanner.shared.show(error) }
            }
            .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: AssistantAttachments.maxCount,
                          matching: .images)
            .onChange(of: photos) {
                let items = photos
                photos = []
                attach(items)
            }
            .alert("Copied", isPresented: $agentPromptCopied) {} message: {
                Text("The prompt’s access works for one hour.")
            }
            .modifier(AssistantPageCommands(enabled: mode == .page, menu: moduleMenu) { newChat() })
    }

    /// The page's menu (the Mac's menu bar, the iPad's ⌘-hold list).
    private var moduleMenu: ModuleMenu {
        ModuleMenu(title: "Assistant") {
            Button("Stop", systemImage: "stop.fill") { Task { await store.stop() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!store.busy)
            Button("Copy the chat, with all tool results", systemImage: "doc.on.doc") {
                copy(store.current?.items ?? [])
            }
            .disabled(store.current?.items.isEmpty ?? true)
            if family.canEdit {
                Divider()
                Button("Assistant settings…", systemImage: "gearshape") { showSettings = true }
            }
        }
    }

    private func cameOnScreen() {
        store.addViewer()
        connect()
        focusComposer()
        #if os(macOS)
        installPasteMonitor()
        #endif
    }

    private func wentOffScreen() {
        store.removeViewer()
        #if os(iOS)
        dictation.stop()
        #endif
        #if os(macOS)
        removePasteMonitor()
        #endif
    }

    /// The store tells this family's screens what changed, and writes notes into its knowledge
    /// folder.
    private func connect() {
        let family = family
        store.onChange = { areas in family.didChange(areas) }
        store.knowledgeNotes = { [weak family] in family?.assistantNotes }
    }

    private func focusComposer() {
        Task {
            // After the panel (or the sheet) is in place, else the focus doesn't stick.
            try? await Task.sleep(for: .milliseconds(150))
            if store.ready { composerFocused = true }
        }
    }

    // MARK: Requests

    /// `family.ask(…)`: a new chat if asked (an empty one is reused), the prompt in the composer
    /// and the attachments with it, sent if asked, and the composer focused.
    private func takeRequest() {
        guard takesRequests, visible, family.assistantRequest != nil, let request = family.takeAssistantRequest() else { return }
        showChats = false
        if request.newChat {
            store.newChatUnlessEmpty()
            attachments = []
        }
        attachments.append(contentsOf: request.attachments)
        let prompt = request.prompt ?? ""
        if !prompt.isEmpty { text = prompt }
        if request.send, !prompt.isEmpty || !request.attachments.isEmpty {
            Task {
                // The settings first: sending needs to know the assistant is set up.
                if store.settings == nil { await store.loadSettings() }
                send()
            }
        }
        focusComposer()
    }

    // MARK: Links

    /// Opens a place of the app: the panel on iPhone gets out of the way.
    private func open(_ route: AppRoute) {
        family.open(route)
        if isSheet { dismissBox.action?() }
    }

    /// Links in answers: the app's own pages (`/f/{id}/…`) open in the app, web links in the
    /// browser.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == nil, let (familyID, route) = AppRoute.parse(url: url), familyID == family.family.id {
            open(route)
            return .handled
        }
        return .systemAction
    }

    // MARK: Header

    /// The same buttons everywhere, in the same order: Chats (the history), the chat's title, New
    /// chat and More. Beside a module they're the panel's own header; in the iPhone's sheet and on
    /// the page they're in the toolbar.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(iOS)
        if isSheet {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismissBox.action?() }
            }
            ToolbarItem(placement: .topBarLeading) { chatsButton }
            ToolbarItem(placement: .principal) {
                titleText.font(.headline)
            }
        }
        #endif
        if mode == .page, !listBeside {
            ToolbarItem(placement: .navigation) { chatsButton }
        }
        ToolbarItem(placement: .primaryAction) { newChatButton }
        ToolbarItem(placement: .primaryAction) { moreMenu }
    }

    /// Over a module (the floating panel on Mac and iPad) the panel's buttons are in a header of its
    /// own, not in the window's toolbar (which isn't above the panel).
    private var headerInPanel: Bool { mode == .panel && !isSheet }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            chatsButton
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            titleText
                .font(.headline)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            newChatButton
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            moreMenu
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var title: String { store.current?.title ?? String(localized: "Assistant") }

    /// The chat's title, cross-fading when it changes (a new chat gets its title from the server).
    private var titleText: some View {
        Text(verbatim: title)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .smooth, value: title)
    }

    /// The chats, pushed over the chat.
    private var chatsButton: some View {
        Button {
            showChats = true
        } label: {
            Label("Chats", systemImage: "clock.arrow.circlepath")
        }
        .help(Text("Chats"))
    }

    private var newChatButton: some View {
        // No shortcut: on the page ⌘N is File ▸ New Chat; beside a module ⌘N is that module's,
        // and ⇧⌘J (Go ▸ Ask the assistant) starts a new chat.
        Button {
            newChat()
        } label: {
            Label("New chat", systemImage: "square.and.pencil")
        }
        .help(Text("New chat"))
    }

    private var moreMenu: some View {
        Menu {
            if headerInPanel {
                Button("Open as a page", systemImage: "arrow.up.left.and.arrow.down.right") {
                    family.open(.assistantChat(id: store.currentID))
                }
            }
            // Beside another page than the chat's: its next turns about this one. (A message
            // carries the chat's own page, so this is the only way to move it.)
            if let page = movablePage {
                Button("Move to \(AssistantPages.name(page))", systemImage: "mappin.and.ellipse") {
                    Task { await store.moveHere() }
                }
            }
            Button("Copy the chat, with all tool results", systemImage: "doc.on.doc") {
                copy(store.current?.items ?? [])
            }
            .disabled(store.current?.items.isEmpty ?? true)
            // Viewers too (their prompt reads only); the demo has no server to ask.
            if !family.api.client.isDemo {
                Button("Copy Prompt for AI Agent", systemImage: "terminal") { copyAgentPrompt() }
                    .disabled(copyingAgentPrompt)
                    .accessibilityHint(Text("Copies instructions for an AI agent, with access to the family for one hour."))
            }
            if family.canEdit {
                Divider()
                Button("Assistant settings", systemImage: "gearshape") { showSettings = true }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help(Text("More"))
    }

    /// The page beside the panel when the open chat (one the server knows) belongs to another;
    /// on the assistant's page a chat isn't tied to the page it's read on.
    private var movablePage: String? {
        guard mode == .panel, let chat = store.current, !chat.id.isEmpty, let page = chat.page, page != here else {
            return nil
        }
        return here
    }

    private func newChat() {
        store.newChat()
        text = ""
        attachments = []
        sentPending = false
        composerFocused = true
    }

    /// Asks the server for an agent's prompt (a token valid for an hour in it) and copies it.
    private func copyAgentPrompt() {
        guard !copyingAgentPrompt else { return }
        copyingAgentPrompt = true
        Task {
            defer { copyingAgentPrompt = false }
            do {
                let access = try await AssistantAgentAccess.request(family.api)
                FamilyPasteboard.copy(access.prompt)
                agentPromptCopied = true
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }

    private func copy(_ items: [AssistantItem]) {
        AssistantTranscript.copy(AssistantTranscript.markdown(items) { store.toolResult($0) })
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
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
    private var opening: Bool { store.currentID != nil && store.current == nil }

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
            // Exactly as wide as the scroll view: nothing in the chat can make it pan sideways. Its
            // own width, not `containerRelativeFrame`: in the floating panel (an overlay) that took
            // the window's.
            .frame(width: chatWidth > 0 ? chatWidth : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Its frame, not its scroll geometry: that didn't tell when the panel went from its first,
        // narrow layout to its width.
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width in
            if width != chatWidth { chatWidth = width }
        }
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
    private func scrolled(from old: AssistantScrollFollow.Metrics, to new: AssistantScrollFollow.Metrics) {
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
    private func scrollToEndSoon() {
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
    private func startWindow(_ key: WindowKey) {
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
    @ViewBuilder private func itemMenu(items: [(offset: Int, item: AssistantItem)], index: Int, group: Int = 1) -> some View {
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
        if group == 1, case let .tool(tool) = item, let route = AssistantToolLinks.route(tool, familyID: family.family.id) {
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
    private struct WindowKey: Equatable {
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

    // MARK: Composer

    private var filled: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// While the assistant answers, a message waits and goes next (once the chat has its id).
    /// Not while a chat opens: a message then would start a new chat in its place.
    private var canSend: Bool {
        store.ready && preparing == 0 && !opening && (!store.busy || !(store.current?.id.isEmpty ?? true))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The settings couldn't be loaded (and there's no copy here): the chat shows, sending waits.
            if store.settings == nil, let error = store.settingsError {
                HStack(spacing: 8) {
                    Label {
                        Text(verbatim: error).lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Try again") { Task { await store.loadSettings() } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
            }
            if !attachments.isEmpty || preparing > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { a in
                            AssistantPendingChip(attachment: a) {
                                attachments.removeAll { $0.id == a.id }
                            }
                        }
                        ForEach(0..<preparing, id: \.self) { _ in
                            ProgressView()
                                .frame(width: 52, height: 52)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                // Bounces only once the chips don't fit.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            // One box, as in Claude's app: the text over the whole width (two lines at least, it
            // grows to ten), the attach menu and Send / Stop / the mic in a row under it.
            VStack(alignment: .leading, spacing: 2) {
                field
                HStack(spacing: 8) {
                    attachMenu
                    Spacer(minLength: 0)
                    actionButton
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            .contentShape(.rect(cornerRadius: 24))
            // A tap anywhere in the box (not on its buttons) starts typing.
            .onTapGesture { if store.ready { composerFocused = true } }
            // Only once the chat nears the point where older messages get condensed.
            if let usage = store.current?.usage, AssistantContextMeter.shows(usage) {
                AssistantContextMeter(usage: usage)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // Here, not beside the attachments' file picker: two on one view don't both work.
        .letterScanFlow(isPresented: $scanningLetter, findsItems: false) { outcome in attachLetter(outcome) }
    }

    private var attachMenu: some View {
        Menu {
            // A button, not a `PhotosPicker`: that opens the photo library (a synchronous call to
            // the system) as soon as the menu is built, which held up the panel's opening.
            Button("Photo library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            Button("Choose files", systemImage: "folder") { importing = true }
            // Only the text read on the device is attached, never the picture.
            Button("Scan Letter", systemImage: "doc.text.viewfinder") { scanningLetter = true }
            #if os(iOS)
            // Paste in the field takes pictures too; this works without the edit menu.
            Button("Paste image", systemImage: "doc.on.clipboard") { pasteImages() }
            #endif
        } label: {
            Image(systemName: "paperclip")
                .font(.body.weight(.semibold))
                .frame(width: AssistantComposerButton.size, height: AssistantComposerButton.size)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(store.ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .disabled(!store.ready)
        .accessibilityLabel(Text("Attach images or text files"))
        .help(Text("Attach images or text files"))
    }

    private var field: some View {
        TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain)
            // At least two lines high: longer messages are common.
            .lineLimit(2...10)
            .focused($composerFocused)
            // The on-screen keyboard's Return puts in a line break and the Send button sends
            // (as in Messages); a hardware keyboard's Return sends. Only hardware keys get here.
            .onKeyPress(.return, phases: .down) { press in
                switch AssistantReturnKey.action(for: press.modifiers) {
                case .send:
                    send()
                    return .handled
                case .lineBreak:
                    (text, selection) = AssistantReturnKey.insertingLineBreak(into: text, at: selection)
                    return .handled
                case .system:
                    return .ignored
                }
            }
            #if os(macOS)
            .onSubmit { send() }
            #else
            .modifier(AssistantPaste(enabled: store.ready, images: { attach(pasted: $0) },
                                     text: { attach(pastedText: $0) }))
            #endif
            .disabled(!store.ready)
            .padding(.horizontal, 16)
            .padding(.top, 14)
    }

    /// What the button beside the field does: one slot for Send, Stop and (on iPhone and iPad)
    /// the mic.
    private var action: AssistantComposerAction {
        AssistantComposerAction.make(filled: filled, busy: store.busy,
                                     canQueue: !(store.current?.id.isEmpty ?? true),
                                     dictation: AssistantDictation.isAvailable, listening: listening)
    }

    /// One button that morphs between Send, Stop and the mic (`AssistantComposerButton`).
    private var actionButton: some View {
        let action = action
        return AssistantComposerButton(action: action, listening: listening, busy: store.busy,
                                       enabled: enabled(action), shortcut: shortcut(action)) {
            perform(action)
        }
        // Typing while the assistant answers puts Send in Stop's place: ⌘. still stops it.
        .background {
            if action == .send, store.busy, mode != .page {
                Button("Stop") { Task { await store.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func enabled(_ action: AssistantComposerAction) -> Bool {
        switch action {
        case .send: canSend && filled
        case .stop: true
        case .dictate: store.ready
        }
    }

    private func shortcut(_ action: AssistantComposerAction) -> KeyboardShortcut? {
        switch action {
        case .send: KeyboardShortcut(.return, modifiers: .command)
        // On the page, Assistant ▸ Stop has it.
        case .stop: mode == .page ? nil : KeyboardShortcut(".", modifiers: .command)
        case .dictate: nil
        }
    }

    private func perform(_ action: AssistantComposerAction) {
        switch action {
        case .send:
            send()
        case .stop:
            Task { await store.stop() }
        case .dictate:
            // iPhone and iPad only: the Mac's keyboard has dictation of its own (Edit ▸ Start Dictation).
            #if os(iOS)
            if dictation.isListening {
                dictation.stop()
            } else {
                composerFocused = false
                let base = text
                Task { await dictation.start(base: base) { text = $0 } }
            }
            #endif
        }
    }

    private var listening: Bool {
        #if os(iOS)
        dictation.isListening
        #else
        false
        #endif
    }

    private var placeholder: LocalizedStringKey {
        // Until the settings are known the field just waits (disabled), without a word of setting up.
        if store.settings?.configured == false { return "Set up the assistant in the settings first" }
        if listening { return "Listening…" }
        if store.busy { return "Next message – sent once this answer is done…" }
        // Send answers the open question (a tap on an option does too).
        return store.composerAnswers ? "Your own answer…" : "Ask me anything…"
    }

    private func send() {
        #if os(iOS)
        dictation.stop()
        #endif
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              canSend else { return }
        let files = attachments
        text = ""
        attachments = []
        // Scrolled to the top once it is in the chat (a waiting message: once its turn comes).
        sentPending = true
        Task {
            do {
                try await store.send(message, attachments: files.map(\.outgoing))
            } catch {
                sentPending = false
                // It couldn't wait: back in the box, to send again.
                if text.isEmpty { text = message }
                if attachments.isEmpty { attachments = files }
            }
        }
    }

    // MARK: Attachments

    private var room: Int { AssistantAttachments.maxCount - attachments.count - preparing }

    /// Reads attachments one by one (each shows a spinner meanwhile); more than there is room
    /// for are left out with a note.
    private func prepare(_ count: Int, _ read: @escaping (Int) async throws -> AssistantPendingAttachment?) {
        if count > room { ErrorBanner.shared.show(AssistantAttachments.limitMessage) }
        for n in 0..<min(count, max(0, room)) {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                do {
                    guard let attachment = try await read(n) else { return }
                    attachments.append(attachment)
                    if AssistantAttachments.wasCut(attachment) {
                        ErrorBanner.shared.show(String(localized: "“\(attachment.name)” is long: only the first 50,000 characters are sent."))
                    }
                } catch {
                    ErrorBanner.shared.show(error)
                }
            }
        }
    }

    private func attach(_ urls: [URL]) {
        prepare(urls.count) { n in
            let url = urls[n]
            return try await Task.detached { try AssistantAttachments.read(url) }.value
        }
    }

    private func attach(_ items: [PhotosPickerItem]) {
        let first = attachments.count
        prepare(items.count) { n in
            let name = String(localized: "Photo \(first + n + 1).jpg")
            guard let data = try await items[n].loadTransferable(type: Data.self) else {
                throw AssistantAttachmentError.unreadable(name)
            }
            return try await Task.detached { try AssistantAttachments.image(data, name: name) }.value
        }
    }

    /// A scanned letter's text (read on the device; its PDF saved by the review sheet), with the
    /// request to find what to add in it when nothing is typed yet (sent once the user taps Send).
    private func attachLetter(_ outcome: LetterScanOutcome) {
        guard let letter = outcome.text else { return }
        prepare(1) { _ in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = AssistantLetter.prompt }
            return AssistantLetter.attachment(letter)
        }
        focusComposer()
    }

    /// Images from the clipboard.
    private func attach(pasted images: [Data]) {
        let first = attachments.count
        prepare(images.count) { n in
            let name = String(localized: "Photo \(first + n + 1).jpg")
            let data = images[n]
            return try await Task.detached { try AssistantAttachments.image(data, name: name) }.value
        }
    }

    /// Long pasted text, as a text file (`AssistantAttachments.isLongPaste`).
    private func attach(pastedText text: String) {
        prepare(1) { _ in AssistantAttachments.pastedText(text) }
    }

    /// Files and pictures dropped on the chat.
    private func drop(_ providers: [NSItemProvider]) {
        prepare(providers.count) { n in
            try await AssistantAttachments.load(providers[n])
        }
    }

    #if os(iOS)
    /// The pictures on the clipboard (the attach menu's "Paste image").
    private func pasteImages() {
        let board = UIPasteboard.general
        guard board.hasImages else {
            ErrorBanner.shared.show(String(localized: "There is no picture on the clipboard."))
            return
        }
        let images = (board.images ?? []).compactMap { $0.jpegData(compressionQuality: 0.95) }
        attach(pasted: images)
    }
    #endif

    #if os(macOS)
    /// ⌘V in the composer with a picture (or image files) on the clipboard attaches them; text
    /// pastes as usual. (The text field would ignore pictures.)
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v", composerFocused, store.ready,
                  let content = AssistantPasteboard.content() else { return event }
            switch content {
            case let .files(urls): attach(urls)
            case let .image(data): attach(pasted: [data])
            case let .text(text): attach(pastedText: text)
            }
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
    #endif
}

/// File ▸ New Chat (⌘N) and the Assistant menu, on the assistant's page only: the panel beside
/// another module leaves both to that module (it doesn't even set them empty).
private struct AssistantPageCommands: ViewModifier {
    let enabled: Bool
    let menu: ModuleMenu
    let newChat: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusedSceneValue(\.newItem, NewItemAction(title: "New Chat", action: newChat))
                .focusedSceneValue(\.moduleMenu, menu)
        } else {
            content
        }
    }
}

/// Paste (the edit menu, ⌘V) attaches the clipboard's pictures, and long text as a file
/// (`AssistantAttachments.isLongPaste`); shorter text goes into the field as usual. Pictures:
/// iOS 27's `pasteDestination`, before it the field's UIKit text view (`AssistantTextPaste`),
/// which takes the text on every version.
private struct AssistantPaste: ViewModifier {
    let enabled: Bool
    let images: ([Data]) -> Void
    let text: (String) -> Void

    func body(content: Content) -> some View {
        // Only the iOS 27 SDK (Swift 6.4, Xcode 27) has `pasteDestination` on iOS; older Xcodes
        // (CI's) build without it.
        #if os(iOS) && compiler(>=6.4)
        if #available(iOS 27, *) {
            content
                .background(AssistantTextPaste(enabled: enabled, takesImages: false, images: images, text: text))
                .pasteDestination(for: AssistantPastedImage.self) { pasted in
                    images(pasted.map(\.data))
                } validator: { pasted in
                    enabled ? pasted : []
                }
        } else {
            content.background(AssistantTextPaste(enabled: enabled, takesImages: true, images: images, text: text))
        }
        #elseif os(iOS)
        content.background(AssistantTextPaste(enabled: enabled, takesImages: true, images: images, text: text))
        #else
        content
        #endif
    }
}

/// The one button beside the composer's field: Send with something to send (while a turn runs,
/// once the chat has an id to wait in), Stop while a turn runs, else the mic where there is one
/// (dictating goes on until it's stopped there) or a disabled Send.
enum AssistantComposerAction: Equatable {
    case send, stop, dictate

    static func make(filled: Bool, busy: Bool, canQueue: Bool, dictation: Bool, listening: Bool) -> Self {
        if listening { return .dictate }
        if busy { return filled && canQueue ? .send : .stop }
        if filled || !dictation { return .send }
        return .dictate
    }
}

/// What Return does in the composer. Only a hardware keyboard's Return gets here (iPad, Mac); the
/// on-screen keyboard's puts in a line break as in Messages, and the Send button sends.
enum AssistantReturnKey {
    enum Action: Equatable {
        case send
        /// The composer puts the line break in itself (the Mac's field would end editing instead).
        case lineBreak
        /// Left to the system: ⌘↩ is the Send button's, and the iPad's field puts in a line break
        /// for Shift- and Option-Return by itself.
        case system
    }

    static func action(for modifiers: EventModifiers, mac: Bool = isMac) -> Action {
        let held = modifiers.intersection([.shift, .option, .command, .control])
        if held.isEmpty { return .send }
        if held.contains(.command) || held.contains(.control) { return .system }
        return mac ? .lineBreak : .system
    }

    private static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// `text` with a line break in place of the selection (at the end without one), and the
    /// cursor after it. A selection older than the text (dictation changed it) is clamped.
    static func insertingLineBreak(into text: String, at selection: TextSelection?) -> (String, TextSelection) {
        let count = text.utf16.count
        var lower = count, upper = count
        if case let .selection(range)? = selection?.indices {
            // Clamped before measuring: an index past the end would trap.
            lower = min(range.lowerBound, text.endIndex).utf16Offset(in: text)
            upper = max(min(range.upperBound, text.endIndex).utf16Offset(in: text), lower)
        }
        let start = String.Index(utf16Offset: lower, in: text)
        let end = String.Index(utf16Offset: upper, in: text)
        let result = text.replacingCharacters(in: start..<end, with: "\n")
        return (result, TextSelection(insertionPoint: String.Index(utf16Offset: lower + 1, in: result)))
    }
}

/// How the chat scrolls. Sending scrolls the message to the top of the chat, and its answer grows
/// into the room below it (the last turn is at least as tall as the visible part) without moving
/// the chat; once it grows past the bottom, the chat follows it while the end was in view (scrolled
/// up, "Jump to latest" shows instead). A change of the visible height (the keyboard, the window,
/// the first measurement) keeps the end in view that was.
enum AssistantScrollFollow {
    /// Closer than this to the end counts as at the end.
    static let threshold: CGFloat = 48
    /// The chat's padding above and below its items: the last turn leaves it free, so its message
    /// stands that far below the top.
    static let padding: CGFloat = 12

    struct Metrics: Equatable {
        /// The vertical content offset, and the largest it can be (the end of the chat).
        var offset: CGFloat
        var maxOffset: CGFloat
        /// How much of the chat is in view (the scroll view less its bars).
        var visibleHeight: CGFloat = 0

        var distanceFromBottom: CGFloat { max(0, maxOffset - offset) }
        var isAtBottom: Bool { distanceFromBottom <= AssistantScrollFollow.threshold }
    }

    /// The last turn's least height for this visible height: all of it but the padding above and
    /// below, in whole points (a fraction would lay the chat out again for nothing).
    static func turnHeight(visible: CGFloat) -> CGFloat {
        max(0, (visible - 2 * padding).rounded(.down))
    }

    /// After the scroll view changed: whether to scroll to the end now, and whether to go on doing
    /// so until it is there. The visible height changed while the end was in view (or was first
    /// measured): back to the end. The content grew past the end that was in view (an answer
    /// longer than its room), with `follows`: to the new end. The user scrolling ends both.
    static func pin(pending: Bool, from old: Metrics, to new: Metrics, scrolling: Bool,
                    follows: Bool = true) -> (scroll: Bool, pending: Bool) {
        if scrolling { return (false, false) }
        let resized = abs(new.visibleHeight - old.visibleHeight) > 0.5
        let pending = pending || resized && (old.isAtBottom || old.visibleHeight <= 0)
        if pending, new.distanceFromBottom > 0.5 { return (true, true) }
        let grew = !resized && new.maxOffset > old.maxOffset + 0.5
        if follows, grew, old.isAtBottom, new.distanceFromBottom > 0.5 { return (true, false) }
        return (false, false)
    }

    /// Whether the last turn's start (the user's last message) scrolls to the top: a later one in
    /// the same chat (not the one it opened with), when the user sent it or reads at the end.
    static func scrollsToTurn(from old: Int?, to new: Int?, sameChat: Bool, sent: Bool, atEnd: Bool) -> Bool {
        guard sameChat, let old, let new, new > old else { return false }
        return sent || atEnd
    }

    /// The user's own scrolling, not an animation: on macOS an animated scroll to where the chat
    /// already is stays `.animating` and would hold the chat off its end for good.
    static func userScrolls(_ phase: ScrollPhase) -> Bool {
        phase.isScrolling && phase != .animating
    }
}

extension AssistantScrollFollow.Metrics {
    init(_ geometry: ScrollGeometry) {
        // The container leaves out the bars (toolbar or header, composer, keyboard): it is what's in
        // view. The offset starts at -top.
        offset = geometry.contentOffset.y
        maxOffset = geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top
        visibleHeight = geometry.containerSize.height
    }
}

/// Holds the dismiss action for a view that mustn't observe it (`AssistantChatView`).
final class AssistantDismissBox {
    var action: DismissAction?
}

/// Reads `\.dismiss` into a box: only this view is drawn again when it changes.
private struct AssistantDismissReader: View {
    let box: AssistantDismissBox
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = (box.action = dismiss)
        Color.clear.accessibilityHidden(true)
    }
}

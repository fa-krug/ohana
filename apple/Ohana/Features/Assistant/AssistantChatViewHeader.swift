import SwiftUI

// The chat's own bar: what the assistant was asked (a request from another module or a
// shortcut), the routes and links an answer named, and the bar itself with its menus.
// Part of `AssistantChatView` (AssistantChatView.swift).

extension AssistantChatView {
    // MARK: Requests

    /// `family.ask(…)`: a new chat if asked (an empty one is reused), the prompt in the composer
    /// and the attachments with it, sent if asked, and the composer focused.
    func takeRequest() {
        guard takesRequests, visible, family.assistantRequest != nil,
              let request = family.takeAssistantRequest() else { return }
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
    func open(_ route: AppRoute) {
        family.open(route)
        if isSheet { dismissBox.action?() }
    }

    /// Links in answers: the app's own pages (`/f/{id}/…`) open in the app, web links in the
    /// browser.
    func openLink(_ url: URL) -> OpenURLAction.Result {
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
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
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
    var headerInPanel: Bool { mode == .panel && !isSheet }

    var panelHeader: some View {
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

    var title: String { store.current?.title ?? String(localized: "Assistant") }

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
                    .accessibilityHint(
                        Text("Copies instructions for an AI agent, with access to the family for one hour.")
                    )
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

    func newChat() {
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

    func copy(_ items: [AssistantItem]) {
        AssistantTranscript.copy(AssistantTranscript.markdown(items) { store.toolResult($0) })
    }
}

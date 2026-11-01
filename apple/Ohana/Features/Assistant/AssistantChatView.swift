import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where the chat is shown: the panel beside a module (the shell's inspector, a sheet on
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: AssistantChatStore
    let mode: AssistantChatMode
    /// The chat list is a column beside the chat (the page when there is room): no history
    /// button then. The panel beside a module has none either, only the sheet on iPhone.
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
    @State private var importing = false
    @State private var dropping = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var dictation = AssistantDictation()
    @FocusState private var composerFocused: Bool
    @State private var scroll = ScrollPosition(edge: .bottom)
    /// New content scrolls into view while this is on: the user is at the end of the chat (or
    /// went back there). Scrolling up turns it off, so an answer can be read while it streams.
    @State private var following = true
    @State private var scrollPhase: ScrollPhase = .idle
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
            .safeAreaInset(edge: .top, spacing: 0) { if headerInPanel { panelHeader } }
            .navigationTitle(Text(verbatim: store.current?.title ?? String(localized: "Assistant")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { if visible && !headerInPanel { toolbar } }
            .navigationDestination(isPresented: $showChats) {
                AssistantChatListView(store: store) {
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

    /// The store tells this family's screens what changed.
    private func connect() {
        let family = family
        store.onChange = { areas in family.didChange(areas) }
    }

    private func focusComposer() {
        Task {
            // After the panel (or the sheet) is in place, else the focus doesn't stick.
            try? await Task.sleep(for: .milliseconds(150))
            if store.ready { composerFocused = true }
        }
    }

    // MARK: Requests

    /// `family.ask(…)`: a new chat if asked (an empty one is reused), the prompt in the composer,
    /// sent if asked, and the composer focused.
    private func takeRequest() {
        guard takesRequests, visible, family.assistantRequest != nil, let request = family.takeAssistantRequest() else { return }
        showChats = false
        if request.newChat {
            store.newChatUnlessEmpty()
            attachments = []
        }
        if let prompt = request.prompt, !prompt.isEmpty {
            text = prompt
            if request.send {
                Task {
                    // The settings first: sending needs to know the assistant is set up.
                    if store.settings == nil { await store.loadSettings() }
                    send()
                }
            }
        }
        focusComposer()
    }

    // MARK: Links

    /// Opens a place of the app: the panel on iPhone gets out of the way.
    private func open(_ route: AppRoute) {
        family.open(route)
        if isSheet { dismiss() }
    }

    /// Links in answers: the app's own pages (`/f/{id}/…`) open in the app, web links in the
    /// browser.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == nil, let (familyID, route) = AppRoute.parse(webPath: url.path), familyID == family.family.id {
            open(route)
            return .handled
        }
        return .systemAction
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(iOS)
        if isSheet {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        #endif
        // Beside a module the chats are on the page ("Open as a page"); the iPhone's sheet has
        // no page to open, so it keeps the button.
        if !listBeside, mode == .page || isSheet {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showChats = true
                } label: {
                    Label("Chats", systemImage: "clock.arrow.circlepath")
                }
                .help(Text("Chats"))
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { newChatMenu }
    }

    /// Beside a module (the inspector on Mac and iPad) the panel's buttons are in a header of its
    /// own, not in the window's toolbar: the toolbar's items came and went with every opening
    /// and closing of the panel, the slowest part of its sliding in.
    private var headerInPanel: Bool { mode == .panel && !isSheet }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text(verbatim: store.current?.title ?? String(localized: "Assistant"))
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            newChatMenu
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            Button {
                family.open(.assistantChat(id: store.currentID))
            } label: {
                Label("Open as a page", systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Open as a page"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var newChatMenu: some View {
        Menu {
            // No shortcut: on the page ⌘N is File ▸ New Chat; beside a module ⌘N is that
            // module's, and ⇧⌘J (Go ▸ Ask the assistant) starts a new chat.
            Button("New chat", systemImage: "square.and.pencil") { newChat() }
            Button("Copy the chat, with all tool results", systemImage: "doc.on.doc") {
                copy(store.current?.items ?? [])
            }
            .disabled(store.current?.items.isEmpty ?? true)
            if family.canEdit {
                Divider()
                Button("Assistant settings", systemImage: "gearshape") { showSettings = true }
            }
        } label: {
            Label("New chat", systemImage: "square.and.pencil")
        } primaryAction: {
            newChat()
        }
        .help(Text("New chat"))
    }

    private func newChat() {
        store.newChat()
        text = ""
        attachments = []
        following = true
        composerFocused = true
    }

    private func copy(_ items: [AssistantItem]) {
        AssistantTranscript.copy(AssistantTranscript.markdown(items) { store.toolResult($0) })
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let settings = store.settings, !settings.configured {
            AssistantSetupView(canEdit: family.canEdit) { showSettings = true }
        } else if store.settings == nil, let error = store.settingsError {
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("Try again") { Task { await store.loadSettings() } }
                    .buttonStyle(.glassProminent)
            }
        } else if store.settings == nil {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // On the page a chat isn't tied to the page it's read on.
                if mode == .panel, let page = store.current?.page, page != here {
                    elsewhere(page: page)
                }
                if store.current?.items.isEmpty ?? true {
                    suggestions
                }
                let items = visibleItems
                ForEach(Array(items.enumerated()), id: \.element.offset) { index, entry in
                    AssistantItemView(item: entry.item, store: store, saved: store.savedCopy != nil, open: open)
                        .equatable()
                        .contextMenu { itemMenu(items: items, index: index) }
                }
                if store.busy {
                    AssistantActivityLine(store: store)
                }
                ForEach(store.current?.queued ?? []) { entry in
                    AssistantQueuedRow(entry: entry, store: store)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($scroll)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: AssistantScrollFollow.Metrics.self) { geometry in
            AssistantScrollFollow.Metrics(geometry)
        } action: { old, new in
            following = AssistantScrollFollow.follows(following, from: old, to: new)
            // The answer grew (or the keyboard came up): keep its end in view.
            if AssistantScrollFollow.shouldPin(following: following, metrics: new, scrolling: AssistantScrollFollow.userScrolls(scrollPhase)) {
                scroll.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: store.currentID) {
            following = true
            scroll.scrollTo(edge: .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
            if !following { jumpToLatest }
        }
        .overlay(alignment: .topTrailing) {
            if let saved = store.savedCopy {
                SavedCopyBadge(date: saved.date, updating: saved.updating, retry: store.retrySaved)
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: following)
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
        .transition(.scale.combined(with: .opacity))
    }

    /// Back to the end of the chat, following it again (animated unless Reduce Motion is on).
    private func scrollToLatest() {
        following = true
        withAnimation(reduceMotion ? nil : .smooth) { scroll.scrollTo(edge: .bottom) }
    }

    /// Copy: the message, or a whole answer (everything since the user's last message) with the
    /// tool results.
    @ViewBuilder private func itemMenu(items: [(offset: Int, item: AssistantItem)], index: Int) -> some View {
        let item = items[index].item
        if case let .assistant(text) = item {
            Button("Copy", systemImage: "doc.on.doc") { AssistantTranscript.copy(text) }
        }
        if case let .user(text, _) = item, !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { AssistantTranscript.copy(text) }
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
        if case let .tool(tool) = item, let route = AssistantToolLinks.route(tool, familyID: family.family.id) {
            Button("Show", systemImage: "arrow.up.forward.square") { open(route) }
        }
    }

    private func elsewhere(page: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
            Text("This chat belongs to \(AssistantPages.name(page)).")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Move to \(AssistantPages.name(here))") {
                Task { await store.moveHere() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.current?.id.isEmpty ?? true)
        }
        .contentCard(cornerRadius: 14, padding: 10)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TintedIcon(systemImage: "sparkles", tint: ModuleTint.assistant)
                Text("Ask me anything about your family’s plans, for example:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // An example goes into the composer, to read (and change) before it's sent: the
            // assistant may change things.
            ForEach(AssistantPages.examples(store.current?.page ?? here), id: \.self) { example in
                Button {
                    text = example
                    composerFocused = true
                } label: {
                    Text(verbatim: example)
                        .multilineTextAlignment(.leading)
                        .contentCard(cornerRadius: 16, padding: 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Puts it in the message field"))
            }
        }
        .padding(.top, 8)
    }

    // MARK: Composer

    private var filled: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// While the assistant answers, a message waits and goes next (once the chat has its id).
    private var canSend: Bool {
        store.ready && preparing == 0 && (!store.busy || !(store.current?.id.isEmpty ?? true))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    field
                    if AssistantDictation.isAvailable {
                        micButton
                    }
                    if store.busy {
                        Button {
                            Task { await store.stop() }
                        } label: {
                            Image(systemName: "stop.fill")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        // On the page, Assistant ▸ Stop has it.
                        .keyboardShortcut(mode == .page ? nil : KeyboardShortcut(".", modifiers: .command))
                        .accessibilityLabel(Text("Stop"))
                        .help(Text("Stop"))
                    }
                    if !store.busy || filled {
                        Button {
                            send()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.semibold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .tint(ModuleTint.assistant)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend || !filled)
                        .accessibilityLabel(store.busy ? Text("Send after this answer") : Text("Send"))
                        .help(store.busy ? Text("Send after this answer") : Text("Send"))
                    }
                }
            }
            if let usage = store.current?.usage, usage.max > 0 {
                AssistantContextMeter(usage: usage)
                    .padding(.horizontal, 8)
            }
            if let hint = AssistantKeyboardHint.text(regularWidth: sizeClass != .compact) {
                Text(verbatim: hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var attachMenu: some View {
        Menu {
            // A button, not a `PhotosPicker`: that opens the photo library (a synchronous call to
            // the system) as soon as the menu is built, which held up the panel's opening.
            Button("Photo library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            Button("Choose files", systemImage: "folder") { importing = true }
            #if os(iOS)
            // ⌘V pastes pictures from iOS 27 on; this works everywhere.
            Button("Paste image", systemImage: "doc.on.clipboard") { pasteImages() }
            #endif
        } label: {
            Image(systemName: "paperclip")
                .font(.body.weight(.medium))
                .frame(width: 22, height: 22)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!store.ready)
        .accessibilityLabel(Text("Attach images or text files"))
        .help(Text("Attach images or text files"))
    }

    private var field: some View {
        TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
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
            .modifier(AssistantImagePaste(enabled: store.ready) { attach(pasted: $0) })
            #endif
            .disabled(!store.ready)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var micButton: some View {
        Button {
            #if os(macOS)
            composerFocused = true
            dictation.start()
            #else
            if dictation.isListening {
                dictation.stop()
            } else {
                composerFocused = false
                let base = text
                Task { await dictation.start(base: base) { text = $0 } }
            }
            #endif
        } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .font(.body.weight(.medium))
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(listening ? ModuleTint.assistant : nil)
        .disabled(!store.ready)
        .accessibilityLabel(listening ? Text("Stop dictation") : Text("Dictate"))
        .help(listening ? Text("Stop dictation") : Text("Dictate"))
    }

    private var listening: Bool {
        #if os(iOS)
        dictation.isListening
        #else
        false
        #endif
    }

    private var placeholder: LocalizedStringKey {
        if !store.ready { return "Set up the assistant in the settings first" }
        if listening { return "Listening…" }
        return store.busy ? "Next message – sent once this answer is done…" : "Ask me anything…"
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
        scrollToLatest()
        Task {
            do {
                try await store.send(message, attachments: files.map(\.outgoing))
            } catch {
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

    /// Images from the clipboard.
    private func attach(pasted images: [Data]) {
        let first = attachments.count
        prepare(images.count) { n in
            let name = String(localized: "Photo \(first + n + 1).jpg")
            let data = images[n]
            return try await Task.detached { try AssistantAttachments.image(data, name: name) }.value
        }
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

/// ⌘V with pictures on the clipboard attaches them (iOS 27 and later; the text field pastes
/// text as usual).
private struct AssistantImagePaste: ViewModifier {
    let enabled: Bool
    let paste: ([Data]) -> Void

    func body(content: Content) -> some View {
        // Only the iOS 27 SDK (Swift 6.4, Xcode 27) has `pasteDestination` on iOS; older Xcodes
        // (CI's) build without it.
        #if os(iOS) && compiler(>=6.4)
        if #available(iOS 27, *) {
            content.pasteDestination(for: AssistantPastedImage.self) { images in
                paste(images.map(\.data))
            } validator: { images in
                enabled ? images : []
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The keyboard line under the composer (web: "Enter sends, Shift+Enter for a new line…"),
/// nil where there is no keyboard to speak of (iPhone).
enum AssistantKeyboardHint {
    static func text(regularWidth: Bool) -> String? {
        #if os(macOS)
        String(localized: "Return sends, Shift-Return starts a new line. Paste (⌘V) or drop screenshots and files.")
        #else
        regularWidth
            ? String(localized: "With a keyboard, Return sends and Shift-Return starts a new line. Attach, paste or drop screenshots and files.")
            : nil
        #endif
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

/// When the chat scrolls along with new content: while the user is at (or near) its end. Once
/// they scroll up it stays where they read, until they scroll back down or jump to the latest.
enum AssistantScrollFollow {
    /// Closer than this to the end counts as at the end.
    static let threshold: CGFloat = 48

    struct Metrics: Equatable {
        /// The vertical content offset, and the largest it can be (the end of the chat).
        var offset: CGFloat
        var maxOffset: CGFloat

        var distanceFromBottom: CGFloat { max(0, maxOffset - offset) }
        var isAtBottom: Bool { distanceFromBottom <= AssistantScrollFollow.threshold }
    }

    /// After the scroll view changed: still following? A move up while the end didn't move up
    /// too (the content didn't shrink, the view didn't grow) is the user scrolling away.
    static func follows(_ following: Bool, from old: Metrics, to new: Metrics) -> Bool {
        if new.isAtBottom { return true }
        if new.offset < old.offset - 0.5, new.maxOffset >= old.maxOffset - 0.5 { return false }
        return following
    }

    /// The user's own scrolling, not an animation: on macOS an animated scroll to where the chat
    /// already is stays `.animating` and would hold the chat off its end for good.
    static func userScrolls(_ phase: ScrollPhase) -> Bool {
        phase.isScrolling && phase != .animating
    }

    /// Whether to scroll to the end now: following, not there, and the user isn't scrolling.
    static func shouldPin(following: Bool, metrics: Metrics, scrolling: Bool) -> Bool {
        following && !scrolling && metrics.distanceFromBottom > 0.5
    }
}

extension AssistantScrollFollow.Metrics {
    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        #if os(macOS)
        // The container leaves out the bars (toolbar, composer); the offset starts at -top.
        maxOffset = geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top
        #else
        maxOffset = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        #endif
    }
}

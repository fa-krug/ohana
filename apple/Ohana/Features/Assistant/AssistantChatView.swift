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
    @FocusedValue(\.shell) private var shell
    let store: AssistantChatStore
    let mode: AssistantChatMode
    /// The chat list is a column beside the chat (the page when there is room): no history
    /// button then.
    var listBeside = false
    /// Takes the family's `ask` requests (only while this view is the one on screen).
    var takesRequests = true

    @State private var text = ""
    @State private var attachments: [AssistantPendingAttachment] = []
    @State private var preparing = 0
    @State private var showChats = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var dropping = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var dictation = AssistantDictation()
    @FocusState private var composerFocused: Bool
    #if os(macOS)
    @State private var pasteMonitor: Any?
    #endif

    /// The page the user looks at (web: `pageOf`; the assistant's page counts as the overview).
    private var here: String {
        guard let module = shell?.module.wrappedValue else { return "overview" }
        return module == .assistant ? "overview" : module.rawValue
    }

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
            .navigationTitle(Text(verbatim: store.current?.title ?? String(localized: "Assistant")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .navigationDestination(isPresented: $showChats) {
                AssistantChatListView(store: store) {
                    showChats = false
                    composerFocused = true
                }
            }
            .background { OhanaBackground(tint: ModuleTint.assistant) }
            .environment(\.openURL, OpenURLAction { url in openLink(url) })
            .task(id: family.revision(.settings)) { await store.loadSettings() }
            .task {
                await store.restoreLatest()
                await store.refresh()
            }
            .onAppear {
                store.addViewer()
                connect()
                focusComposer()
                #if os(macOS)
                installPasteMonitor()
                #endif
            }
            .onDisappear {
                store.removeViewer()
                #if os(iOS)
                dictation.stop()
                #endif
                #if os(macOS)
                removePasteMonitor()
                #endif
            }
            .onChange(of: here, initial: true) { store.page = here }
            .onChange(of: family.assistantRequest?.id, initial: true) { takeRequest() }
            .onChange(of: takesRequests) { takeRequest() }
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await store.refresh() } } else if scenePhase == .background { store.unfollow() }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await store.loadSettings() } }) {
                NavigationStack {
                    AssistantSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
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
            .onChange(of: photos) {
                let items = photos
                photos = []
                attach(items)
            }
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
        guard takesRequests, family.assistantRequest != nil, let request = family.takeAssistantRequest() else { return }
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
        if !listBeside {
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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New chat", systemImage: "square.and.pencil") { newChat() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
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
        if mode == .panel, !isSheet {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    family.open(.assistantChat(id: store.currentID))
                } label: {
                    Label("Open as a page", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help(Text("Open as a page"))
            }
        }
    }

    private func newChat() {
        store.newChat()
        text = ""
        attachments = []
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

    /// Changes whenever the chat grows, so it scrolls along.
    private var scrollKey: Int {
        var hasher = Hasher()
        hasher.combine(store.current?.items.count)
        if case let .assistant(text)? = store.current?.items.last { hasher.combine(text.count) }
        hasher.combine(store.current?.queued.count)
        hasher.combine(store.busy)
        return hasher.finalize()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
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
                        AssistantItemView(item: entry.item, store: store, open: open)
                            .contextMenu { itemMenu(items: items, index: index) }
                    }
                    if store.busy {
                        AssistantActivityLine(store: store)
                    }
                    ForEach(store.current?.queued ?? []) { entry in
                        AssistantQueuedRow(entry: entry, store: store)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollKey) {
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.currentID) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
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
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(store.current?.id.isEmpty ?? true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TintedIcon(systemImage: "sparkles", tint: ModuleTint.assistant)
                Text("Ask me anything about your family’s plans, for example:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AssistantPages.examples(store.current?.page ?? here), id: \.self) { example in
                Button {
                    send(example)
                } label: {
                    Text(verbatim: example)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
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
                        .keyboardShortcut(".", modifiers: .command)
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
            PhotosPicker(selection: $photos, maxSelectionCount: AssistantAttachments.maxCount,
                         matching: .images) {
                Label("Photo library", systemImage: "photo.on.rectangle")
            }
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
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($composerFocused)
            .submitLabel(.send)
            .onSubmit { send() }
            #if os(iOS)
            // Return sends (a multi-line field would put in a line break instead).
            .onChange(of: text) { before, after in
                if after == before + "\n", !dictation.isListening {
                    text = before
                    send()
                }
            }
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

    private func send(_ value: String? = nil) {
        #if os(iOS)
        dictation.stop()
        #endif
        let message = value ?? text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              canSend else { return }
        let files = attachments
        text = ""
        attachments = []
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

/// ⌘V with pictures on the clipboard attaches them (iOS 27 and later; the text field pastes
/// text as usual).
private struct AssistantImagePaste: ViewModifier {
    let enabled: Bool
    let paste: ([Data]) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
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
        String(localized: "Return sends, Option-Return starts a new line. Paste (⌘V) or drop screenshots and files.")
        #else
        regularWidth
            ? String(localized: "Return sends. Attach, paste or drop screenshots and files.")
            : nil
        #endif
    }
}

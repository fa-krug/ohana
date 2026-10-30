import PhotosUI
import SwiftUI

/// The assistant's chat, in the shell's inspector (a sheet on iPhone) (web: chat-panel.tsx):
/// the open chat with its messages (Markdown), tool activity, changes with undo, questions to
/// answer, messages waiting for the answer, attachments, how full the model's context is, and
/// the chat list. The family's chats are kept by `AssistantChatStore`, which follows a running
/// turn live and tells the other modules what the assistant changed.
struct AssistantPanel: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        AssistantPanelContent(store: AssistantChatStore.shared(for: family.api))
            .id(family.family.id)
    }
}

/// The page names the chat's banner uses.
enum AssistantPages {
    static func name(_ page: String) -> String {
        switch page {
        case "calendar": String(localized: "Calendar")
        case "finance": String(localized: "Finance")
        case "meals": String(localized: "Meals")
        case "appointments": String(localized: "Appointments")
        case "settings": String(localized: "Settings")
        default: String(localized: "Overview")
        }
    }

    /// Examples for a new chat, fitting the page it starts on.
    static func examples(_ page: String) -> [String] {
        let gaps = String(localized: "Which days this year still need cover, and who could take them?")
        let planWithout = String(localized: "Plan next week’s meals without fish.")
        switch page {
        case "calendar":
            return [gaps, String(localized: "Look up next year’s public holidays here and add them to the calendar.")]
        case "finance":
            return [String(localized: "How much did we spend on groceries this year, per month?"),
                    String(localized: "Sort our uncategorized transactions into categories.")]
        case "meals":
            return [planWithout, String(localized: "What’s still on the shopping list? Add 2 l of milk.")]
        case "appointments":
            return [String(localized: "Find a dermatologist appointment before June."),
                    String(localized: "Which searches found something, and what is the earliest slot?")]
        case "settings":
            return [String(localized: "Set up this year’s entry types: day care closed, each parent’s vacation and public holidays."),
                    String(localized: "Suggest categories for our finances and add them.")]
        default:
            return [gaps, planWithout]
        }
    }
}

struct AssistantPanelContent: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusedValue(\.shell) private var shell
    let store: AssistantChatStore

    @State private var text = ""
    @State private var attachments: [AssistantPendingAttachment] = []
    @State private var preparing = 0
    @State private var showChats = false
    @State private var showSettings = false
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @FocusState private var composerFocused: Bool

    /// The page the user looks at, if the shell says.
    private var here: String? { shell?.module.wrappedValue.rawValue }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(Text(verbatim: store.current?.title ?? String(localized: "Assistant")))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .navigationDestination(isPresented: $showChats) {
                    AssistantChatListView(store: store) { showChats = false }
                }
                .background { OhanaBackground(tint: ModuleTint.assistant) }
        }
        .task(id: family.revision(.settings)) { await store.loadSettings() }
        .task { await store.refresh() }
        .onAppear { connect() }
        .onDisappear { store.unfollow() }
        .onChange(of: here, initial: true) { store.page = here ?? "overview" }
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

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(iOS)
        if sizeClass == .compact {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button {
                showChats = true
            } label: {
                Label("Chats", systemImage: "clock.arrow.circlepath")
            }
            .help(Text("Chats"))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
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
        }
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
                    if let page = store.current?.page, let here, page != here {
                        elsewhere(page: page, here: here)
                    }
                    if store.current?.items.isEmpty ?? true {
                        suggestions
                    }
                    let items = visibleItems
                    ForEach(Array(items.enumerated()), id: \.element.offset) { index, entry in
                        AssistantItemView(item: entry.item, store: store)
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
    }

    private func elsewhere(page: String, here: String) -> some View {
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
            ForEach(AssistantPages.examples(store.current?.page ?? here ?? "overview"), id: \.self) { example in
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
                    Menu {
                        PhotosPicker(selection: $photos, maxSelectionCount: AssistantAttachments.maxCount,
                                     matching: .images) {
                            Label("Photo library", systemImage: "photo.on.rectangle")
                        }
                        Button("Choose files", systemImage: "folder") { importing = true }
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

                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .submitLabel(.send)
                        .onSubmit { send() }
                        .disabled(!store.ready)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))

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
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var placeholder: LocalizedStringKey {
        if !store.ready { return "Set up the assistant in the settings first" }
        return store.busy ? "Next message – sent once this answer is done…" : "Ask me anything…"
    }

    private func send(_ value: String? = nil) {
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

    private func attach(_ urls: [URL]) {
        if urls.count > room {
            ErrorBanner.shared.show(String(localized: "At most \(AssistantAttachments.maxCount) attachments per message."))
        }
        for url in urls.prefix(max(0, room)) {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                do {
                    let attachment = try await Task.detached { try AssistantAttachments.read(url) }.value
                    attachments.append(attachment)
                } catch {
                    ErrorBanner.shared.show(error)
                }
            }
        }
    }

    private func attach(_ items: [PhotosPickerItem]) {
        if items.count > room {
            ErrorBanner.shared.show(String(localized: "At most \(AssistantAttachments.maxCount) attachments per message."))
        }
        for (n, item) in items.prefix(max(0, room)).enumerated() {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                let name = String(localized: "Photo \(attachments.count + n + 1).jpg")
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AssistantAttachmentError.unreadable(name)
                    }
                    let attachment = try await Task.detached { try AssistantAttachments.image(data, name: name) }.value
                    attachments.append(attachment)
                } catch {
                    ErrorBanner.shared.show(error)
                }
            }
        }
    }
}

/// An attachment in the composer, with a remove button.
struct AssistantPendingChip: View {
    let attachment: AssistantPendingAttachment
    let remove: () -> Void
    @State private var image: Image?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    image.resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    Label {
                        Text(verbatim: attachment.name).lineLimit(1)
                    } icon: {
                        Image(systemName: attachment.kind == "image" ? "photo" : "doc.text")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 160, minHeight: 52)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
            .help(Text(verbatim: attachment.name))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("Remove \(attachment.name)"))
        }
        .task(id: attachment.id) {
            image = attachment.url.flatMap(AssistantAttachments.image(dataURL:))
        }
    }
}

/// Without AI settings: editors set them up, viewers ask an editor.
struct AssistantSetupView: View {
    let canEdit: Bool
    let openSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Set up the assistant", systemImage: "sparkles")
                .foregroundStyle(ModuleTint.assistant)
        } description: {
            if canEdit {
                Text("Connect any OpenAI-compatible AI (OpenAI, OpenRouter, Mistral, Gemini, a local model …) in the settings. It can then look things up on the web and plan in your calendar and finances.")
            } else {
                Text("Nobody has set up the assistant for this family yet. Ask an editor of the family to do it in the settings.")
            }
        } actions: {
            if canEdit {
                Button("Open the settings", action: openSettings)
                    .buttonStyle(.glassProminent)
                    .tint(ModuleTint.assistant)
            }
        }
    }
}

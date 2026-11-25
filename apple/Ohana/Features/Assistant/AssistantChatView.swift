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
///
/// Its parts live in the `AssistantChat…` files beside this one (its bar, its messages, its
/// composer and the helpers around it), so what they use is internal rather than private.
struct AssistantChatView: View {
    @Environment(FamilyContext.self) var family
    /// The sheet's dismiss action (iPhone), kept by `AssistantDismissReader`, not read here: on
    /// the iPad's page `\.dismiss` changes with every update, and read here each change drew the
    /// whole chat again, whose toolbar changed it again (a loop at full CPU).
    @State var dismissBox = AssistantDismissBox()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) var reduceMotion
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

    @State var text = ""
    @State var selection: TextSelection?
    @State var attachments: [AssistantPendingAttachment] = []
    @State var preparing = 0
    @State var showChats = false
    @State var showSettings = false
    /// "Copy Prompt for AI Agent": the request runs (taps meanwhile do nothing), then the note.
    @State var copyingAgentPrompt = false
    @State var agentPromptCopied = false
    @State var importing = false
    @State var dropping = false
    @State private var photos: [PhotosPickerItem] = []
    @State var pickingPhotos = false
    @State var scanningLetter = false
    @State var dictation = AssistantDictation()
    @FocusState var composerFocused: Bool
    @State var scroll = ScrollPosition(edge: .bottom)
    /// The end of the chat is in view; else "Jump to latest" floats over it. Sending scrolls the
    /// message to the top, the answer grows below it; past the bottom the chat follows it while the
    /// end is in view.
    @State var atEnd = true
    @State var scrollPhase: ScrollPhase = .idle
    /// How tall the last turn is at least (the visible height of the chat, `AssistantTurnLayout`).
    @State var turnHeight: CGFloat = 0
    /// The visible height changed with the end in view: back to the end until it is there.
    @State var pinning = false
    /// The user sent a message: it scrolls to the top once it is in the chat.
    @State var sentPending = false
    /// The sent message is on its way to the top (animated): the chat growing doesn't jump meanwhile.
    @State var turnScrolling = false
    /// A scroll to the end waits for the update to be through (`scrollToEndSoon`).
    @State var endQueued = false
    /// iOS: the message whose text the "Select Text" sheet shows.
    @State var selecting: AssistantSelectableText?
    /// Where the window of drawn items starts (`AssistantItemWindow`), worked out for the chat
    /// `windowKey` names.
    @State var windowStart = 0
    @State var windowKey: WindowKey?
    /// Items animate in from this chat (`AssistantChatStore.session`) on: not the ones it opened with.
    @State var settledSession: Int?
    #if os(macOS)
    @State var pasteMonitor: Any?
    #endif


    /// The panel on iPhone is a sheet: opening a place in another module closes it.
    var isSheet: Bool {
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
            // Plain, without the module's tinted gradient: long answers read best on a neutral page
            // (the assistant's color stays on the user's bubbles and the buttons).
            .background { Color.pageBackground.ignoresSafeArea() }
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
    var moduleMenu: ModuleMenu {
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
                Button("Assistant settings", systemImage: "gearshape") { showSettings = true }
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

    func focusComposer() {
        Task {
            // After the panel (or the sheet) is in place, else the focus doesn't stick.
            try? await Task.sleep(for: .milliseconds(150))
            if store.ready { composerFocused = true }
        }
    }
}

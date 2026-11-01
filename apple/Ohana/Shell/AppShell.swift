import SwiftUI

/// The frame around a family (the web app's components/shell/app-shell.tsx): the modules as a
/// sidebar in sections (iPad, Mac) or a floating Liquid Glass tab bar (iPhone), the family
/// switcher, the search across the modules (its own tab, ⌘K), and the assistant as an inspector
/// on the right (a sheet on iPhone), ⌘J. The iPhone's tab bar holds five tabs: with more, iOS
/// puts the rest under "More", which pushes a tab's own navigation stack under a second bar. So
/// there the appointments and the settings (`Module.phonePages`) open as sheets from the family
/// page (`FamilySidebarHost`) instead.
struct AppShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The tab on screen; nil until one is picked: then the scene's last one (`storedModule`).
    /// The tab view's selection is this state, only mirrored to the scene storage: bound to it
    /// directly, the iPhone's tab bar jumps back to the old tab for a moment at every switch.
    @State private var module: Module?
    @SceneStorage("module") private var storedModule: Module = .overview

    /// The tab on screen; the overview while the server has its module off (and on iPhone for a
    /// page that isn't a tab there).
    private var selection: Binding<Module> {
        Binding {
            let current = module ?? storedModule
            return app.isEnabled(current) && !Module.notTabs.contains(current) ? current : .overview
        } set: { show($0) }
    }
    /// On iPhone: the appointments or the settings, as a sheet over the tabs.
    @State private var phonePage: Module?
    /// The assistant panel: each window opens it as the last one left it (on iPhone, where it
    /// is a sheet, closed).
    @State private var showAssistant = AppShell.assistantWasOpen

    static let assistantOpenKey = "assistantOpen"

    private static var assistantWasOpen: Bool {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return false }
        #endif
        return UserDefaults.standard.bool(forKey: assistantOpenKey)
    }

    var body: some View {
        @Bindable var app = app
        if let family = app.selectedFamily, let context = app.context(for: family) {
            // The modules the server has on (GET /api/v1/server).
            let assistantOn = context.isEnabled(.assistant)
            TabView(selection: selection) {
                tab(.overview, assistantOn: assistantOn)
                TabSection("Modules") {
                    ForEach(Module.modules.filter { context.isEnabled($0) && !Module.notTabs.contains($0) }) {
                        tab($0, assistantOn: assistantOn)
                    }
                }
                if !Module.notTabs.contains(.settings) {
                    tab(.settings, assistantOn: assistantOn)
                }
                // The iPhone's tab bar shows it apart, at its end; the sidebar at its top.
                Tab(value: Module.search, role: .search) {
                    page(.search, assistantOn: assistantOn)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewSidebarHeader { FamilySwitcher() }
            .tabViewSidebarBottomBar {
                SidebarSettingsButton(selected: selection.wrappedValue == .settings) { module = .settings }
            }
            .sheet(item: $phonePage) { page in
                PhonePageSheet(page: page)
            }
            .onChange(of: module) { if let module { storedModule = module } }
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            #endif
            .modifier(AssistantPresentation(isPresented: $showAssistant, enabled: assistantOn))
            #if os(iOS)
            // Where the tab view has no sidebar: the family page behind the tabs.
            .modifier(FamilySidebarHost(active: sizeClass == .compact, current: selection.wrappedValue))
            #endif
            // The letter scanner over everything (the family menu, Spotlight / Siri / Shortcuts).
            .modifier(ShellLetterScan(context: context, assistantSheet: $showAssistant, phonePage: $phonePage))
            // The panel's settings and chats before it first opens, so it doesn't wait for them.
            .task(id: assistantOn) {
                if assistantOn { await AssistantChatStore.shared(for: context.api).preload() }
            }
            // The family's recipes in Spotlight, again after they change.
            .modifier(RecipeSpotlightFamilyUpdates())
            // The shopping list in Reminders: at becoming active, on showing the family, after changes.
            .modifier(ShoppingRemindersUpdates())
            .environment(context)
            .id(family.id)
            .focusedSceneValue(\.shell, ShellFocus(module: selection, assistant: $showAssistant,
                                                   modules: Module.allCases.filter { context.isEnabled($0) },
                                                   ask: { context.ask(newChat: true) },
                                                   search: { context.startSearch() }))
            .onChange(of: context.assistantRequest?.id) {
                guard context.assistantRequest != nil else { return }
                // The assistant's page takes the request itself when it's on screen.
                if selection.wrappedValue == .assistant, sizeClass != .compact { return }
                showAssistant = true
            }
            .onChange(of: AssistantInbox.shared.pending?.id, initial: true) {
                // "Ask Ohana" from Siri, Shortcuts or Spotlight.
                guard let pending = AssistantInbox.shared.take() else { return }
                context.ask(pending.prompt, send: pending.prompt != nil, newChat: true)
            }
            .sheet(isPresented: $app.showsConnect) { ConnectServerView().errorBanner() }
            .onReceive(NotificationCenter.default.publisher(for: .openModule)) { note in
                if let target = note.object as? Module, context.isEnabled(target) { show(target) }
            }
            .onChange(of: context.pendingRoute, initial: true) {
                guard let route = context.pendingRoute else { return }
                #if os(iOS)
                // The iPhone has no assistant tab: its page opens as the panel.
                if route.module == .assistant, sizeClass == .compact {
                    if case let .assistantChat(id?) = context.takeRoute(for: .assistant) {
                        let store = AssistantChatStore.shared(for: context.api)
                        Task { await store.open(id) }
                    }
                    showAssistant = true
                    return
                }
                #endif
                show(route.module)
                if case let .module(target) = route, context.pendingRoute == route {
                    // A bare module needs nothing pushed.
                    _ = context.takeRoute(for: target)
                }
            }
            #if DEBUG
            // Development: `-OHANA_DEV_MODULE calendar` / `-OHANA_DEV_ASSISTANT YES` open a module or
            // the assistant at launch (screenshots, UI checks).
            .onAppear {
                let defaults = UserDefaults.standard
                if let name = defaults.string(forKey: "OHANA_DEV_MODULE"), let target = Module(rawValue: name),
                   context.isEnabled(target) {
                    show(target)
                }
                if defaults.object(forKey: "OHANA_DEV_ASSISTANT") != nil {
                    showAssistant = defaults.bool(forKey: "OHANA_DEV_ASSISTANT")
                }
                // `-OHANA_DEV_URL ohana://f/{id}/meals/recipes/{id}` opens a link at launch.
                if let link = defaults.string(forKey: "OHANA_DEV_URL"), let url = URL(string: link) {
                    app.open(url)
                }
            }
            #endif
        } else {
            NoFamilyView()
        }
    }

    /// Switches to `target`'s tab, or on iPhone opens what isn't a tab there as a sheet (a page
    /// once the assistant's sheet, which a link may come from, has gone: only one shows).
    private func show(_ target: Module) {
        guard Module.notTabs.contains(target) else {
            module = target
            return
        }
        if target == .assistant {
            showAssistant = true
            return
        }
        guard showAssistant else {
            phonePage = target
            return
        }
        showAssistant = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            phonePage = target
        }
    }

    /// A module's tab; `assistantOn`: the server has the assistant, so the pages get its button.
    private func tab(_ item: Module, assistantOn: Bool) -> some TabContent<Module> {
        Tab(item.title, systemImage: item.systemImage, value: item) {
            page(item, assistantOn: assistantOn)
        }
        // The assistant (a sheet from the toolbar) and the settings (the family picker) live in
        // the sidebar; a compact tab bar (iPad) keeps the modules. On iPhone they aren't tabs.
        .defaultVisibility(item == .assistant || item == .settings ? .hidden : .automatic, for: .tabBar)
        // The settings stand at the sidebar's foot instead (`SidebarSettingsButton`).
        #if os(macOS)
        .hidden(item == .settings)
        #else
        .defaultVisibility(item == .settings ? .hidden : .automatic, for: .sidebar)
        #endif
    }

    /// What a tab shows: the module's root in its navigation stack.
    private func page(_ item: Module, assistantOn: Bool) -> some View {
        NavigationStack {
            item.root
                // Any size: asked for its smallest size after every layout of the window
                // (every step of the assistant panel sliding in), the page would be measured
                // whole. Not around the tab view: framing its AppKit view made the window lay
                // out without end.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .shellToolbar()
                .demoBanner()
        }
        // Not on the assistant's own page (iPad, Mac), nor without the assistant.
        .environment(\.shellAssistant, item == .assistant || !assistantOn ? nil : $showAssistant)
    }
}

/// On iPhone, a page that isn't a tab (`Module.phonePages`): its root in a sheet of its own, with
/// a close button where the tabs' pages have the family button.
private struct PhonePageSheet: View {
    let page: Module
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            page.root
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
                .demoBanner()
        }
        .errorBanner()
    }
}

/// The settings at the foot of the sidebar, below the modules however many there are: a row
/// like the sidebar's own, highlighted while the settings are on screen.
private struct SidebarSettingsButton: View {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(Module.settings.title, systemImage: Module.settings.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                #if os(macOS)
                .padding(.vertical, 6)
                #else
                .padding(.vertical, 11)
                #endif
                .background(
                    .primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0),
                    in: .rect(cornerRadius: 10)
                )
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Notification.Name {
    /// Switches the shell to a module (`object`: a `Module`), e.g. from an overview card.
    static let openModule = Notification.Name("OhanaOpenModule")
}

extension Module {
    /// Shows this module in the shell. Inside a family prefer `family.open(.module(…))` or a
    /// more specific `AppRoute`.
    func open() { NotificationCenter.default.post(name: .openModule, object: self) }
}

extension EnvironmentValues {
    /// The shell's assistant toggle, inside a module's navigation stack (nil elsewhere: sheets
    /// of their own, the assistant's own page).
    @Entry var shellAssistant: Binding<Bool>?
}

/// The assistant beside the modules: an inspector (iPad, Mac), a sheet on iPhone. Not an
/// inspector there too: around the tab view, even closed, it puts the tabs' navigation bars
/// under the status bar.
private struct AssistantPresentation: ViewModifier {
    @Binding var isPresented: Bool
    /// The server has the assistant on; off, the panel never shows (the views stay as they are,
    /// so turning it on or off doesn't rebuild the shell).
    var enabled = true

    /// What the sheet or inspector shows: never while the assistant is off.
    private var shown: Binding<Bool> {
        Binding { enabled && isPresented } set: { isPresented = $0 }
    }

    func body(content: Content) -> some View {
        presentation(content)
            // Here, not in the shell: what reads the state is drawn again when it changes, and the
            // shell holds every module's page.
            .onChange(of: isPresented) { UserDefaults.standard.set(isPresented, forKey: AppShell.assistantOpenKey) }
    }

    @ViewBuilder
    private func presentation(_ content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.sheet(isPresented: shown) {
                AssistantPanel().errorBannerWhenCompact()
            }
        } else {
            inspector(content)
        }
        #else
        inspector(content)
        #endif
    }

    private func inspector(_ content: Content) -> some View {
        content.inspector(isPresented: shown) {
            // Kept while closed, so it opens without being built (and closes without being taken
            // apart) while it slides; closed, it puts no items in the window's toolbar.
            AssistantPanel(visible: enabled && isPresented)
                .errorBannerWhenCompact()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
        }
    }
}

/// The toolbar every module page gets from the shell: the family sidebar's button (on iPhone,
/// where the tab view has no sidebar) and the assistant toggle.
struct ShellToolbar: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .toolbar {
                #if os(iOS)
                if sizeClass == .compact {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Family", systemImage: "sidebar.leading") {
                            withAnimation(.snappy(duration: 0.3)) { app.showsFamilySidebar = true }
                        }
                    }
                }
                #endif
            }
            .assistantButton()
            #if os(iOS)
            // The swipe to the family page waits while a page is pushed over a root.
            .onAppear { app.moduleRootsOnScreen += 1 }
            .onDisappear { app.moduleRootsOnScreen = max(0, app.moduleRootsOnScreen - 1) }
            #endif
    }
}

/// The assistant toggle at the top right. The shell gives it to the module roots; a page pushed
/// onto a module's stack adds it itself (a pushed page has its own toolbar).
struct AssistantButton: ViewModifier {
    @Environment(\.shellAssistant) private var showAssistant

    func body(content: Content) -> some View {
        // From an overlay: toolbar items line up in view order, so the page's own buttons come
        // first and the assistant's is the last at the top right.
        content.overlay {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .toolbar {
                    if let showAssistant {
                        #if os(iOS)
                        ToolbarSpacer(.fixed, placement: .primaryAction)
                        #endif
                        ToolbarItem(placement: .primaryAction) { button(showAssistant) }
                    }
                }
        }
    }

    private func button(_ showAssistant: Binding<Bool>) -> some View {
        Button {
            showAssistant.wrappedValue.toggle()
        } label: {
            Label("Assistant", systemImage: "sparkles")
        }
        .help("Assistant (⌘J)")
    }
}

extension View {
    func shellToolbar() -> some View {
        modifier(ShellToolbar())
    }

    func assistantButton() -> some View {
        modifier(AssistantButton())
    }
}

/// Shown when the account has no family yet: create one, or join one with an invite link
/// (also when the app was opened with one).
struct NoFamilyView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var showAccount = false
    @State private var showAdmin = false
    @State private var joining: InviteRequest?

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No family yet", systemImage: "house")
            } description: {
                Text("Create a family, or join one with the invite link someone sent you.")
            } actions: {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        Button("Create a family") { creating = true }
                            .buttonStyle(.glassProminent)
                        Button("Join a family") { joining = InviteRequest() }
                            .buttonStyle(.glass)
                        Button("Reload") { Task { await app.refresh() } }
                            .buttonStyle(.glass)
                    }
                }
            }
            .background { OhanaBackground() }
            .toolbar {
                if app.me?.isAdmin == true {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Administration", systemImage: "person.badge.shield.checkmark") { showAdmin = true }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Account", systemImage: "person.crop.circle") { showAccount = true }
                }
            }
            .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showAdmin) { AdminSheet() }
            .inviteJoinSheet($joining)
        }
    }
}

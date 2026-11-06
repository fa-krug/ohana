import SwiftUI

/// The frame around a family (the web app's components/shell/app-shell.tsx): the modules as a
/// sidebar in sections (iPad, Mac; a tab bar on a narrow iPad), the family switcher, the search
/// across the modules (its own tab, ⌘K), and the assistant as an inspector on the right, ⌘J. On
/// iPhone there are no tabs: one page at a time, the last one opened (also after the app was
/// closed), with the family page behind it listing every page (`FamilySidebarHost`), and the
/// assistant as a sheet from the Ask Ohana bar at the bottom (`AssistantBar`).
struct AppShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The tab on screen; nil until one is picked: then the scene's last one (`storedModule`).
    /// The tab view's selection is this state, only mirrored to the scene storage: bound to it
    /// directly, the iPhone's tab bar jumps back to the old tab for a moment at every switch.
    @State private var module: Module?
    @SceneStorage("module") private var storedModule: Module = .overview
    /// iPhone: the page on screen, kept across launches (a scene's storage goes when the app is
    /// swiped away).
    @AppStorage("phoneModule") private var phoneModule: Module = .overview
    /// iPhone: the pages opened in this family, kept while another shows, so each is where it was
    /// left (scrolled, pushed), as tabs are.
    @State private var openedPages: [Module] = []

    /// The tab on screen; the overview while the server has its module off (and on iPhone for the
    /// assistant, which isn't a page there).
    private var selection: Binding<Module> {
        Binding {
            let current = module ?? (Module.onPhone ? phoneModule : storedModule)
            return app.isEnabled(current) && !Module.notPages.contains(current) ? current : .overview
        } set: { show($0) }
    }
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
            pages(context, assistantOn: assistantOn)
                .onChange(of: module) {
                    guard let module else { return }
                    storedModule = module
                    if Module.onPhone { phoneModule = module }
                }
            .modifier(AssistantPresentation(isPresented: $showAssistant, enabled: assistantOn))
            #if os(iOS)
            // Where the tab view has no sidebar, and on iPhone: the family page behind the page.
            .modifier(FamilySidebarHost(active: Module.onPhone || sizeClass == .compact,
                                        current: selection.wrappedValue))
            #endif
            // The letter scanner over everything (the family menu, Spotlight / Siri / Shortcuts).
            .modifier(ShellLetterScan(context: context, assistantSheet: $showAssistant))
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
                // The iPhone has no assistant page: it opens as the panel.
                if route.module == .assistant, Module.onPhone || sizeClass == .compact {
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

    /// Switches to `target`'s tab, on iPhone its page (the family page sliding away), or there
    /// opens the assistant's sheet.
    private func show(_ target: Module) {
        if Module.notPages.contains(target) {
            showAssistant = true
            return
        }
        module = target
        if Module.onPhone, app.showsFamilySidebar {
            withAnimation(.snappy(duration: 0.3)) { app.showsFamilySidebar = false }
        }
    }

    /// The pages: on iPhone the one on screen, with the Ask Ohana bar below it; elsewhere the tab
    /// view (a sidebar, or a tab bar on a narrow iPad).
    @ViewBuilder
    private func pages(_ context: FamilyContext, assistantOn: Bool) -> some View {
        if Module.onPhone {
            let current = selection.wrappedValue
            let kept = openedPages.filter { context.isEnabled($0) }
            ZStack {
                ForEach(kept.contains(current) ? kept : kept + [current]) { item in
                    let visible = item == current
                    page(item, assistantOn: assistantOn)
                        .environment(\.shellPageVisible, visible)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .accessibilityHidden(!visible)
                }
            }
            .onChange(of: current, initial: true) {
                if !openedPages.contains(current) { openedPages.append(current) }
            }
            // Not under the settings.
            .assistantBar(context, enabled: assistantOn && current != .settings)
        } else {
            TabView(selection: selection) {
                tab(.overview, assistantOn: assistantOn)
                TabSection("Modules") {
                    ForEach(Module.modules.filter { context.isEnabled($0) }) {
                        tab($0, assistantOn: assistantOn)
                    }
                    #if os(macOS)
                    // Out of the list (see `tab`) but while on screen: then the list's last row.
                    tab(.settings, assistantOn: assistantOn)
                    #endif
                }
                #if os(iOS)
                tab(.settings, assistantOn: assistantOn)
                #endif
                // The sidebar shows it at its top. The Mac has the toolbar's field instead
                // (`ShellSearchField`).
                Tab(value: Module.search, role: .search) {
                    page(.search, assistantOn: assistantOn)
                }
                #if os(macOS)
                .hidden()
                #endif
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewSidebarHeader { FamilySwitcher() }
            .tabViewSidebarBottomBar {
                SidebarSettingsButton(selected: selection.wrappedValue == .settings) { module = .settings }
            }
        }
    }

    /// A module's tab; `assistantOn`: the server has the assistant, so the pages get its button.
    private func tab(_ item: Module, assistantOn: Bool) -> some TabContent<Module> {
        Tab(item.title, systemImage: item.systemImage, value: item) {
            page(item, assistantOn: assistantOn)
        }
        // The assistant (a sheet from the toolbar) and the settings (the family picker) live in
        // the sidebar; a compact tab bar (iPad) keeps the modules.
        .defaultVisibility(item == .assistant || item == .settings ? .hidden : .automatic, for: .tabBar)
        // The settings stand at the sidebar's foot instead (`SidebarSettingsButton`).
        #if os(iOS)
        .defaultVisibility(item == .settings ? .hidden : .automatic, for: .sidebar)
        #else
        // The Mac can't leave a tab out of the sidebar alone, and a `.hidden` tab draws nothing
        // when picked: hidden only while another page is on screen.
        .hidden(item == .settings && selection.wrappedValue != .settings)
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
        // Not on the assistant's own page (iPad, Mac), nor without the assistant, nor on iPhone:
        // the Ask Ohana bar is there instead (`AssistantBar`).
        .environment(\.shellAssistant, item == .assistant || !assistantOn || Module.onPhone
                     ? nil : $showAssistant)
        .environment(\.shellModule, selection)
    }
}

/// The settings at the foot of the sidebar (iPad, Mac), below the modules however many there are:
/// a row like the sidebar's own, highlighted while the settings are on screen.
private struct SidebarSettingsButton: View {
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(Module.settings.title, systemImage: Module.settings.systemImage)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
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
    /// of their own, the assistant's own page, the iPhone's tabs, which have the Ask Ohana bar).
    @Entry var shellAssistant: Binding<Bool>?
    /// The shell's page on screen, inside a module's navigation stack (nil elsewhere): on the Mac
    /// every page there gets the search field (`ShellSearchField`).
    @Entry var shellModule: Binding<Module>?
    /// False for a page the iPhone keeps while another shows (`AppShell.openedPages`).
    @Entry var shellPageVisible = true
}

/// The assistant beside the modules: an inspector (iPad, Mac), a sheet on iPhone. Not an
/// inspector there too: around the page, even closed, it puts its navigation bar under the
/// status bar.
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

/// The toolbar every module page gets from the shell: the way to the family page (iPhone: back
/// to it; a narrow iPad, where the tab view has no sidebar: its sidebar button) and the assistant
/// toggle (not on iPhone).
struct ShellToolbar: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.shellPageVisible) private var visible
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                #if os(iOS)
                if Module.onPhone {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.snappy(duration: 0.3)) { app.showsFamilySidebar = true }
                        } label: {
                            Label { Text(verbatim: "Ohana") } icon: { Image(systemName: "chevron.backward") }
                        }
                    }
                } else if sizeClass == .compact {
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
            // The swipe to the family page waits while a page is pushed over a root (a kept page
            // the iPhone hides doesn't count).
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
            .onChange(of: appeared && visible) { _, onScreen in
                app.moduleRootsOnScreen = max(0, app.moduleRootsOnScreen + (onScreen ? 1 : -1))
            }
            #endif
    }
}

/// The assistant toggle at the top right (`AssistantToolbarToggle`; none where `shellAssistant` is
/// nil, as on iPhone); on the Mac right of it the search across the modules
/// (`ShellSearchField`), the page's own items left of both. The shell gives them to the module
/// roots; a page pushed onto a module's stack adds them itself (a pushed page has its own toolbar).
struct AssistantButton: ViewModifier {
    @Environment(\.shellAssistant) private var showAssistant
    @Environment(\.shellModule) private var module

    func body(content: Content) -> some View {
        // From an overlay: toolbar items line up in view order, so the page's own buttons come
        // first, then the assistant's, then (Mac) the search field at the top right.
        content
            .overlay {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .toolbar {
                        if let showAssistant {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                            ToolbarItem(placement: .primaryAction) { AssistantToolbarToggle(isOpen: showAssistant) }
                        }
                        #if os(macOS)
                        if let module {
                            // Its own capsule, not one with the assistant's button.
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                            ToolbarItem(placement: .primaryAction) { ShellSearchField(module: module) }
                        }
                        #endif
                    }
            }
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
                    Button("Account", systemImage: "person") { showAccount = true }
                }
            }
            .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showAdmin) { AdminSheet() }
            .inviteJoinSheet($joining)
        }
    }
}

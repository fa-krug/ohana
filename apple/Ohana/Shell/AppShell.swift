import SwiftUI

/// The frame around a family (the web app's components/shell/app-shell.tsx): the modules as a
/// sidebar in sections (iPad, Mac; a tab bar on a narrow iPad), the family switcher, the search
/// across the modules (its own tab, ⌘K), and the assistant: a round button at the bottom right
/// of every page opening it (⌘J) as a panel floating over the page, a sheet on iPhone
/// (`AssistantFloating`). On iPhone there are no tabs: a split view collapsed into one stack, the
/// family page listing every page with the page on screen pushed over it, the last one opened
/// (also after the app was closed; `PhoneShell`).
struct AppShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(macOS)
    /// The Mac's settings are a window (`SettingsWindow`).
    @Environment(\.openSettings) private var openSettings
    #endif
    /// The tab on screen; nil until one is picked: then the scene's last one (`storedModule`).
    /// The tab view's selection is this state, only mirrored to the scene storage: bound to it
    /// directly, the iPhone's tab bar jumps back to the old tab for a moment at every switch.
    @State private var module: Module?
    @SceneStorage("module") private var storedModule: Module = .overview
    /// iPhone: the page on screen, kept across launches (a scene's storage goes when the app is
    /// swiped away).
    @AppStorage("phoneModule") private var phoneModule: Module = .overview
    /// At launch the loading screen stays over the shell while the pages are built
    /// (`prebuildPages`), so none has to be built when it's first opened.
    @State private var launchLoading = !AppShell.launchBuilt
    /// iPad, Mac: the tab a route or a tap asked for while the launch built the tabs.
    @State private var tabAfterLaunch: Module?
    /// Mac: the window's toolbar while the launch builds the tabs (each tab's items would flash by).
    @State private var launchToolbarHidden = !AppShell.launchBuilt
    /// The pages were built at launch: later shells (another family, another server) build theirs
    /// when opened.
    private static var launchBuilt = false

    /// The tab on screen; the overview while the server has its module off (and on iPhone for the
    /// assistant, which isn't a page there).
    private var selection: Binding<Module> {
        Binding {
            let current = module ?? (Module.onPhone ? phoneModule : storedModule)
            return app.isEnabled(current) && !Module.notPages.contains(current) && !current.isWindow && !current.isAction ? current : .overview
        } set: { show($0) }
    }
    /// The pages' stores, kept while the shell shows the family (`ShellPageStores`).
    @State private var pageStores = ShellPageStores()
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
            // The launch's loading screen, until the pages are built.
            .overlay {
                // There from the first frame (the root's own loading screen fades into the shell):
                // faded in, the pages showed through for a moment.
                if launchLoading { LoadingScreen().transition(.asymmetric(insertion: .identity, removal: .opacity)) }
            }
            #if os(macOS)
            .toolbar(launchToolbarHidden ? .hidden : .automatic, for: .windowToolbar)
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
            .environment(\.pageStores, pageStores)
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

    /// Switches to `target`'s tab, on iPhone its page (pushed over the family page), or there
    /// opens the assistant's sheet.
    private func show(_ target: Module) {
        // Mac: the sidebar's "Scan letter" row; the page on screen stays.
        if target == .scanLetter {
            if let family = app.selectedFamily { app.context(for: family)?.scanLetter() }
            return
        }
        #if os(macOS)
        // A route to a settings page stays pending: the window's view takes it.
        if target.isWindow {
            openSettings()
            return
        }
        #endif
        if Module.notPages.contains(target) {
            showAssistant = true
            return
        }
        // The launch is going through the tabs: this one once it's done.
        if launchLoading, !Module.onPhone { tabAfterLaunch = target }
        module = target
        if Module.onPhone { app.showsFamilySidebar = false }
    }

    /// iPad, Mac: the tabs that weren't opened yet, built ahead behind the loading screen at launch
    /// (each takes a few hundred milliseconds, and built when first opened it showed a blank page or
    /// a spinner): each tab picked for a moment (a tab view builds a tab only when it's picked, and
    /// keeps it), then the one to show. Not the search page or the assistant's: they take the keyboard
    /// on appearing. Later shells (another family, another server) build theirs when opened. On
    /// iPhone only the page on screen is built (the split view has one).
    private func prebuildPages(_ context: FamilyContext) async {
        guard launchLoading else { return }
        AppShell.launchBuilt = true
        // The loading screen drawn first.
        try? await Task.sleep(for: .milliseconds(16))
        if !Module.onPhone {
            let pages = ([.overview] + Module.modules + [.settings])
                .filter { !Module.notPages.contains($0) && !$0.isWindow && context.isEnabled($0) }
            let start = selection.wrappedValue
            for page in pages where page != start && page != .assistant {
                guard !Task.isCancelled else { break }
                module = page
                try? await Task.sleep(for: .milliseconds(16))
            }
            module = tabAfterLaunch ?? start
            tabAfterLaunch = nil
        }
        // The last one drawn and the toolbar back (laid out under the loading screen), then the
        // pages show.
        launchToolbarHidden = false
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.smooth(duration: 0.3)) { launchLoading = false }
    }

    /// The pages: on iPhone the one on screen over the family page (the assistant's button floating
    /// on it, `ShellPageItems`); elsewhere the tab view (a sidebar, or a tab bar on a narrow iPad), each
    /// page with the button over it.
    @ViewBuilder
    private func pages(_ context: FamilyContext, assistantOn: Bool) -> some View {
        if Module.onPhone {
            #if os(iOS)
            PhoneShell(current: selection.wrappedValue, open: show) { item in
                page(item, assistantOn: assistantOn)
            }
            .task { await prebuildPages(context) }
            #endif
        } else {
            TabView(selection: selection) {
                tab(.overview, assistantOn: assistantOn)
                TabSection("Modules") {
                    ForEach(Module.modules.filter { context.isEnabled($0) && !Self.ownSection.contains($0) }) {
                        tab($0, assistantOn: assistantOn)
                    }
                }
                #if os(macOS)
                // The assistant and scanning a letter, a section of their own below the modules.
                TabSection("Tools") {
                    ForEach(Self.ownSection.filter { context.isEnabled($0) }) {
                        tab($0, assistantOn: assistantOn)
                    }
                    // A tab only for its row (`sectionActions` draw nothing on the Mac): picking it
                    // opens the scanner (`show`), never its page.
                    Tab(Module.scanLetter.title, systemImage: Module.scanLetter.systemImage, value: Module.scanLetter) {
                        Color.clear
                    }
                }
                #endif
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
            #if os(iOS)
            .tabViewSidebarBottomBar {
                SidebarSettingsButton(selected: selection.wrappedValue == .settings) { module = .settings }
            }
            #else
            .tabViewSidebarBottomBar {
                MacSidebarFooter { openSettings() }
            }
            #endif
            .task { await prebuildPages(context) }
        }
    }

    /// The Mac's sidebar has the assistant in a section of its own, with scanning a letter.
    private static var ownSection: [Module] {
        #if os(macOS)
        [.assistant]
        #else
        []
        #endif
    }

    /// A module's tab; `assistantOn`: the server has the assistant, so the pages get its button.
    private func tab(_ item: Module, assistantOn: Bool) -> some TabContent<Module> {
        Tab(item.title, systemImage: item.systemImage, value: item) {
            page(item, assistantOn: assistantOn)
        }
        // The assistant (a sheet from the toolbar) and the settings (the family picker) live in
        // the sidebar; a compact tab bar (iPad) keeps the modules.
        .defaultVisibility(item == .assistant || item == .settings ? .hidden : .automatic, for: .tabBar)
        // The settings stand at the sidebar's foot instead (`SidebarSettingsButton`); the Mac has
        // no settings tab (a window, `SettingsWindow`, opened from its sidebar's foot,
        // `MacSidebarFooter`).
        #if os(iOS)
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
        .environment(\.shellModule, selection)
        // iPhone: on each page (`ShellPageItems`), so it stays above a page's own bottom bar.
        .environment(\.shellAssistant, assistantOn && Module.onPhone ? $showAssistant : nil)
        // Here, inside the tab, so a narrow iPad's tab bar stays clear. Not on the assistant's own
        // page.
        .assistantFloatingButton(isOpen: $showAssistant,
                                 enabled: assistantOn && item != .assistant && !Module.onPhone)
    }
}

#if os(iOS)
/// The settings at the foot of the iPad's sidebar, below the modules however many there are: a
/// row like the sidebar's own, highlighted while the settings are on screen.
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
                .padding(.vertical, 11)
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
#endif

#if os(macOS)
/// The foot of the Mac's sidebar, below the modules: the settings window (⌘,), a quiet row in
/// the secondary color.
private struct MacSidebarFooter: View {
    let openSettings: () -> Void

    var body: some View {
        Button(action: openSettings) {
            Label(Module.settings.title, systemImage: Module.settings.systemImage)
                // The bar shows icons only otherwise.
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(BarDividerHider())
    }
}

/// Takes away the line SwiftUI draws above the sidebar's bottom bar (a 1 pt layer of the bar's
/// container; no modifier turns it off, `scrollEdgeEffectStyle` / `Hidden` don't reach it), so the
/// settings sit in the sidebar as in the system's apps. Should the container change, the line simply
/// shows again.
private struct BarDividerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HiderView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? HiderView)?.hideSoon() }

    private final class HiderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hideSoon()
        }

        override func layout() {
            super.layout()
            hideSoon()
        }

        func hideSoon() {
            DispatchQueue.main.async { [weak self] in self?.hide() }
        }

        private func hide() {
            var view = superview
            while let current = view, !NSStringFromClass(type(of: current)).contains("PocketContainer") {
                view = current.superview
            }
            guard let container = view, let layers = container.layer?.sublayers else { return }
            let viewLayers = Set(container.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
            for layer in layers where !viewLayers.contains(ObjectIdentifier(layer))
                && layer.bounds.height <= 1 && layer.frame.minY <= 1 && !layer.isHidden {
                layer.isHidden = true
            }
        }
    }
}
#endif

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
    /// iPhone: the shell's assistant sheet, for the button floating on every page (nil elsewhere,
    /// and without the assistant).
    @Entry var shellAssistant: Binding<Bool>?
    /// The shell's page on screen, inside a module's navigation stack (nil elsewhere): on the Mac
    /// every page there gets the search field (`ShellSearchField`).
    @Entry var shellModule: Binding<Module>?
    /// False while the iPhone's family page covers the page (`PhoneShell`).
    @Entry var shellPageVisible = true
    /// The shell's keeper of the pages' stores (nil outside a shell).
    @Entry var pageStores: ShellPageStores?
}

/// The stores pages make for themselves (the calendar's, finance's), kept by the shell while it
/// shows the family: a page built again (on iPhone each page opened after another; the split view
/// has only the one on screen) finds what it showed, the year, the selection, the filters, and
/// refreshes it quietly instead of starting empty. Per family context (a newer context of the family
/// gets new ones); gone with the shell.
final class ShellPageStores {
    private var stores: [String: AnyObject] = [:]

    /// The `S` kept for `family`, made with `make` the first time.
    func store<S: AnyObject>(for family: FamilyContext, make: () -> S) -> S {
        let key = "\(ObjectIdentifier(S.self).hashValue)-\(ObjectIdentifier(family).hashValue)"
        if let store = stores[key] as? S { return store }
        let store = make()
        stores[key] = store
        return store
    }
}

/// The assistant over the modules: a panel floating at the right of the page (iPad, Mac), a sheet
/// on iPhone and a narrow iPad (`AssistantFloating`). Both are always there, so a size class change
/// doesn't rebuild the shell.
private struct AssistantPresentation: ViewModifier {
    @Binding var isPresented: Bool
    /// The server has the assistant on; off, the panel never shows (the views stay as they are,
    /// so turning it on or off doesn't rebuild the shell).
    var enabled = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Floating over the page, rather than a sheet.
    private var floats: Bool {
        #if os(iOS)
        !Module.onPhone && sizeClass != .compact
        #else
        true
        #endif
    }

    private var sheet: Binding<Bool> {
        Binding { !floats && enabled && isPresented } set: { isPresented = $0 }
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if floats { AssistantFloatingPanel(isOpen: enabled && isPresented) }
            }
            .sheet(isPresented: sheet) {
                AssistantPanel().errorBannerWhenCompact()
            }
            // Here, not in the shell: what reads the state is drawn again when it changes, and the
            // shell holds every module's page.
            .onChange(of: isPresented) { UserDefaults.standard.set(isPresented, forKey: AppShell.assistantOpenKey) }
    }
}

/// The toolbar every module page gets from the shell: on a narrow iPad, where the tab view has no
/// sidebar, the family menu (`FamilyPickerButton`, with the settings: the tab bar leaves them out);
/// on the Mac the search field at its end. (On iPhone the split view's back button goes to the family
/// page.)
struct ShellToolbar: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .toolbar {
                #if os(iOS)
                if !Module.onPhone, sizeClass == .compact {
                    ToolbarItem(placement: .topBarLeading) {
                        FamilyPickerButton(showsSettings: true) {
                            Label("Family", systemImage: "sidebar.leading")
                        }
                    }
                }
                #endif
            }
            .shellPageItems()
    }
}

/// What the shell adds to every page: on the Mac the search across the modules at its toolbar's end
/// (`ShellSearchField`), the page's own items left of it; on iPhone the assistant's round button
/// floating at the bottom right (`AssistantFloatingButton`; not in a bottom toolbar, whose scroll
/// edge effect dimmed a tall band of the page). The shell gives them to the module roots; a page
/// pushed onto a module's stack adds them itself (a pushed page has its own toolbar).
struct ShellPageItems: ViewModifier {
    @Environment(\.shellModule) private var module
    @Environment(\.shellAssistant) private var showAssistant

    func body(content: Content) -> some View {
        // From an overlay: toolbar items line up in view order, so the page's own buttons come
        // first, then the shell's.
        content
            .overlay {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .toolbar {
                        #if os(macOS)
                        if let module {
                            ToolbarSpacer(.fixed, placement: .primaryAction)
                            ToolbarItem(placement: .primaryAction) { ShellSearchField(module: module) }
                        }
                        #endif
                    }
            }
            #if os(iOS)
            .assistantFloatingButton(isOpen: showAssistant ?? .constant(false), enabled: showAssistant != nil)
            #endif
    }
}

extension View {
    func shellToolbar() -> some View {
        modifier(ShellToolbar())
    }

    func shellPageItems() -> some View {
        modifier(ShellPageItems())
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

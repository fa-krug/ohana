import SwiftUI

/// The frame around a family (the web app's components/shell/app-shell.tsx): the modules as a
/// sidebar (iPad, Mac) or a floating Liquid Glass tab bar (iPhone), the family switcher, and
/// the assistant as an inspector on the right (a sheet on iPhone), ⌘J.
struct AppShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("module") private var module: Module = .overview
    @SceneStorage("assistant") private var showAssistant = false

    var body: some View {
        @Bindable var app = app
        if let family = app.selectedFamily, let context = app.context(for: family) {
            TabView(selection: $module) {
                ForEach(Module.allCases) { item in
                    Tab(item.title, systemImage: item.systemImage, value: item) {
                        NavigationStack {
                            item.root
                                .shellToolbar()
                                .demoBanner()
                        }
                        // Not on the assistant's own page (iPad, Mac).
                        .environment(\.shellAssistant, item == .assistant ? nil : $showAssistant)
                    }
                    // The assistant (a sheet from the toolbar) and the settings (the family menu)
                    // live in the sidebar; the iPhone's tab bar keeps the five modules.
                    .defaultVisibility(item == .settings || item == .assistant ? .hidden : .automatic, for: .tabBar)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewSidebarHeader { FamilySwitcher() }
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            #endif
            .modifier(AssistantPresentation(isPresented: $showAssistant))
            .environment(context)
            .id(family.id)
            .focusedSceneValue(\.shell, ShellFocus(module: $module, assistant: $showAssistant) {
                context.ask(newChat: true)
            })
            .onChange(of: context.assistantRequest?.id) {
                guard context.assistantRequest != nil else { return }
                // The assistant's page takes the request itself when it's on screen.
                if module == .assistant, sizeClass != .compact { return }
                showAssistant = true
            }
            .onChange(of: AssistantInbox.shared.pending?.id, initial: true) {
                // "Ask Ohana" from Siri, Shortcuts or Spotlight.
                guard let pending = AssistantInbox.shared.take() else { return }
                context.ask(pending.prompt, send: pending.prompt != nil, newChat: true)
            }
            .sheet(isPresented: $app.showsConnect) { ConnectServerView().errorBanner() }
            .onReceive(NotificationCenter.default.publisher(for: .openModule)) { note in
                if let target = note.object as? Module { module = target }
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
                module = route.module
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
                if let name = defaults.string(forKey: "OHANA_DEV_MODULE"), let target = Module(rawValue: name) {
                    module = target
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

    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.sheet(isPresented: $isPresented) {
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
        content.inspector(isPresented: $isPresented) {
            // Only while shown: a hidden inspector's toolbar items would stay in the window's.
            if isPresented {
                AssistantPanel()
                    .errorBannerWhenCompact()
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
            }
        }
    }
}

/// The toolbar every module page gets from the shell: the family menu (on iPhone, where there is
/// no sidebar) and the assistant toggle.
struct ShellToolbar: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .toolbar {
                #if os(iOS)
                if sizeClass == .compact {
                    ToolbarItem(placement: .topBarLeading) { FamilyMenu() }
                }
                #endif
            }
            .assistantButton()
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
                        Button("Join a family…") { joining = InviteRequest() }
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
                    #if os(macOS)
                    SettingsLink { Label("Account", systemImage: "person.crop.circle") }
                    #else
                    Button("Account", systemImage: "person.crop.circle") { showAccount = true }
                    #endif
                }
            }
            .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showAdmin) { AdminSheet() }
            .inviteJoinSheet($joining)
        }
    }
}

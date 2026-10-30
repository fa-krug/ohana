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
                                .shellToolbar(showAssistant: $showAssistant, assistantButton: item != .assistant)
                                .demoBanner()
                        }
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
            // "Ask Ohana" floats above the iPhone's tab bar on every page.
            .tabViewBottomAccessory { ShellQuickAsk(context: context) }
            #endif
            .inspector(isPresented: $showAssistant) {
                // Only while shown: a hidden inspector's toolbar items would stay in the window's.
                if showAssistant {
                    AssistantPanel()
                        .errorBannerWhenCompact()
                        .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
                }
            }
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

/// The toolbar every module page gets from the shell: the family menu (on iPhone, where there is
/// no sidebar) and the assistant toggle.
struct ShellToolbar: ViewModifier {
    @Binding var showAssistant: Bool
    /// False on the assistant's own page.
    var assistantButton = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar {
            #if os(iOS)
            if sizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) { FamilyMenu() }
            }
            #endif
            if assistantButton {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAssistant.toggle()
                } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .help("Assistant (⌘J)")
            }
            }
            #if os(iOS)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            #endif
        }
    }
}

extension View {
    func shellToolbar(showAssistant: Binding<Bool>, assistantButton: Bool = true) -> some View {
        modifier(ShellToolbar(showAssistant: showAssistant, assistantButton: assistantButton))
    }
}

/// The "Ask Ohana" bar above the iPhone's tab bar: one tap to a new chat, ready to type.
#if os(iOS)
struct ShellQuickAsk: View {
    let context: FamilyContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button {
            context.ask(newChat: true)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(ModuleTint.assistant)
                Text(placement == .inline ? "Ask" : "Ask Ohana…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask the assistant")
    }
}
#endif

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

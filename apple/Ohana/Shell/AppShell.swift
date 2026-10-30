import SwiftUI

/// The frame around a family (the web app's components/shell/app-shell.tsx): the modules as a
/// sidebar (iPad, Mac) or a floating Liquid Glass tab bar (iPhone), the family switcher, and
/// the assistant as an inspector on the right (a sheet on iPhone), ⌘J.
struct AppShell: View {
    @Environment(AppModel.self) private var app
    @SceneStorage("module") private var module: Module = .overview
    @SceneStorage("assistant") private var showAssistant = false

    var body: some View {
        if let family = app.selectedFamily, let context = app.context(for: family) {
            TabView(selection: $module) {
                ForEach(Module.allCases) { item in
                    Tab(item.title, systemImage: item.systemImage, value: item) {
                        NavigationStack {
                            item.root
                                .shellToolbar(showAssistant: $showAssistant)
                        }
                    }
                    // Settings live in the sidebar and the family menu; the iPhone's tab bar
                    // keeps the five modules.
                    .defaultVisibility(item == .settings ? .hidden : .automatic, for: .tabBar)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabViewSidebarHeader { FamilySwitcher() }
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            #endif
            .inspector(isPresented: $showAssistant) {
                AssistantPanel()
                    .errorBanner()
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
            }
            .environment(context)
            .id(family.id)
            .focusedSceneValue(\.shell, ShellFocus(module: $module, assistant: $showAssistant))
            .onReceive(NotificationCenter.default.publisher(for: .openModule)) { note in
                if let target = note.object as? Module { module = target }
            }
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
    /// Shows this module in the shell.
    func open() { NotificationCenter.default.post(name: .openModule, object: self) }
}

/// The toolbar every module page gets from the shell: the family menu (on iPhone, where there is
/// no sidebar) and the assistant toggle.
struct ShellToolbar: ViewModifier {
    @Binding var showAssistant: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbar {
            #if os(iOS)
            if sizeClass == .compact {
                ToolbarItem(placement: .topBarLeading) { FamilyMenu() }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAssistant.toggle()
                } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .help("Assistant (⌘J)")
            }
            #if os(iOS)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            #endif
        }
    }
}

extension View {
    func shellToolbar(showAssistant: Binding<Bool>) -> some View {
        modifier(ShellToolbar(showAssistant: showAssistant))
    }
}

/// Shown when the account has no family yet.
struct NoFamilyView: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("No family yet", systemImage: "house")
            } description: {
                Text("Create a family, or ask someone to invite you to theirs.")
            } actions: {
                Button("Create a family") { creating = true }
                    .buttonStyle(.glassProminent)
                Button("Reload") { Task { await app.refresh() } }
                    .buttonStyle(.glass)
            }
            .background { OhanaBackground() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Account", systemImage: "person.crop.circle") { showAccount = true }
                }
            }
            .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
            .sheet(isPresented: $showAccount) { NavigationStack { AccountView() }.errorBanner() }
        }
    }
}

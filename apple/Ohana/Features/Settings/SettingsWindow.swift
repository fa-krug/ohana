#if os(macOS)
import SwiftUI

/// The Mac's settings: a window of their own (⌘,, the app's Settings scene) with a sidebar like the
/// system's Settings, rather than a page of the main window's sidebar. The sidebar holds what the
/// iPhone's and iPad's settings page lists (`FamilySettingsForm`): the account, the selected family's
/// pages, the modules' settings, this device's and, for administrators, the server's; the detail its
/// page. It follows the family the main window shows. Routes to a settings page
/// (`family.open(.settings(.knowledge))`) open this window (`AppShell.show`) and pick the page here.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Group {
            if app.switching == nil, app.phase == .ready, let family = app.selectedFamily,
               let context = app.context(for: family) {
                SettingsSplitView()
                    .environment(context)
                    .id(family.id)
            } else if app.switching == nil, app.phase == .ready {
                ContentUnavailableView("No family yet", systemImage: "house",
                                       description: Text("Create a family, or join one with the invite link someone sent you."))
            } else {
                LoadingScreen()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .errorBanner()
        .tint(.ohana)
        .preferredColorScheme(appearance.colorScheme)
    }
}

/// What the settings window's sidebar picks.
private enum SettingsSidebarItem: Hashable {
    case account
    case page(SettingsPage)
    case administration
}

private struct SettingsSplitView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @State private var model = FamilySettingsModel()
    @State private var selection: SettingsSidebarItem? = .page(.general)
    /// The pages opened inside the picked one (a route to the assistant's memory, the family's data).
    @State private var path: [SettingsPage] = []

    var body: some View {
        NavigationSplitView {
            sidebar
                // The settings window's split view keeps its sidebar narrow without a width of the
                // list's own (the column width alone left the rows cut off).
                .frame(minWidth: 230)
                .navigationSplitViewColumnWidth(min: 230, ideal: 240, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: SettingsPage.self) { page in
                        FamilySettingsPageView(page: page, model: model).id(page)
                    }
            }
            .id(selection)
        }
        // The household, for the pages, before one opens.
        .task(id: [family.revision(.family), family.revision(.settings)]) { await model.load(family.api) }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .settings),
                  let page = FamilySettingsPageView.page(for: route) else { return }
            open(page)
        }
    }

    /// The sidebar's selection: picking a row starts its page afresh.
    private var sidebarSelection: Binding<SettingsSidebarItem?> {
        Binding { selection } set: {
            selection = $0
            path = []
        }
    }

    /// A route's page: one the sidebar lists picked, one inside another opened on it.
    private func open(_ page: SettingsPage) {
        switch page {
        case .assistantMemory:
            selection = .page(.assistant)
            path = [page]
        case .data:
            selection = .page(.general)
            path = [page]
        default:
            selection = .page(page)
            path = []
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                accountRow.tag(SettingsSidebarItem.account)
            }

            Section {
                row(.general, "General", systemImage: "gearshape.fill", tint: .gray)
                row(.members, "Members", systemImage: "person.2.fill", tint: .ohana)
                row(.home, "Home address", systemImage: "house.fill", tint: .indigo)
                row(.notifications, "Notifications", systemImage: "bell.badge.fill", tint: .red)
            } header: {
                Text(verbatim: app.selectedFamily?.name ?? family.family.name)
            }

            Section("Modules") {
                row(.calendar, "Calendar", systemImage: Module.calendar.systemImage, tint: ModuleTint.calendar)
                if family.isEnabled(.finance) {
                    row(.finance, "Finance", systemImage: Module.finance.systemImage, tint: ModuleTint.finance)
                }
                if family.isEnabled(.meals), !app.isDemo {
                    row(.shopping, "Shopping List", systemImage: "checklist", tint: ModuleTint.meals)
                }
                if family.isEnabled(.chores) {
                    row(.chores, "Chores", systemImage: Module.chores.systemImage, tint: ModuleTint.chores)
                }
                if family.isEnabled(.assistant) {
                    row(.assistant, "Assistant", systemImage: "sparkles", tint: ModuleTint.assistant)
                }
                if family.knowledgeAvailable {
                    row(.knowledge, "Knowledge", systemImage: "books.vertical.fill", tint: ModuleTint.knowledge)
                }
            }

            Section {
                row(.device, "This device", systemImage: "desktopcomputer", tint: .blue)
            }

            if app.me?.isAdmin == true, !app.isDemo {
                Section("Server") {
                    label("Administration", systemImage: "person.badge.shield.checkmark", tint: .indigo)
                        .tag(SettingsSidebarItem.administration)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ page: SettingsPage, _ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        label(title, systemImage: systemImage, tint: tint).tag(SettingsSidebarItem.page(page))
    }

    private func label(_ title: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            TintedIcon(systemImage: systemImage, tint: tint, size: 22)
        }
    }

    /// Who is signed in (in the demo: that it is one), as the system's Settings shows the account.
    private var accountRow: some View {
        HStack(spacing: 10) {
            if app.isDemo {
                TintedIcon(systemImage: "sparkles.rectangle.stack", tint: .ohana, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Demo data").font(.headline)
                    Text("No server connected").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TintedIcon(systemImage: "person.fill", tint: .ohana, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.me?.displayName ?? "").font(.headline).lineLimit(1)
                    Text("Account, sign-in and security").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .account:
            AccountPageView()
        case let .page(page):
            FamilySettingsPageView(page: page, model: model)
        case .administration:
            AdminView()
        case nil:
            ContentUnavailableView("Settings", systemImage: Module.settings.systemImage)
        }
    }
}
#endif

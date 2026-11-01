import SwiftUI

/// The pages of the shell, in sidebar order (the web app's components/shell/modules.ts plus
/// the overview, the assistant's own page and the settings), and the search across them (its
/// own tab, ⌘K; last, so the others keep their ⌘-numbers).
enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview, calendar, finance, meals, appointments, assistant, settings, search

    /// The sidebar's "Modules" section; the overview stands above it, the settings at its foot.
    static let modules: [Module] = [.calendar, .finance, .meals, .appointments, .assistant]

    var id: String { rawValue }

    /// The pages that aren't tabs on iPhone, whose tab bar holds five (the overview, three
    /// modules and the search): sheets opened from the family page (`FamilySidebarHost`).
    static var phonePages: [Module] {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? [.appointments, .settings] : []
        #else
        []
        #endif
    }

    /// What isn't a tab on iPhone: those pages, and the assistant (a sheet there).
    static var notTabs: [Module] {
        phonePages.isEmpty ? [] : phonePages + [.assistant]
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .finance: "Finance"
        case .meals: "Meals"
        case .appointments: "Appointments"
        case .assistant: "Assistant"
        case .settings: "Settings"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .calendar: "calendar"
        case .finance: "banknote"
        case .meals: "fork.knife"
        case .appointments: "stethoscope"
        case .assistant: "sparkles"
        case .settings: "gearshape"
        case .search: "magnifyingglass"
        }
    }

    var tint: Color {
        switch self {
        case .overview: ModuleTint.overview
        case .calendar: ModuleTint.calendar
        case .finance: ModuleTint.finance
        case .meals: ModuleTint.meals
        case .appointments: ModuleTint.appointments
        case .assistant: ModuleTint.assistant
        case .settings: ModuleTint.settings
        case .search: ModuleTint.overview
        }
    }

    /// ⌘1 … ⌘7
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(Module.allCases.firstIndex(of: self)! + 1)")) }

    @ViewBuilder var root: some View {
        switch self {
        case .overview: OverviewView()
        case .calendar: CalendarView()
        case .finance: FinanceView()
        case .meals: MealsView()
        case .appointments: AppointmentsView()
        case .assistant: AssistantPage()
        case .settings: FamilySettingsView()
        case .search: FamilySearchView()
        }
    }
}

/// The shell's state the menu commands reach (macOS menu bar, iPad keyboard shortcuts).
struct ShellFocus {
    var module: Binding<Module>
    var assistant: Binding<Bool>
    /// The modules the server has on, in `Module.allCases` order (the Go menu's).
    var modules: [Module] = Module.allCases
    /// Opens the assistant on a new chat, ready to type.
    var ask: () -> Void = {}
    /// Opens the search, ready to type.
    var search: () -> Void = {}
}

/// The visible module's "New …" (File ▸ New …, ⌘N). A module sets it with
/// `.focusedSceneValue(\.newItem, NewItemAction(title: "New Recipe") { … })`.
struct NewItemAction {
    var title: LocalizedStringKey
    var action: () -> Void
}

/// The visible module's own menu in the menu bar (and the iPad's ⌘-hold shortcut list): its
/// commands as buttons, with ⌘-shortcuts where they have one. A module sets it with
/// `.focusedSceneValue(\.moduleMenu, ModuleMenu(title: "Calendar") { Button(…) … })`.
struct ModuleMenu {
    var title: LocalizedStringKey
    var content: () -> AnyView

    init<Content: View>(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = { AnyView(content()) }
    }
}

extension FocusedValues {
    @Entry var shell: ShellFocus?
    @Entry var newItem: NewItemAction?
    @Entry var moduleMenu: ModuleMenu?
}

struct ShellCommands: Commands {
    @FocusedValue(\.shell) private var shell
    @FocusedValue(\.newItem) private var newItem
    @FocusedValue(\.moduleMenu) private var moduleMenu
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button(newItem?.title ?? "New") { newItem?.action() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newItem == nil)
            Button("New Window") { openWindow(id: OhanaApp.mainWindow) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        if let moduleMenu {
            CommandMenu(moduleMenu.title) { moduleMenu.content() }
        }
        CommandMenu("Go") {
            // The modules the server has on; each keeps its ⌘-number.
            ForEach((shell?.modules ?? Module.allCases).filter { $0 != .search }) { module in
                Button(module.title) { shell?.module.wrappedValue = module }
                    .keyboardShortcut(module.shortcut, modifiers: .command)
            }
            Divider()
            Button("Search") { shell?.search() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(shell == nil)
            if shell?.modules.contains(.assistant) ?? true {
                Divider()
                Button("Assistant panel") { shell?.assistant.wrappedValue.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Ask the assistant") { shell?.ask() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
        }
        // The settings (the account's among them) are a page of the sidebar, not a window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { shell?.module.wrappedValue = .settings }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(shell == nil)
        }
    }
}

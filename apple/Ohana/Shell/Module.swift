import SwiftUI

/// The sections of a family, in sidebar order (the web app's components/shell/modules.ts plus
/// the overview, the assistant's own page and the family's settings).
enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview, calendar, finance, meals, appointments, assistant, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .finance: "Finance"
        case .meals: "Meals"
        case .appointments: "Appointments"
        case .assistant: "Assistant"
        case .settings: "Settings"
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
        }
    }
}

/// The shell's state the menu commands reach (macOS menu bar, iPad keyboard shortcuts).
struct ShellFocus {
    var module: Binding<Module>
    var assistant: Binding<Bool>
    /// Opens the assistant on a new chat, ready to type.
    var ask: () -> Void = {}
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
            ForEach(Module.allCases) { module in
                Button(module.title) { shell?.module.wrappedValue = module }
                    .keyboardShortcut(module.shortcut, modifiers: .command)
            }
            Divider()
            Button("Assistant panel") { shell?.assistant.wrappedValue.toggle() }
                .keyboardShortcut("j", modifiers: .command)
            Button("Ask the assistant") { shell?.ask() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
        }
    }
}

import SwiftUI

/// The sections of a family, in sidebar order (the web app's components/shell/modules.ts plus
/// the overview and the family's settings).
enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview, calendar, finance, meals, appointments, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .finance: "Finance"
        case .meals: "Meals"
        case .appointments: "Appointments"
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
        case .settings: ModuleTint.settings
        }
    }

    /// ⌘1 … ⌘6
    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(Module.allCases.firstIndex(of: self)! + 1)")) }

    @ViewBuilder var root: some View {
        switch self {
        case .overview: OverviewView()
        case .calendar: CalendarView()
        case .finance: FinanceView()
        case .meals: MealsView()
        case .appointments: AppointmentsView()
        case .settings: FamilySettingsView()
        }
    }
}

/// The shell's state the menu commands reach (macOS menu bar, iPad keyboard shortcuts).
struct ShellFocus {
    var module: Binding<Module>
    var assistant: Binding<Bool>
}

extension FocusedValues {
    @Entry var shell: ShellFocus?
}

struct ShellCommands: Commands {
    @FocusedValue(\.shell) private var shell

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Module.allCases) { module in
                Button(module.title) { shell?.module.wrappedValue = module }
                    .keyboardShortcut(module.shortcut, modifiers: .command)
            }
            Divider()
            Button("Assistant") { shell?.assistant.wrappedValue.toggle() }
                .keyboardShortcut("j", modifiers: .command)
        }
    }
}

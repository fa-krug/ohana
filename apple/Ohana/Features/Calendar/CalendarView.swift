import SwiftUI

/// Calendar (placeholder until the module is ported).
struct CalendarView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Calendar", systemImage: "calendar")
            .ohanaBackground(ModuleTint.calendar)
            .navigationTitle("Calendar")
    }
}

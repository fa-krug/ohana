import SwiftUI

/// Settings → Calendar: entry types, the calendar feed (placeholder until the module is ported).
struct CalendarSettingsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Calendar", systemImage: "calendar")
            .navigationTitle("Calendar")
    }
}

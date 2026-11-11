import SwiftUI

/// Settings → Chores: when the family's parts of the day start (`ChoreDayParts`). A chore's time
/// puts it into the part it falls in, a chore without a time is due when its part starts. Editors
/// change them (PATCH /chores/day-parts, sent once the pickers rest; the chores load again, as the
/// server moved the ones with a time), viewers and the demo see them.
struct ChoreSettingsView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    /// What the pickers show.
    @State private var parts: ChoreDayParts?
    /// What the server has, as far as the app knows.
    @State private var saved: ChoreDayParts?

    private var canEdit: Bool { family.canEdit && !app.isDemo }

    var body: some View {
        Form {
            Section {
                ForEach(ChorePart.allCases, id: \.self) { part in
                    DatePicker(selection: binding(part), displayedComponents: .hourAndMinute) {
                        Label(part.title, systemImage: part.systemImage)
                    }
                }
            } header: {
                Text("Parts of the Day")
            } footer: {
                if let parts, !parts.isOrdered {
                    Text("The morning must start before the day, and the day before the evening.")
                        .foregroundStyle(.red)
                } else {
                    Text("When each part starts. Chores without a time are due then.")
                }
            }
            .disabled(!canEdit || parts == nil)
        }
        .formStyle(.grouped)
        .readableWidth()
        .ohanaBackground(ModuleTint.chores)
        .navigationTitle("Chores")
        .task(id: family.revision(.chores)) { await load() }
        .task(id: parts) { await saveWhenResting() }
    }

    private func binding(_ part: ChorePart) -> Binding<Date> {
        Binding {
            CalendarEventSheet.date(of: (parts ?? family.chores.dayParts)[part], on: .today)
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            var changed = parts ?? family.chores.dayParts
            changed[part] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            parts = changed
        }
    }

    /// The chores' copy at once, then the server's (an older server's or the demo's: the copy).
    private func load() async {
        if parts == nil {
            parts = family.chores.dayParts
            saved = parts
        }
        guard let answer: ChoreDayPartsResponse = try? await family.api.get("/chores/day-parts") else { return }
        // Not over a change still waiting to be sent.
        if parts == saved { parts = answer.dayParts }
        saved = answer.dayParts
    }

    /// Sends the pickers' times once they rest for a moment and are in order; a refusal goes to
    /// the banner and the pickers go back.
    private func saveWhenResting() async {
        guard canEdit, let parts, let saved, parts != saved, parts.isOrdered else { return }
        try? await Task.sleep(for: .milliseconds(700))
        if Task.isCancelled { return }
        do {
            let answer: ChoreDayPartsResponse = try await family.api.send(.patch, "/chores/day-parts", body: parts)
            self.saved = answer.dayParts
            if self.parts == parts { self.parts = answer.dayParts }
            await family.chores.refresh()
            family.didChange(.chores)
        } catch {
            if Task.isCancelled { return }
            self.parts = saved
            ErrorBanner.shared.show(error)
        }
    }
}

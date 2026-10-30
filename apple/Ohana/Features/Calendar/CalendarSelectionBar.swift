import SwiftUI

/// The selection's actions: note, clear, event, copy and paste, skip weekends and (touch) the
/// range and multi-select modes.
struct CalendarSelectionActions: View {
    @Bindable var store: CalendarStore
    let actions: CalendarActions
    var touch: Bool
    var showDetails: Bool

    var body: some View {
        if !store.readOnly {
            Button("Icon & note", systemImage: "face.smiling") { actions.editNote() }
                .help("Add an icon or comment to the selected days (N)")
            Button("Clear", systemImage: "eraser") { store.clearSelectedDays() }
                .help("Remove all entries from the selected days (Delete)")
            Button("Event", systemImage: "calendar.badge.plus") { actions.addEvent() }
                .help("Add a timed event on the first selected day")
            Toggle(isOn: $store.skipWeekends) {
                Label("Skip weekends", systemImage: "calendar.day.timeline.leading")
            }
            .toggleStyle(.button)
            .help("Weekends are left out when filling, pasting or toggling ranges")
            if touch {
                Toggle(isOn: $store.rangeMode) {
                    Label("Range", systemImage: "arrow.left.and.right")
                }
                .toggleStyle(.button)
                .help("Tap a start day, enable this, then tap the end day")
                Toggle(isOn: $store.multiSelect) {
                    Label("Multi-select", systemImage: "checklist")
                }
                .toggleStyle(.button)
                .help("Tap days to add them to the selection or remove them")
            }
        }
        if showDetails {
            Button("Details", systemImage: "list.bullet.below.rectangle") { actions.showDetails() }
        }
    }
}

/// Phones: the floating glass bar at the bottom: the selection and its actions, the type chips.
struct CalendarSelectionBar: View {
    let store: CalendarStore
    let actions: CalendarActions

    var body: some View {
        let days = store.selectedDays
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if !days.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CalendarText.selection(days))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            if let line = singleDayLine(days) {
                                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            store.deselect()
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Clear the selection")
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            CalendarSelectionActions(store: store, actions: actions, touch: true, showDetails: true)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                } else if store.readOnly {
                    Text("View only").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Tap a day to select it – long-press and drag for a range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                CalendarTypeChips(store: store, showEditLink: false)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.snappy, value: days.isEmpty)
    }

    /// One day: its note, events and birthdays in a line (touch screens have no tooltips).
    private func singleDayLine(_ days: [Day]) -> String? {
        guard days.count == 1, let day = days.first else { return nil }
        var parts: [String] = []
        if let note = store.notes[day], !note.text.isEmpty { parts.append(note.text) }
        parts += (store.events[day] ?? []).map { "🕑 " + $0.line }
        parts += (store.birthdays[day] ?? []).map(CalendarText.birthday)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// iPad and Mac: the selection under the grid, with its actions and details.
struct CalendarSelectionPanel: View {
    let store: CalendarStore
    let actions: CalendarActions

    var body: some View {
        let days = store.selectedDays
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if days.isEmpty {
                    Text(store.readOnly ? LocalizedStringKey("View only") : LocalizedStringKey("Click or drag over days to select them. Shift-click extends, ⌘-click adds days."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(CalendarText.selection(days)).font(.headline)
                }
                Spacer(minLength: 0)
                if !days.isEmpty {
                    Button {
                        store.deselect()
                    } label: {
                        Label("Clear the selection", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Clear the selection (Esc)")
                }
            }
            if !days.isEmpty {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        #if os(iOS)
                        CalendarSelectionActions(store: store, actions: actions, touch: true, showDetails: false)
                        #else
                        CalendarSelectionActions(store: store, actions: actions, touch: false, showDetails: false)
                        #endif
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                }
                CalendarSelectionDetails(store: store, actions: actions)
            }
        }
        .glassCard(cornerRadius: 22, padding: 14)
    }
}

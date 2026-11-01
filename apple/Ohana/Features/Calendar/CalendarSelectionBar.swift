import SwiftUI

/// Touch is how the iPhone and iPad are used (range and multi-select modes, long presses); the
/// Mac has a pointer.
let calendarTouchInput: Bool = {
    #if os(iOS)
    true
    #else
    false
    #endif
}()

/// The selection's actions: note, clear, event, repeat, skip weekends and (touch) the range and
/// multi-select modes. Editors only: viewers have none (their details button is in the bar's
/// header).
struct CalendarSelectionActions: View {
    @Bindable var store: CalendarStore
    let actions: CalendarActions
    var touch: Bool

    var body: some View {
        if !store.readOnly {
            Button("Icon & note", systemImage: "face.smiling") { actions.editNote() }
                .help("Add an icon or comment to the selected days (N)")
            Button("Clear", systemImage: "eraser") { store.clearSelectedDays() }
                .help("Remove all entries from the selected days (Delete)")
            Button("Event", systemImage: "calendar.badge.plus") { actions.addEvent() }
                .help("Add a timed event on the first selected day")
            if store.canRepeat {
                Button("Repeat…", systemImage: "repeat") { actions.repeatSelection() }
                    .help("Repeat the selected days forwards or backwards (or drag the ▪ handle)")
            }
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
    }
}

/// The glass bar floating at the bottom of the calendar, on every size, so the selection's
/// actions are always next to the days: the selection (or how to select), its actions, the
/// type chips that apply a type, and (year grid) the zoom. `showDetails`: the details open in
/// a sheet (the list of months has no room for them under the grid), from a round button next
/// to the close button, so it takes no row of its own.
struct CalendarSelectionBar: View {
    let store: CalendarStore
    let actions: CalendarActions
    var showDetails = true
    var showZoom = false
    /// The "how to select" hint shows until the first few selections (like the web); the help
    /// button next to it stays.
    @AppStorage("ohana.calendar.selections") private var selections = 0
    @ScaledMetric(relativeTo: .body) private var closeSize: CGFloat = 30

    static let hintedSelections = 3

    var body: some View {
        let days = store.selectedDays
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                status(days)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showZoom { CalendarZoomSlider() }
                if days.isEmpty && store.fill == nil {
                    Button {
                        actions.showHelp()
                    } label: {
                        Label("Help & shortcuts", systemImage: "questionmark.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .help("Help & shortcuts (?)")
                } else if !days.isEmpty {
                    if showDetails {
                        Button {
                            actions.showDetails()
                        } label: {
                            roundIcon("list.bullet.below.rectangle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Details")
                        .help("Show the selected days’ details")
                    }
                    Button {
                        store.deselect()
                    } label: {
                        roundIcon("xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the selection")
                    .help("Clear the selection (Esc)")
                }
            }
            if !days.isEmpty && store.fill == nil && !store.readOnly {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        CalendarSelectionActions(store: store, actions: actions, touch: calendarTouchInput)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            CalendarTypeChips(store: store)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // The rows scroll under the bar's rounded edge, not past it.
        .clipShape(.rect(cornerRadius: 26))
        // Glass tinted with the cards' color: the days behind it stay out of the text's way.
        .glassEffect(.regular.tint(Color.cardBackground.opacity(0.8)), in: .rect(cornerRadius: 26))
        .frame(maxWidth: 760)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.snappy, value: days.isEmpty)
        .onChange(of: days.isEmpty) { _, empty in
            if !empty && selections < Self.hintedSelections { selections += 1 }
        }
    }

    /// The header's round buttons (details, close): a tinted circle in a 44 pt target.
    private func roundIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .frame(width: closeSize, height: closeSize)
            .background(Color.primary.opacity(0.08), in: .circle)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }

    @ViewBuilder
    private func status(_ days: [Day]) -> some View {
        if let fill = store.fill {
            Text(CalendarText.fill(fill))
                .font(.subheadline.weight(.semibold))
        } else if !days.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarText.selection(days))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let line = singleDayLine(days) {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else if store.readOnly {
            Text("View only").font(.caption).foregroundStyle(.secondary)
        } else if selections < Self.hintedSelections {
            Text(calendarTouchInput ? LocalizedStringKey("Tap a day to select it – long-press and drag for a range.")
                                    : LocalizedStringKey("Click or drag over days to select them. Shift-click extends, ⌘-click adds days."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One day: its note, events and birthdays in a line (touch screens have no tooltips).
    private func singleDayLine(_ days: [Day]) -> String? {
        guard days.count == 1, let day = days.first else { return nil }
        var parts: [String] = []
        if let note = store.notes[day], !note.text.isEmpty { parts.append(note.text) }
        parts += (store.events[day] ?? []).map { "🕑 " + $0.line(on: day) }
        parts += (store.birthdays[day] ?? []).map(CalendarText.birthday)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// iPad and Mac: the selected days' details under the grid (their actions are in the bar).
struct CalendarSelectionDetailsCard: View {
    let store: CalendarStore
    let actions: CalendarActions

    var body: some View {
        if !store.selection.isEmpty {
            CalendarSelectionDetails(store: store, actions: actions)
                .contentCard(cornerRadius: 22, padding: 14)
        }
    }
}

/// The year grid's zoom: to the right zooms in (fewer days across), like the web's slider.
struct CalendarZoomSlider: View {
    @AppStorage(CalendarZoom.key) private var zoom = CalendarZoom.initial

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { CalendarZoom.sliderValue(zoom) },
                                  set: { zoom = CalendarZoom.zoom(sliderValue: $0) }),
                   in: Double(CalendarZoom.min)...Double(CalendarZoom.max), step: 1) {
                Text("Zoom")
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityValue(CalendarText.days(CalendarZoom.clamp(zoom)))
            Text(CalendarText.days(CalendarZoom.clamp(zoom)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .help("Zoom: how many days fit in the calendar (⌘+ / ⌘− / ⌘0)")
    }
}

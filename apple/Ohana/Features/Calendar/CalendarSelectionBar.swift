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

/// The selection's actions: note, clear, event, repeat, and a menu with skip weekends and (touch)
/// the range and multi-select modes. Editors only: viewers have none (their details button is in
/// the bar's header).
struct CalendarSelectionActions: View {
    @Bindable var store: CalendarStore
    let actions: CalendarActions
    var touch: Bool

    var body: some View {
        if !store.readOnly {
            Button("Icon & note", systemImage: "face.smiling") { actions.editNote() }
                .help("Add an icon or comment to the selected days (N)")
            Button("Event", systemImage: "calendar.badge.plus") { actions.addEvent() }
                .help("Add a timed event on the first selected day")
            if store.canRepeat {
                Button("Repeat…", systemImage: "repeat") { actions.repeatSelection() }
                    .help("Repeat the selected days forwards or backwards (or drag the ▪ handle)")
            }
            Button("Clear", systemImage: "eraser") { store.clearSelectedDays() }
                .help("Remove all entries from the selected days (Delete)")
            // The modes in one menu on every size, its icon showing a mode that is on.
            Menu {
                modes
            } label: {
                Label("More", systemImage: modeIcon ?? "ellipsis")
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .tint(modeIcon == nil ? nil : .accentColor)
            .help(touch ? LocalizedStringKey("Skip weekends, range and multi-select") : LocalizedStringKey("Skip weekends"))
        }
    }

    @ViewBuilder
    private var modes: some View {
        Toggle(isOn: $store.skipWeekends) {
            Label("Skip weekends", systemImage: "calendar.day.timeline.leading")
        }
        .help("Weekends are left out when filling, pasting or toggling ranges")
        if touch {
            Toggle(isOn: $store.rangeMode) {
                Label("Range", systemImage: "arrow.left.and.right")
            }
            .help("Tap a start day, enable this, then tap the end day")
            Toggle(isOn: $store.multiSelect) {
                Label("Multi-select", systemImage: "checklist")
            }
            .help("Tap days to add them to the selection or remove them")
        }
    }

    /// The menu shows a mode that is on: taps on the days do something else then.
    private var modeIcon: String? {
        guard touch else { return nil }
        if store.rangeMode { return "arrow.left.and.right" }
        if store.multiSelect { return "checklist" }
        return nil
    }
}

/// The glass bar floating at the bottom of the calendar, on every size, so the selection's
/// actions are always next to the days: the selection (or how to select), its actions and the
/// type chips that apply a type. `showDetails` (the list of months: phones, narrow windows): the
/// details open in a sheet from the selection's title, as there is no room for them under the
/// grid, and the actions are a row of icons. Otherwise the details are on the page, so the
/// header only names the selection.
struct CalendarSelectionBar: View {
    let store: CalendarStore
    let actions: CalendarActions
    var showDetails = true
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
                if showDetails {
                    HStack(spacing: 10) {
                        CalendarSelectionActions(store: store, actions: actions, touch: calendarTouchInput)
                    }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                } else {
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

    /// The header's close button: a tinted circle in a 44 pt target.
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
            if showDetails {
                Button {
                    actions.showDetails()
                } label: {
                    // The chevron right behind the date; the whole width stays the button.
                    selection(days)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Show the selected days’ details"))
            } else {
                Text(CalendarText.selectionSummary(days))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        } else if !store.readOnly && selections < Self.hintedSelections {
            Text(calendarTouchInput ? LocalizedStringKey("Tap a day to select it – long-press and drag for a range.")
                                    : LocalizedStringKey("Click or drag over days to select them. Shift-click extends, ⌘-click adds days."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The day (or first and last) with the details' chevron, and under it the count or, one
    /// day, what is on it.
    private func selection(_ days: [Day]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(CalendarText.selectionTitle(days))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            if let line = days.count == 1 ? dayLine(days[0]) : Text(CalendarText.selectionCount(days)) {
                line.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// One day: its note (the icon in the theme color), holidays, events and birthdays in a line
    /// (touch screens have no tooltips).
    private func dayLine(_ day: Day) -> Text? {
        var parts: [String] = []
        let note = store.notes[day]
        if let note, !note.comment.isEmpty { parts.append(note.comment) }
        parts += (store.holidays[day] ?? []).map(CalendarText.holiday)
        parts += (store.events[day] ?? []).map { "🕑 " + $0.line(on: day) }
        parts += (store.birthdays[day] ?? []).map(CalendarText.birthday)
        let text = parts.joined(separator: " · ")
        guard let icon = note.flatMap({ CalendarSymbol.drawable($0.icon) }) else {
            return parts.isEmpty ? nil : Text(text)
        }
        let symbol = Text(Image(systemName: icon)).foregroundStyle(Color.accentColor)
        return parts.isEmpty ? Text("\(symbol) \(CalendarSymbol.title(icon))") : Text("\(symbol) \(text)")
    }
}

/// iPad and Mac: the selected days' details under the grid or beside it (their actions are in
/// the bar). `placeholder` (the column beside the grid): with nothing selected a quiet hint holds
/// its place. `maxWidth`: under the grid, no wider than a page of text.
struct CalendarSelectionDetailsCard: View {
    let store: CalendarStore
    let actions: CalendarActions
    var placeholder = false
    var maxWidth: CGFloat = .infinity

    var body: some View {
        if !store.selection.isEmpty {
            CalendarSelectionDetails(store: store, actions: actions)
                .contentCard(cornerRadius: 22, padding: 14)
                .frame(maxWidth: maxWidth, alignment: .leading)
        } else if placeholder {
            VStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(store.readOnly ? LocalizedStringKey("Select days to see their entries.")
                                    : LocalizedStringKey("Select days to see and change them."))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .contentCard(cornerRadius: 22, padding: 14)
        }
    }
}

extension CalendarText {
    /// The bar's header when the details are on the page: "Wednesday, 4 November"; a run of days
    /// "3 days · 4 – 6 Nov"; days with gaps "5 days selected".
    static func selectionSummary(_ days: [Day]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        if days.count == 1 { return selectionTitle(days) }
        // Sorted days without repeats (the selection's): consecutive when the span is as long.
        guard CalendarMath.isContiguous(days) else {
            return selectionAnnouncement(days.count)
        }
        let style: Date.IntervalFormatStyle = first.year == last.year
            ? .interval.day().month(.abbreviated)
            : .interval.day().month(.abbreviated).year()
        return "\(Self.days(days.count)) · \((first.date..<last.date).formatted(style))"
    }
}

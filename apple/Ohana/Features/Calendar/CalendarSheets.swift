import SwiftUI

/// What the calendar shows in a sheet.
enum CalendarSheet: Identifiable {
    case note([Day])
    case event(CalendarEventDraft)
    case details
    case repeatDays
    case help

    var id: String {
        switch self {
        case let .note(days): "note-" + days.map(\.description).joined(separator: ",")
        case let .event(draft): "event-" + (draft.original?.uid ?? draft.eventID ?? "new")
        case .details: "details"
        case .repeatDays: "repeat"
        case .help: "help"
        }
    }
}

/// The sheet's actions, shared by the grids' menus, the selection bar and the toolbar.
@Observable
final class CalendarActions {
    let store: CalendarStore
    var sheet: CalendarSheet?

    init(store: CalendarStore) { self.store = store }

    func editNote() {
        guard !store.readOnly else { return }
        let days = store.targetDays()
        if days.isEmpty { return store.showToast(String(localized: "Select some days first")) }
        sheet = .note(days)
    }

    func addEvent(on day: Day? = nil) {
        guard !store.readOnly else { return }
        let target = day ?? store.selectedDays.first ?? (Day.today.year == store.year ? Day.today : Day(year: store.year, month: 1, day: 1))
        sheet = .event(.new(on: target))
    }

    func editEvent(_ event: CalendarEvent) {
        sheet = .event(CalendarEventDraft(event))
    }

    func showDetails() { sheet = .details }

    /// The fill handle's equivalent for touch (and the menus): repeat the selection up to a day.
    func repeatSelection() {
        guard store.canRepeat else {
            return store.showToast(String(localized: "Select days that follow each other first"))
        }
        sheet = .repeatDays
    }

    func showHelp() { sheet = .help }
}

// MARK: Note

/// Icon (an SF Symbol, `CalendarSymbol.noteIcons`) and/or comment for the days (the web's note
/// dialog).
struct CalendarNoteSheet: View {
    let store: CalendarStore
    let days: [Day]
    @Environment(\.dismiss) private var dismiss
    @State private var icon = ""
    @State private var comment = ""
    /// What the days had when the sheet opened, for Cancel.
    @State private var initial = CalendarNote(icon: "", comment: "")
    @State private var same = true
    /// Whether an icon was picked on the sheet: until then a new comment's best suggestion is taken
    /// (for days without an icon).
    @State private var iconPicked = false
    /// With a keyboard (Mac) the comment has the focus; on touch screens the keyboard would
    /// cover the icons.
    @FocusState private var commentFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Comment") {
                    TextField("e.g. Christmas", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: comment) { _, value in
                            if value.count > 500 { comment = String(value.prefix(500)) }
                            if !iconPicked && initial.icon.isEmpty && value != initial.comment {
                                icon = CalendarSymbol.suggestions(for: value).first ?? ""
                            }
                        }
                        .focused($commentFocused)
                }
                Section {
                    CalendarSymbolGrid(symbols: CalendarSymbol.noteIcons,
                                       selection: Binding(get: { icon }, set: { icon = $0; iconPicked = true }),
                                       allowsNone: true, suggested: suggested)
                } header: {
                    Text("Icon")
                }
                if !same {
                    Section {
                        Text("The selected days have different notes – saving replaces them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if days.contains(where: { store.notes[$0] != nil }) {
                    Section {
                        Button("Remove", role: .destructive) {
                            store.setNote(nil, on: days)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .readableWidth()
            .navigationTitle("Icon & note")
            .navigationSubtitleCompat(days.count == 1 ? CalendarText.longDay(days[0])
                                      : "\(CalendarText.days(days.count)): \(CalendarText.span(days))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .discardGuard(hasChanges: hasChanges)
        .errorBanner()
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
        .onAppear {
            let notes = days.map { store.notes[$0] }
            same = notes.allSatisfy { CalendarMath.sameNote($0, notes.first ?? nil) }
            if same, let first = CalendarMath.noteOrNil(notes.first ?? nil) {
                icon = first.icon
                comment = first.comment
                initial = first
            }
            #if os(macOS)
            commentFocused = true
            #endif
        }
    }

    /// The icons the comment suggests (an emoji in it too).
    private var suggested: [String] { CalendarSymbol.suggestions(for: comment) }

    private var hasChanges: Bool {
        icon.trimmingCharacters(in: .whitespacesAndNewlines) != initial.icon
            || comment.trimmingCharacters(in: .whitespacesAndNewlines) != initial.comment
    }

    private func save() {
        let i = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setNote(i.isEmpty && c.isEmpty ? nil : CalendarNote(icon: i, comment: c), on: days)
        dismiss()
    }
}

extension View {
    /// A subtitle under the navigation title where the platform has one.
    @ViewBuilder
    func navigationSubtitleCompat(_ text: String) -> some View {
        #if os(macOS)
        navigationSubtitle(text)
        #else
        if #available(iOS 26, *) { navigationSubtitle(text) } else { self }
        #endif
    }
}

// MARK: Details

/// The selected days with their entries, holidays, notes, events and birthdays, and their actions.
struct CalendarSelectionDetails: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.horizontalSizeClass) private var sizeClass
    let store: CalendarStore
    let actions: CalendarActions
    @State private var deleting: CalendarEvent?
    /// Days shown at most (a long selection lists the days that have something).
    static let maxDays = 62

    var body: some View {
        let days = store.selectedDays
        let withContent = days.count == 1 ? days : days.filter(hasContent)
        let shown = days.count == 1 ? days : Array(withContent.prefix(Self.maxDays))
        VStack(alignment: .leading, spacing: 12) {
            if days.isEmpty {
                Text(store.readOnly ? LocalizedStringKey("View only") : LocalizedStringKey("Select days to see and change them."))
                    .foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("Nothing on the selected days yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { day in
                dayCard(day)
            }
            if days.count > 1 && withContent.count > Self.maxDays {
                Text("Only the first \(Self.maxDays) days are listed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .calendarDeleteEventDialog($deleting, store: store)
    }

    private func hasContent(_ day: Day) -> Bool {
        store.entries[day] != nil || store.notes[day] != nil || store.events[day] != nil || store.birthdays[day] != nil
            || store.holidays[day] != nil
    }

    private func dayCard(_ day: Day) -> some View {
        let types = store.types(on: day)
        let events = store.events[day] ?? []
        let holidays = store.holidays[day] ?? []
        let birthdays = store.birthdays[day] ?? []
        let note = store.notes[day]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(CalendarText.longDay(day)).font(.headline)
                Spacer()
                if store.isGap(day) {
                    Label("Not covered", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if !store.readOnly {
                    Button {
                        actions.addEvent(on: day)
                    } label: {
                        Label("Add event", systemImage: "calendar.badge.plus")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .help("Add event")
                }
            }
            if !types.isEmpty {
                CalendarDayTypes(types: types, store: store)
            }
            ForEach(holidays, id: \.self) { h in
                Text(CalendarText.holiday(h))
            }
            if let note {
                Button {
                    if !store.readOnly { actions.sheet = .note([day]) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        CalendarNoteSymbol(icon: note.icon.isEmpty ? "note.text" : note.icon)
                        Text(note.comment.isEmpty ? CalendarSymbol.title(note.icon) : note.comment)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.readOnly)
                .accessibilityLabel(Text(note.text))
            }
            ForEach(events, id: \.uid) { event in
                eventRow(event, on: day)
            }
            ForEach(birthdays, id: \.self) { b in
                Text(CalendarText.birthday(b))
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
    }

    /// The appointment search an event was booked from (the details sheet closes first).
    private func openSearch(_ id: String) {
        actions.sheet = nil
        family.open(.appointmentSearch(id: id))
    }

    private func eventRow(_ event: CalendarEvent, on day: Day) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.isAppointment ? "stethoscope" : "clock")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.person.isEmpty ? event.title : "\(event.title) (\(event.person))")
                    .font(.subheadline.weight(.semibold))
                Text(event.whenText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let repeatText = event.repeatText {
                    Label(repeatText, systemImage: "repeat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !event.location.isEmpty {
                    Text(event.location).font(.caption).foregroundStyle(.secondary)
                }
                if !event.note.isEmpty {
                    Text(event.note).font(.caption)
                }
                if let url = URL(string: event.url), !event.url.isEmpty {
                    Link(destination: url) {
                        Label("Open link", systemImage: "link").font(.caption)
                    }
                }
                if event.isAppointment, let searchID = event.searchId {
                    Button {
                        openSearch(searchID)
                    } label: {
                        Label("Open the appointment search", systemImage: "stethoscope").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
            if !store.readOnly {
                Menu {
                    Button("Edit", systemImage: "pencil") { actions.editEvent(event) }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = event }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("Event actions")
            }
        }
        .contentShape(.rect)
        // Onto another day of the grid (iPad, Mac: phones have no grid next to the details).
        .modifier(CalendarEventDragSource(store: store, event: event, day: day,
                                          enabled: !store.readOnly && sizeClass != .compact))
        .contextMenu {
            if event.isAppointment, let searchID = event.searchId {
                Button("Open the appointment search", systemImage: "stethoscope") { openSearch(searchID) }
            }
            if !store.readOnly {
                Button("Edit", systemImage: "pencil") { actions.editEvent(event) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = event }
            }
        }
    }
}

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
        case let .event(draft): "event-" + (draft.eventID ?? "new")
        case .details: "details"
        case .repeatDays: "repeat"
        case .help: "help"
        }
    }
}

/// A new event or one being edited.
struct CalendarEventDraft: Equatable {
    var eventID: String?
    var input: CalendarEventInput
    var isAppointment = false
    /// The appointment search it was booked from.
    var searchID: String?
    /// The event being edited, as it is saved.
    var original: CalendarEvent?

    static func new(on day: Day) -> CalendarEventDraft {
        CalendarEventDraft(input: CalendarEventInput(date: day, start: nil, end: nil, title: ""))
    }

    init(eventID: String? = nil, input: CalendarEventInput, isAppointment: Bool = false) {
        self.eventID = eventID
        self.input = input
        self.isAppointment = isAppointment
    }

    init(_ event: CalendarEvent) {
        eventID = event.id
        input = CalendarEventInput(event)
        isAppointment = event.isAppointment
        searchID = event.searchId
        original = event
    }

    /// What's wrong with it (the server's checks), nil when it can be saved.
    var problem: String? {
        if input.title.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Give it a title.") }
        if let start = input.start, let end = input.end, end < start { return String(localized: "The end must be after the start.") }
        let url = input.url.trimmingCharacters(in: .whitespaces).lowercased()
        if !url.isEmpty && !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
            return String(localized: "The link must start with http:// or https://.")
        }
        return nil
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

/// Icon and/or comment for the days (the web's note dialog).
struct CalendarNoteSheet: View {
    let store: CalendarStore
    let days: [Day]
    @Environment(\.dismiss) private var dismiss
    @State private var icon = ""
    @State private var comment = ""
    /// What the days had when the sheet opened, for Cancel.
    @State private var initial = CalendarNote(icon: "", comment: "")
    @State private var same = true
    /// With a keyboard (Mac) the comment has the focus; on touch screens the keyboard would
    /// cover the icons.
    @FocusState private var commentFocused: Bool

    static let icons = ["🎄", "🎅", "🎁", "🎆", "🐣", "🐰", "🎃", "🎂", "🎉", "❤️",
                        "⭐", "📌", "✈️", "🏖️", "⛷️", "🏫", "🏥", "🎓", "💼", "⚽"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(Self.icons, id: \.self) { e in
                            Button {
                                icon = icon == e ? "" : e
                            } label: {
                                Text(e)
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(icon == e ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                                in: .rect(cornerRadius: 10))
                                    .overlay {
                                        if icon == e { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(icon == e ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Or any other emoji", text: $icon)
                        .onChange(of: icon) { _, value in if value.utf16.count > 16 { icon = String(value.prefix(4)) } }
                        .onSubmit { save() }
                } header: {
                    Text("Icon")
                }
                Section("Comment") {
                    TextField("e.g. Christmas", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: comment) { _, value in if value.count > 500 { comment = String(value.prefix(500)) } }
                        .focused($commentFocused)
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

// MARK: Event

/// Adds or edits a timed event (POST /events, PATCH /events/{id}).
struct CalendarEventSheet: View {
    @Environment(FamilyContext.self) private var family
    let store: CalendarStore
    @State var draft: CalendarEventDraft
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var deleting: CalendarEvent?
    /// The draft as it opened, for Cancel.
    private let initial: CalendarEventDraft

    init(store: CalendarStore, draft: CalendarEventDraft) {
        self.store = store
        _draft = State(initialValue: draft)
        initial = draft
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.input.title)
                        .accessibilityHint(Text("Required"))
                    DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                    Toggle("All day", isOn: allDayBinding)
                    if draft.input.start != nil {
                        DatePicker("Starts", selection: timeBinding(\.start, fallback: "09:00"), displayedComponents: .hourAndMinute)
                        Toggle("End time", isOn: hasEndBinding)
                        if draft.input.end != nil {
                            DatePicker("Ends", selection: timeBinding(\.end, fallback: "10:00"), displayedComponents: .hourAndMinute)
                        }
                    }
                } footer: {
                    if let problem = timeProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Who it is for", text: $draft.input.person)
                    TextField("Location", text: $draft.input.location)
                    TextField("Link", text: $draft.input.url)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Note", text: $draft.input.note, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem = linkProblem {
                            Text(problem).foregroundStyle(.red)
                        }
                        if draft.isAppointment {
                            Text("Booked from an appointment search.")
                            if let searchID = draft.searchID {
                                Button("Open the appointment search") {
                                    dismiss()
                                    family.open(.appointmentSearch(id: searchID))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let original = draft.original {
                    Section {
                        Button("Delete event", role: .destructive) { deleting = original }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.eventID == nil ? LocalizedStringKey("New event") : LocalizedStringKey("Edit event"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: draft != initial)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft.problem != nil || saving)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .calendarDeleteEventDialog($deleting, store: store) { dismiss() }
        }
        .discardGuard(hasChanges: draft != initial)
        .errorBanner()
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    /// The checks shown at their fields (a missing title only disables Save).
    private var timeProblem: String? {
        if let start = draft.input.start, let end = draft.input.end, end < start {
            return String(localized: "The end must be after the start.")
        }
        return nil
    }

    private var linkProblem: String? {
        let url = draft.input.url.trimmingCharacters(in: .whitespaces).lowercased()
        return !url.isEmpty && !(url.hasPrefix("http://") || url.hasPrefix("https://"))
            ? String(localized: "The link must start with http:// or https://.") : nil
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { draft.input.date.date }, set: { draft.input.date = Day($0) })
    }

    private var allDayBinding: Binding<Bool> {
        Binding(get: { draft.input.start == nil }, set: { allDay in
            draft.input.start = allDay ? nil : "09:00"
            draft.input.end = nil
        })
    }

    private var hasEndBinding: Binding<Bool> {
        Binding(get: { draft.input.end != nil }, set: { on in
            draft.input.end = on ? Self.later(draft.input.start ?? "09:00") : nil
        })
    }

    private func timeBinding(_ key: WritableKeyPath<CalendarEventInput, String?>, fallback: String) -> Binding<Date> {
        Binding(get: {
            Self.date(of: draft.input[keyPath: key] ?? fallback, on: draft.input.date)
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.input[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        })
    }

    static func date(of time: String, on day: Day) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let c = DateComponents(year: day.year, month: day.month, day: day.day,
                               hour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0)
        return Calendar.current.date(from: c) ?? day.date
    }

    /// An hour after "HH:MM" (at most 23:59).
    static func later(_ time: String) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let minutes = min((parts.first ?? 9) * 60 + (parts.count > 1 ? parts[1] : 0) + 60, 23 * 60 + 59)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func save() {
        saving = true
        var input = draft.input
        input.title = input.title.trimmingCharacters(in: .whitespaces)
        input.url = input.url.trimmingCharacters(in: .whitespaces)
        let id = draft.eventID
        perform {
            defer { saving = false }
            try await store.saveEvent(input, id: id)
            dismiss()
        }
    }

}

extension View {
    /// "Delete “Title”?" before an event is deleted, the same from every place that deletes one
    /// (the editor, a row's menu, its context menu); `onDeleted` runs after it is gone.
    func calendarDeleteEventDialog(_ event: Binding<CalendarEvent?>, store: CalendarStore,
                                   onDeleted: @escaping () -> Void = {}) -> some View {
        confirmationDialog(String(localized: "Delete “\(event.wrappedValue?.title ?? "")”?"),
                           isPresented: Binding(get: { event.wrappedValue != nil }, set: { if !$0 { event.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: event.wrappedValue) { e in
            Button("Delete", role: .destructive) {
                perform {
                    try await store.deleteEvent(e)
                    onDeleted()
                }
            }
        } message: { _ in
            Text("You can undo this.")
        }
    }
}

// MARK: Details

/// The selected days with their entries, notes, events and birthdays, and their actions.
struct CalendarSelectionDetails: View {
    @Environment(FamilyContext.self) private var family
    let store: CalendarStore
    let actions: CalendarActions
    @State private var deleting: CalendarEvent?
    /// Days shown at most (a long selection lists the days that have something).
    static let maxDays = 62

    var body: some View {
        let days = store.selectedDays
        let shown = days.count == 1 ? days : days.filter(hasContent).prefix(Self.maxDays).map { $0 }
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
            if days.count > 1 && days.filter(hasContent).count > Self.maxDays {
                Text("Only the first \(Self.maxDays) days are listed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .calendarDeleteEventDialog($deleting, store: store)
    }

    private func hasContent(_ day: Day) -> Bool {
        store.entries[day] != nil || store.notes[day] != nil || store.events[day] != nil || store.birthdays[day] != nil
    }

    private func dayCard(_ day: Day) -> some View {
        let types = store.types(on: day)
        let events = store.events[day] ?? []
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
                HStack(spacing: 6) {
                    ForEach(types) { type in
                        HStack(spacing: 4) {
                            CalendarSwatch(type: type, size: 10)
                            Text(type.name).font(.subheadline)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(calendarHex: type.color).opacity(0.18), in: .capsule)
                    }
                }
            }
            if let note {
                Button {
                    if !store.readOnly { actions.sheet = .note([day]) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.icon.isEmpty ? "📝" : note.icon)
                        Text(note.comment.isEmpty ? String(localized: "Icon") : note.comment)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.readOnly)
            }
            ForEach(events) { event in
                eventRow(event)
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

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.isAppointment ? "stethoscope" : "clock")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.person.isEmpty ? event.title : "\(event.title) (\(event.person))")
                    .font(.subheadline.weight(.semibold))
                Text(event.timeText ?? String(localized: "All day"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// The details in a sheet (phones).
struct CalendarDetailsSheet: View {
    let store: CalendarStore
    let actions: CalendarActions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CalendarSelectionDetails(store: store, actions: actions)
                    .padding()
            }
            .navigationTitle(CalendarText.span(store.selectedDays))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .errorBanner()
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

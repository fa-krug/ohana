import SwiftUI

/// A new event or one being edited: what the editor's fields hold. Its Repeat is
/// `RepeatEditing`'s.
struct CalendarEventDraft: Equatable, RepeatEditing {
    var eventID: String?
    var input: CalendarEventInput
    var isAppointment = false
    /// The appointment search it was booked from.
    var searchID: String?
    /// The event being edited (for one that repeats: the occurrence), as it is saved.
    var original: CalendarEvent?

    static func new(on day: Day) -> CalendarEventDraft {
        CalendarEventDraft(input: CalendarEventInput(date: day, endDate: day, start: nil, end: nil, title: ""))
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

    var repeatRRule: String? {
        get { input.rrule }
        set { input.rrule = newValue }
    }

    var repeatStart: Day { input.date }

    var isAllDay: Bool { input.start == nil }
    /// The last day as the fields show it (it may be before the first while it's being changed).
    var endDay: Day { input.endDate ?? input.date }
    /// Editing one occurrence of an event that repeats: saving asks which ones it changes.
    var isOccurrence: Bool { eventID != nil && original?.occurrence != nil }
    /// How it repeats isn't what it was: only "this and the following events" can take that.
    var ruleChanged: Bool { RepeatRule.canonical(input.rrule) != RepeatRule.canonical(original?.rrule) }

    /// A new first day: the last moves along, so it keeps its length.
    mutating func setStart(_ day: Day) {
        let length = CalendarMath.ordinal(endDay) - CalendarMath.ordinal(input.date)
        input.date = day
        input.endDate = CalendarMath.add(day, max(length, 0))
    }

    mutating func setEnd(_ day: Day) {
        input.endDate = day
    }

    /// All day: no times. Timed: from 9:00, no end time yet.
    mutating func setAllDay(_ allDay: Bool) {
        input.start = allDay ? nil : "09:00"
        input.end = nil
    }

    /// A timed event's end time on or off (an hour after the start, on the first day).
    mutating func setHasEnd(_ on: Bool) {
        input.end = on ? CalendarEventSheet.later(input.start ?? "09:00") : nil
        if !on || endDay < input.date { input.endDate = input.date }
    }

    /// What's wrong with it (the server's checks), nil when it can be saved.
    var problem: String? {
        if input.title.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Give it a title.") }
        return timeProblem ?? repeatProblem ?? linkProblem
    }

    /// The end before the start: a day before the first, or an earlier time on the same day.
    var timeProblem: String? {
        if endDay < input.date { return String(localized: "The end must be after the start.") }
        if endDay == input.date, let start = input.start, let end = input.end, end < start {
            return String(localized: "The end must be after the start.")
        }
        return nil
    }

    var linkProblem: String? {
        let url = input.url.trimmingCharacters(in: .whitespaces).lowercased()
        return !url.isEmpty && !(url.hasPrefix("http://") || url.hasPrefix("https://"))
            ? String(localized: "The link must start with http:// or https://.") : nil
    }
}

/// Adds or edits an event (POST /events, PATCH /events/{id}): one day or several, all day or
/// timed, repeating like in Apple Calendar. Saving a changed occurrence of a repeating event asks
/// whether the change is for it alone or for it and the ones after it.
struct CalendarEventSheet: View {
    @Environment(FamilyContext.self) private var family
    let store: CalendarStore
    @State var draft: CalendarEventDraft
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var deleting: CalendarEvent?
    @State private var askSpan = false
    @State private var customRepeat = false
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
                    Toggle("All day", isOn: Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0) }))
                    if draft.isAllDay {
                        DatePicker("Starts", selection: dayBinding(start: true), displayedComponents: .date)
                        DatePicker("Ends", selection: dayBinding(start: false), in: draft.input.date.date...,
                                   displayedComponents: .date)
                    } else {
                        DatePicker("Starts", selection: momentBinding(start: true), displayedComponents: [.date, .hourAndMinute])
                        Toggle("End time", isOn: Binding(get: { draft.input.end != nil }, set: { draft.setHasEnd($0) }))
                        if draft.input.end != nil {
                            DatePicker("Ends", selection: momentBinding(start: false), in: momentBinding(start: true).wrappedValue...,
                                       displayedComponents: [.date, .hourAndMinute])
                        } else if draft.endDay > draft.input.date {
                            DatePicker("Ends", selection: dayBinding(start: false), in: draft.input.date.date...,
                                       displayedComponents: .date)
                        }
                    }
                } footer: {
                    if let problem = draft.timeProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                CalendarEventRepeatSection(draft: $draft, custom: $customRepeat)
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
                        if let problem = draft.linkProblem {
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
            .navigationDestination(isPresented: $customRepeat) {
                CalendarRepeatRuleEditor(draft: $draft)
            }
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
            .confirmationDialog("This is a repeating event.", isPresented: $askSpan, titleVisibility: .visible) {
                if !draft.ruleChanged {
                    Button("Save for this event only") { save(span: .this) }
                }
                Button("Save for future events") { save(span: .future) }
            } message: {
                if draft.ruleChanged {
                    Text("A change to how it repeats applies to this event and the ones after it.")
                }
            }
            .calendarDeleteEventDialog($deleting, store: store) { dismiss() }
        }
        .discardGuard(hasChanges: draft != initial)
        .errorBanner()
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    /// A day of an all-day event (or the last of a timed one without an end time).
    private func dayBinding(start: Bool) -> Binding<Date> {
        Binding(get: { (start ? draft.input.date : draft.endDay).date }, set: { date in
            if start { draft.setStart(Day(date)) } else { draft.setEnd(Day(date)) }
        })
    }

    /// The start (its day and time) or the end of a timed event.
    private func momentBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            start ? Self.date(of: draft.input.start ?? "09:00", on: draft.input.date)
                  : Self.date(of: draft.input.end ?? Self.later(draft.input.start ?? "09:00"), on: draft.endDay)
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            if start {
                draft.setStart(Day(date))
                draft.input.start = time
            } else {
                draft.setEnd(Day(date))
                draft.input.end = time
            }
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

    /// Unchanged: nothing to send. A changed occurrence of a repeating event asks first.
    private func save() {
        if draft.eventID != nil && draft == initial { return dismiss() }
        if draft.isOccurrence { askSpan = true } else { save(span: nil) }
    }

    private func save(span: CalendarEventSpan?) {
        saving = true
        var input = draft.input
        input.title = input.title.trimmingCharacters(in: .whitespaces)
        input.url = input.url.trimmingCharacters(in: .whitespaces)
        input.endDate = input.lastDay
        let original = draft.original
        perform {
            defer { saving = false }
            try await store.saveEvent(input, editing: original, span: span)
            dismiss()
        }
    }
}

extension View {
    /// "Delete “Title”?" before an event is deleted, the same from every place that deletes one
    /// (the editor, a row's menu, its context menu); `onDeleted` runs after it is gone. For an
    /// occurrence of a repeating event it offers this one alone or it and the ones after it (on
    /// the first occurrence: all of them).
    func calendarDeleteEventDialog(_ event: Binding<CalendarEvent?>, store: CalendarStore,
                                   onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(CalendarDeleteEventDialog(event: event, store: store, onDeleted: onDeleted))
    }
}

private struct CalendarDeleteEventDialog: ViewModifier {
    @Binding var event: CalendarEvent?
    let store: CalendarStore
    let onDeleted: () -> Void
    /// The series' first day, once loaded: there "the ones after it" are all of them.
    @State private var seriesStart: Day?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(String(localized: "Delete “\(event?.title ?? "")”?"),
                                isPresented: Binding(get: { event != nil }, set: { if !$0 { event = nil } }),
                                titleVisibility: .visible, presenting: event) { e in
                if e.occurrence != nil {
                    Button("Delete This Event Only", role: .destructive) { delete(e, span: .this) }
                    Button(e.occurrence == seriesStart ? LocalizedStringKey("Delete All Events")
                                                       : LocalizedStringKey("Delete All Future Events"),
                           role: .destructive) { delete(e, span: .future) }
                } else {
                    Button("Delete", role: .destructive) { delete(e, span: nil) }
                }
            } message: { e in
                Text(e.occurrence != nil ? LocalizedStringKey("This is a repeating event. You can undo this.")
                                         : LocalizedStringKey("You can undo this."))
            }
            .task(id: event?.uid) {
                seriesStart = nil
                guard let event, event.occurrence != nil else { return }
                seriesStart = try? await store.seriesStart(event.id)
            }
    }

    private func delete(_ event: CalendarEvent, span: CalendarEventSpan?) {
        perform {
            try await store.deleteEvent(event, span: span)
            onDeleted()
        }
    }
}

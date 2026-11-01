import SwiftUI

/// Edits one thing found in a letter before it's added (`LetterReviewSheet`): what it is (event,
/// task, deadline: the day and time carry over), the title; for an event its days and times, who
/// it is for (the family's names in a menu, or any text) and where; for a task or deadline the
/// due day (a deadline needs one), an optional time and the Reminders list (with access); a note.
struct LetterItemEditor: View {
    let names: [String]
    let onSave: (AssistantSuggestionOp) -> Void
    @State private var draft: LetterItemDraft
    /// The draft as it opened, for Cancel.
    private let initial: LetterItemDraft
    @State private var reminders = RemindersStore.shared
    @Environment(\.dismiss) private var dismiss

    init(op: AssistantSuggestionOp, today: Day, names: [String], onSave: @escaping (AssistantSuggestionOp) -> Void) {
        let draft = LetterItemDraft(op, today: today)
        _draft = State(initialValue: draft)
        initial = draft
        self.names = names
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: Binding(get: { draft.kind }, set: { draft.setKind($0) })) {
                        ForEach(LetterItemDraft.Kind.allCases) { kind in
                            Text(Self.name(kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Title", text: $draft.title)
                        .accessibilityHint(Text("Required"))
                }
                if draft.kind == .event {
                    eventWhen
                    eventDetails
                } else {
                    reminderDue
                    reminderList
                }
                Section {
                    TextField("Note", text: $draft.note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Self.name(draft.kind))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: draft != initial)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft.op)
                        dismiss()
                    }
                    .disabled(draft.problem != nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .discardGuard(hasChanges: draft != initial)
        .task(id: reminders.revision) { reminders.refreshAccess() }
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 460, idealHeight: 560)
        #endif
    }

    static func name(_ kind: LetterItemDraft.Kind) -> LocalizedStringKey {
        switch kind {
        case .event: "Event"
        case .task: "Task"
        case .deadline: "Deadline"
        }
    }

    // MARK: Event

    private var eventWhen: some View {
        Section {
            Toggle("All day", isOn: Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0) }))
            if draft.isAllDay {
                DatePicker("Starts", selection: dayBinding, displayedComponents: .date)
                DatePicker("Ends", selection: endDayBinding, in: first.date..., displayedComponents: .date)
            } else {
                DatePicker("Starts", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                Toggle("End time", isOn: Binding(get: { draft.endTime != nil }, set: { draft.setHasEndTime($0) }))
                if draft.endTime != nil {
                    DatePicker("Ends", selection: endBinding, in: startBinding.wrappedValue...,
                               displayedComponents: [.date, .hourAndMinute])
                } else if draft.endDay != nil {
                    DatePicker("Ends", selection: endDayBinding, in: first.date..., displayedComponents: .date)
                }
            }
        } footer: {
            if let problem = draft.timeProblem {
                Text(problem).foregroundStyle(.red)
            }
        }
    }

    private var eventDetails: some View {
        Section {
            HStack {
                TextField("Who it is for", text: $draft.person)
                if !names.isEmpty {
                    Menu {
                        ForEach(names, id: \.self) { name in
                            Button(name) { draft.person = name }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("Who it is for"))
                }
            }
            TextField("Location", text: $draft.location)
        }
    }

    private var first: Day { draft.day ?? draft.today }

    /// The first day of an all-day event (the last one keeps the length).
    private var dayBinding: Binding<Date> {
        Binding(get: { first.date }, set: { draft.setDay(Day($0)) })
    }

    /// The last day of an all-day event (the first: one day).
    private var endDayBinding: Binding<Date> {
        Binding(get: { (draft.endDay ?? first).date }, set: { draft.setEndDay(Day($0)) })
    }

    /// A timed event's first day and start time.
    private var startBinding: Binding<Date> {
        Binding(get: { CalendarEventSheet.date(of: draft.time ?? "09:00", on: first) }, set: { date in
            draft.setDay(Day(date))
            draft.time = Self.clock(date)
        })
    }

    /// A timed event's last day and end time.
    private var endBinding: Binding<Date> {
        Binding(get: {
            CalendarEventSheet.date(of: draft.endTime ?? CalendarEventSheet.later(draft.time ?? "09:00"),
                                    on: draft.endDay ?? first)
        }, set: { date in
            draft.setEndDay(Day(date))
            draft.endTime = Self.clock(date)
        })
    }

    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: Task and deadline

    private var reminderDue: some View {
        Section {
            Toggle("Date", isOn: Binding(get: { draft.day != nil }, set: { draft.setHasDue($0) }))
            if draft.day != nil {
                DatePicker("Due", selection: dayBinding, displayedComponents: .date)
                Toggle("Time", isOn: Binding(get: { draft.time != nil }, set: { on in
                    draft.time = on ? "09:00" : nil
                }))
                if draft.time != nil {
                    DatePicker("Time", selection: Binding(get: { CalendarEventSheet.date(of: draft.time ?? "09:00", on: first) },
                                                          set: { draft.time = Self.clock($0) }),
                               displayedComponents: .hourAndMinute)
                }
            }
        } footer: {
            if draft.kind == .deadline, draft.day == nil {
                Text("A deadline needs a date.").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var reminderList: some View {
        let lists = reminders.access.isGranted ? reminders.lists().filter(\.isWritable) : []
        if !lists.isEmpty {
            Section {
                Picker("Reminders list", selection: Binding(get: { draft.list ?? reminders.defaultListID ?? lists[0].id }, set: { id in
                    draft.list = id
                    draft.listTitle = lists.first { $0.id == id }?.title
                })) {
                    ForEach(lists) { list in
                        Text(verbatim: list.title).tag(list.id)
                    }
                }
            }
        }
    }
}

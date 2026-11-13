import SwiftUI

/// A new chore or one being edited: what the editor's fields hold. Its Repeat is
/// `RepeatEditing`'s, as an event's.
struct ChoreDraft: Equatable, RepeatEditing {
    var input: ChoreInput
    /// When the family's parts of the day start: a time's part, a part's usual time.
    var dayParts: ChoreDayParts = .standard

    /// A new chore: the signed-in account (`me`) is notified, nobody else.
    static func new(on day: Day, for assigneeID: String? = nil, me: String? = nil,
                    dayParts: ChoreDayParts = .standard) -> ChoreDraft {
        ChoreDraft(input: ChoreInput(title: "", assigneeId: assigneeID, day: day, subscriberIds: me.map { [$0] } ?? []),
                   dayParts: dayParts)
    }

    var repeatRRule: String? {
        get { input.rrule }
        set { input.rrule = newValue }
    }

    var repeatStart: Day { input.day }

    var repeatProblem: String? {
        repeatProblem(endsTooEarly: String(localized: "The repeat must end after the chore’s first day."))
    }

    /// What's wrong with it (the server's checks), nil when it can be saved.
    var problem: String? {
        if input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Give it a title.") }
        return repeatProblem
    }

    /// At a time (first the part's usual one), or any time of its part of the day.
    mutating func setTimed(_ timed: Bool) {
        setTime(timed ? usualTime(input.effectivePart(dayParts)) : nil)
    }

    /// The time; the part follows it, and stays when the time goes.
    mutating func setTime(_ time: String?) {
        input.time = time
        if let part = time.flatMap({ ChorePart.of(time: $0, in: dayParts) }) { input.part = part }
    }

    /// The editor's When: a part of the day, or at a time. Picking a part drops the time; picking
    /// At a Time sets the part's usual one (kept when there is a time already).
    var when: ChoreWhen {
        get { input.time == nil ? .part(input.part) : .atTime }
        set {
            switch newValue {
            case let .part(part):
                setTime(nil)
                input.part = part
            case .atTime:
                if input.time == nil { setTimed(true) }
            }
        }
    }

    /// When a part's chore without a time is due: when the part starts (the server's, for its
    /// notification).
    func usualTime(_ part: ChorePart) -> String { dayParts[part] }

    /// The notification for `id` on or off.
    mutating func setNotified(_ id: String, _ on: Bool) {
        input.subscriberIds.removeAll { $0 == id }
        if on { input.subscriberIds.append(id) }
    }

    /// What's sent: the title and note trimmed.
    var cleaned: ChoreInput {
        var input = input
        input.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        input.note = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return input
    }
}

/// The editor's When choices: a part of the day, or at a time (which decides the part).
enum ChoreWhen: Hashable {
    case part(ChorePart)
    case atTime
}

/// What the chores page opens its editor for.
enum ChoreEditorTarget: Identifiable, Hashable {
    case new
    case chore(Chore)

    var id: String {
        switch self {
        case .new: "new"
        case let .chore(chore): chore.id
        }
    }
}

/// The editor the chores pages open: a new chore (for the filter's person, on `day`) or one
/// (read-only without editing).
struct ChoreEditorHost: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyContext.self) private var family
    let target: ChoreEditorTarget
    let filter: ChoreFilter
    let day: Day

    var body: some View {
        let people = family.chores.page?.people ?? []
        let canEdit = family.chores.canEdit
        switch target {
        case .new:
            // A filter on someone: the new chore is theirs.
            let assignee: String? = if case let .person(id) = filter { id } else { nil }
            ChoreEditor(chore: nil, people: people,
                        draft: .new(on: day, for: assignee, me: app.me?.id, dayParts: family.chores.dayParts))
        case let .chore(chore):
            ChoreEditor(chore: chore, people: people, readOnly: !canEdit,
                        draft: ChoreDraft(input: ChoreInput(chore), dayParts: family.chores.dayParts))
        }
    }
}

/// Adds or edits a chore (through the `ChoresStore`: saved on the device at once, sent when the
/// server can be reached): a title, whom it's for, its day, part of the day (or time), how it
/// repeats like an event in the calendar, a note, who's notified. Viewers see it read-only, but
/// turn their own notification on or off.
struct ChoreEditor: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The chore being edited; nil: a new one.
    let chore: Chore?
    let people: [ChorePerson]
    /// Shown, not edited (viewers).
    let readOnly: Bool
    @State private var draft: ChoreDraft
    @State private var customRepeat = false
    @State private var confirmDelete = false
    /// Read-only: the account's own notification (changed at once).
    @State private var subscribed: Bool
    /// The draft as it opened, for Cancel.
    private let initial: ChoreDraft

    init(chore: Chore?, people: [ChorePerson], readOnly: Bool = false, draft: ChoreDraft) {
        self.chore = chore
        self.people = people
        self.readOnly = readOnly
        _draft = State(initialValue: draft)
        _subscribed = State(initialValue: chore?.subscribed ?? false)
        initial = draft
    }

    /// Who can be notified: the members with an account.
    private var accounts: [ChorePerson] { people.filter(\.account) }

    /// Whom it can be for: the family's people, and the one it's for even when they left.
    private var choices: [ChorePerson] {
        guard let assignee = chore?.assignee, !people.contains(where: { $0.id == assignee.id }) else { return people }
        return people + [assignee]
    }

    private var title: LocalizedStringKey {
        if readOnly { return "Chore" }
        return chore == nil ? "New Chore" : "Edit Chore"
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Title", text: $draft.input.title)
                            .accessibilityHint(Text("Required"))
                        Picker("Assigned to", selection: $draft.input.assigneeId) {
                            Text("Nobody").tag(String?.none)
                            ForEach(choices) { person in
                                Text(verbatim: person.name).tag(Optional(person.id))
                            }
                        }
                    }
                    Section {
                        DatePicker(draft.rule == nil ? "Due" : "Starts",
                                   selection: Binding(get: { draft.input.day.date }, set: { draft.input.day = Day($0) }),
                                   displayedComponents: .date)
                        // A part of the day, or at a time (the time decides the part).
                        Picker("When", selection: $draft.when) {
                            ForEach(ChorePart.allCases, id: \.self) { part in
                                Text(part.title).tag(ChoreWhen.part(part))
                            }
                            Text("At a Time").tag(ChoreWhen.atTime)
                        }
                        if let time = draft.input.time {
                            DatePicker("Time", selection: Binding(get: { CalendarEventSheet.date(of: time, on: draft.input.day) }, set: {
                                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                                draft.setTime(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
                            }), displayedComponents: .hourAndMinute)
                        }
                    }
                    CalendarEventRepeatSection(draft: $draft, custom: $customRepeat)
                    Section {
                        TextField("Note", text: $draft.input.note, axis: .vertical)
                            .lineLimit(2...6)
                    }
                }
                .disabled(readOnly)
                notifySection
                if let chore, !readOnly {
                    Section {
                        Button("Delete Chore", role: .destructive) { confirmDelete = true }
                    }
                    .alert(Text("Delete “\(chore.title)”?"), isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { delete(chore) }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .formStyle(.grouped)
            .readableWidth()
            .navigationTitle(title)
            .navigationDestination(isPresented: $customRepeat) {
                CalendarRepeatRuleEditor(draft: $draft)
            }
            .toolbar {
                if readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        CancelButton(hasChanges: draft != initial)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(draft.problem != nil)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .discardGuard(hasChanges: draft != initial)
        .errorBanner()
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    /// Editors pick who's notified (saved with the chore); a viewer turns their own on or off.
    @ViewBuilder private var notifySection: some View {
        if readOnly {
            if let chore {
                Section("Notify") {
                    Toggle("Notify me", isOn: Binding(get: { subscribed }, set: { subscribe(chore, $0) }))
                        .disabled(app.isDemo)
                }
            }
        } else if !accounts.isEmpty {
            Section("Notify") {
                ForEach(accounts) { person in
                    let on = draft.input.subscriberIds.contains(person.id)
                    Button { draft.setNotified(person.id, !on) } label: {
                        HStack {
                            Text(verbatim: person.name).foregroundStyle(.primary)
                            Spacer()
                            if on {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(ModuleTint.chores)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func subscribe(_ chore: Chore, _ on: Bool) {
        subscribed = on
        family.chores.subscribe(chore.id, on)
    }

    /// Unchanged: nothing to send.
    private func save() {
        if chore == nil || draft != initial { family.chores.save(draft.cleaned, editing: chore?.id) }
        dismiss()
    }

    private func delete(_ chore: Chore) {
        family.chores.delete(chore.id)
        dismiss()
    }
}

import SwiftUI

/// A new chore or one being edited: what the editor's fields hold. Its Repeat is
/// `RepeatEditing`'s, as an event's.
struct ChoreDraft: Equatable, RepeatEditing {
    var input: ChoreInput

    static func new(on day: Day, for assigneeID: String? = nil) -> ChoreDraft {
        ChoreDraft(input: ChoreInput(title: "", assigneeId: assigneeID, day: day))
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

    /// At a time, or any time of the day.
    mutating func setTimed(_ timed: Bool) {
        input.time = timed ? "09:00" : nil
    }

    /// What's sent: the title and note trimmed.
    var cleaned: ChoreInput {
        var input = input
        input.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        input.note = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return input
    }
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

/// Adds or edits a chore (POST /chores, PATCH /chores/{id}): a title, whom it's for, its day
/// (and time), how it repeats like an event in the calendar, a note. Viewers see it read-only.
struct ChoreEditor: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    /// The chore being edited; nil: a new one.
    let chore: Chore?
    let people: [ChorePerson]
    /// Shown, not edited (viewers).
    let readOnly: Bool
    @State private var draft: ChoreDraft
    @State private var saving = false
    @State private var customRepeat = false
    @State private var confirmDelete = false
    /// The draft as it opened, for Cancel.
    private let initial: ChoreDraft

    init(chore: Chore?, people: [ChorePerson], readOnly: Bool = false, draft: ChoreDraft) {
        self.chore = chore
        self.people = people
        self.readOnly = readOnly
        _draft = State(initialValue: draft)
        initial = draft
    }

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
                    Toggle("At a time", isOn: Binding(get: { draft.input.time != nil }, set: { draft.setTimed($0) }))
                    if let time = draft.input.time {
                        DatePicker("Time", selection: Binding(get: { CalendarEventSheet.date(of: time, on: draft.input.day) }, set: {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            draft.input.time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                        }), displayedComponents: .hourAndMinute)
                    }
                }
                CalendarEventRepeatSection(draft: $draft, custom: $customRepeat)
                Section {
                    TextField("Note", text: $draft.input.note, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    if let chore, chore.done, let date = chore.doneDate {
                        Text("Done \(date.formatted(date: .abbreviated, time: .shortened)).")
                    } else if draft.rule != nil {
                        Text("In Reminders, a repeating chore gets a new reminder each time, three hours before it’s due.")
                    }
                }
                if let chore, !readOnly {
                    Section {
                        Button("Delete Chore", role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(Text("Delete “\(chore.title)”?"), isPresented: $confirmDelete,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { delete(chore) }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(readOnly)
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
                            .disabled(draft.problem != nil || saving)
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

    /// Unchanged: nothing to send.
    private func save() {
        if chore != nil && draft == initial { return dismiss() }
        saving = true
        let input = draft.cleaned
        perform {
            defer { saving = false }
            try await ChoreActions.save(family, input, editing: chore?.id)
            dismiss()
        }
    }

    private func delete(_ chore: Chore) {
        perform {
            try await ChoreActions.delete(family, chore.id)
            dismiss()
        }
    }
}

/// The module's changes, shared by its screens; each tells the others what changed.
enum ChoreActions {
    static var today: [String: String?] { ["today": Day.today.description] }

    /// Adds a chore (`id` nil) or changes one.
    @discardableResult
    static func save(_ family: FamilyContext, _ input: ChoreInput, editing id: String?) async throws -> Chore {
        let response: ChoreResponse = if let id {
            try await family.api.send(.patch, "/chores/\(id)", query: today, body: input)
        } else {
            try await family.api.send(.post, "/chores", query: today, body: input)
        }
        family.didChange(.chores)
        return response.chore
    }

    static func delete(_ family: FamilyContext, _ id: String) async throws {
        try await family.api.perform(.delete, "/chores/\(id)")
        family.didChange(.chores)
        ErrorBanner.shared.success(String(localized: "Chore deleted."))
    }

    /// Ticks a single chore off, or opens it again.
    @discardableResult
    static func setDone(_ family: FamilyContext, _ id: String, _ done: Bool) async throws -> Chore {
        let response: ChoreResponse = try await family.api.send(.post, "/chores/\(id)/done", query: today,
                                                                body: ["done": done])
        family.didChange(.chores)
        return response.chore
    }
}

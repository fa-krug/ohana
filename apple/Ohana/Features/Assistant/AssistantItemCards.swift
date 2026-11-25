import SwiftUI

// The cards that offer an edit of the assistant: a question to answer, and the Reminders,
// calendar and notes edits to apply. Drawn by `AssistantItemView` (AssistantItemViews.swift).

// MARK: - The pieces every edit card shares

/// The first line of an edit card: what the assistant offers to change, with its icon.
struct AssistantEditCardHeader: View {
    let summary: String
    let systemImage: String

    var body: some View {
        Label {
            Text(verbatim: summary).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(ModuleTint.assistant)
        }
    }
}

/// The two buttons of an edit card while it waits: **Don't apply** and **Apply** (a spinner
/// while the apply is on its way).
struct AssistantEditApplyButtons: View {
    let summary: String
    var busy = false
    var enabled = true
    let decline: () -> Void
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Don’t Apply") { decline() }
                .buttonStyle(.bordered)
            Button {
                apply()
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Apply")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(ModuleTint.assistant)
            .accessibilityLabel(Text("Apply: \(summary)"))
        }
        .disabled(!enabled)
    }
}

/// The ops of an edit, one row under the other.
struct AssistantEditOpsList<Row: View>: View {
    let count: Int
    let row: (Int) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                row(index)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The card's note when the device won't let it work: what is missing, and the way to the
/// Settings (nothing there to open when the device itself refuses the whole thing).
struct AssistantNoAccessNote: View {
    /// What to say when the device itself won't allow this at all.
    let restrictedText: LocalizedStringKey
    /// What to say when only Ohana is missing the access.
    let deniedText: LocalizedStringKey
    let restricted: Bool
    let settingsURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(restricted ? restrictedText : deniedText, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if !restricted, let settingsURL {
                Link(destination: settingsURL) {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        }
        .font(.caption)
    }
}

extension AssistantEditOutcome {
    /// The line of an edit's outcome; nothing while the edit still waits for the user.
    @ViewBuilder static func line(outcome: String?, answer: AssistantRemindersEdit.Answer?) -> some View {
        if let outcome {
            AssistantEditOutcome(text: outcome, answer: answer)
        }
    }
}

// MARK: - The cards

/// A question of the assistant: a tap on an option answers it (or, with several to pick, ticks
/// it, and **Answer** sends the ticked ones). An own answer is written in the composer, whose Send
/// answers the question while it waits (with the ticked options). Once answered, it shows the answer.
struct AssistantQuestionCard: View {
    let question: AssistantQuestion
    let store: AssistantChatStore

    /// It waits for the user (the chat's last open question or edit), and whether a turn runs:
    /// given by the chat, which works them out once for all its items, so a card isn't drawn again
    /// with every piece of an answer being written.
    var isOpen = false
    var busy = false

    var body: some View {
        let open = isOpen
        let active = open && !busy
        let picked = store.picks(question)
        let chosen = question.answer?.selected ?? picked
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: question.question).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.self) { option in
                AssistantQuestionOptionRow(option: option, chosen: chosen.contains(option), multiple: question.multiple,
                                           open: open, active: active) {
                    if question.multiple {
                        store.togglePick(question, option)
                    } else {
                        store.answer(selected: [option], text: "")
                    }
                }
            }
            if open, question.multiple {
                HStack {
                    Spacer(minLength: 0)
                    Button("Answer") {
                        store.answer(selected: picked, text: "")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.assistant)
                    .disabled(!active || picked.isEmpty)
                }
            }
            if let own = question.answer?.text {
                AssistantUserBubble(text: own, attachments: [])
            }
            if question.skipped {
                Text("Not answered").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
    }
}

/// One option of a question: a button that answers with it (a question with one answer) or ticks
/// it (a question with several). The ticked box and the filled circle say it only to the eye.
private struct AssistantQuestionOptionRow: View {
    let option: String
    let chosen: Bool
    let multiple: Bool
    let open: Bool
    let active: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(chosen ? ModuleTint.assistant : .secondary)
                    .accessibilityHidden(true)
                Text(verbatim: option)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .background(chosen ? ModuleTint.assistant.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .opacity(!open && !chosen ? 0.6 : 1)
        .accessibilityLabel(Text(verbatim: option))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(hint)
    }

    /// The box or the circle, ticked or not.
    private var symbol: String {
        guard chosen else { return multiple ? "square" : "circle" }
        return multiple ? "checkmark.square.fill" : "largecircle.fill.circle"
    }

    private var hint: Text {
        guard open else { return Text(verbatim: "") }
        return multiple ? Text("Ticks or unticks it") : Text("Answers with it")
    }
}

/// A change of the user's Reminders the assistant suggests: what it does, op by op in plain
/// words (deletes in red), and **Apply** / **Don't apply** while it waits. Apply asks for the
/// access to Reminders first when it wasn't asked for yet (and points to the Settings when it was
/// refused). Once answered, each op shows how it went and the card how it ended.
struct AssistantRemindersCard: View {
    let edit: AssistantRemindersEdit
    let store: AssistantChatStore
    @State private var reminders = RemindersStore.shared
    @State private var posting = false
    /// Apply found no access.
    @State private var refused = false

    /// It waits for the user (the chat's last open question or edit), and whether a turn runs:
    /// given by the chat, which works them out once for all its items, so a card isn't drawn again
    /// with every piece of an answer being written.
    var isOpen = false
    var busy = false

    var body: some View {
        let open = isOpen
        let active = open && !busy && !posting
        VStack(alignment: .leading, spacing: 8) {
            AssistantEditCardHeader(summary: edit.summary, systemImage: "checklist")
            AssistantEditOpsList(count: edit.ops.count) { index in
                row(edit.ops[index], index: index, open: open)
            }
            if open || posting {
                if open, refused || reminders.access == .denied || reminders.access == .restricted
                    || reminders.access == .writeOnly {
                    noAccess
                }
                AssistantEditApplyButtons(summary: edit.summary, busy: posting, enabled: active,
                                          decline: { store.declineReminders(edit.id) }, apply: { apply() })
            }
            AssistantEditOutcome.line(outcome: edit.outcome, answer: edit.answer)
        }
        .contentCard(cornerRadius: 18, padding: 12)
        .task(id: reminders.revision) { reminders.refreshAccess() }
    }

    private func row(_ operation: AssistantReminderOp, index: Int, open: Bool) -> AssistantEditOpRow {
        // While it waits, an update to another list reads as a move (the reminder's list now).
        let currentList = open && operation.op == "update" && reminders.access.isGranted
            ? operation.id.flatMap { reminders.reminder($0)?.listID } : nil
        let line = AssistantReminderOpLine.make(operation, currentListID: currentList)
        return AssistantEditOpRow(icon: line.icon, text: line.text, detail: line.detail, destructive: line.destructive,
                                  result: edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil },
                                  declined: edit.answer?.applied == false || edit.skipped)
    }

    private var noAccess: some View {
        AssistantNoAccessNote(restrictedText: "Reminders aren’t allowed on this device.",
                              deniedText: "Ohana has no access to your reminders.",
                              restricted: reminders.access == .restricted,
                              settingsURL: reminders.access == .restricted ? nil : RemindersStore.settingsURL)
    }

    private func apply() {
        posting = true
        Task {
            defer { posting = false }
            refused = await store.applyReminders(edit.id) == .noAccess
        }
    }
}

/// A change of the device's calendars the assistant suggests, like the Reminders card: what it
/// does, op by op (the event, when it is, the calendar; deletes in red), and **Apply** /
/// **Don't apply** while it waits. Without access to the calendars (taken away since the message)
/// it points to the Settings. Once answered, each op shows how it went and the card how it ended.
struct AssistantCalendarCard: View {
    let edit: AssistantCalendarEdit
    let store: AssistantChatStore
    @State private var calendars = DeviceCalendarStore.shared
    /// Apply found no access.
    @State private var refused = false

    /// It waits for the user (the chat's last open question or edit), and whether a turn runs:
    /// given by the chat, which works them out once for all its items, so a card isn't drawn again
    /// with every piece of an answer being written.
    var isOpen = false
    var busy = false

    var body: some View {
        let open = isOpen
        let active = open && !busy
        VStack(alignment: .leading, spacing: 8) {
            AssistantEditCardHeader(summary: edit.summary, systemImage: "calendar")
            AssistantEditOpsList(count: edit.ops.count) { index in
                row(edit.ops[index], index: index, open: open)
            }
            if open {
                if refused || !calendars.hasAccess {
                    noAccess
                }
                AssistantEditApplyButtons(summary: edit.summary, enabled: active,
                                          decline: { store.declineCalendar(edit.id) }, apply: { apply() })
            }
            AssistantEditOutcome.line(outcome: edit.outcome, answer: edit.answer)
        }
        .contentCard(cornerRadius: 18, padding: 12)
        .task(id: calendars.revision) { calendars.refreshAccess() }
    }

    private func row(_ operation: AssistantCalendarOp, index: Int, open: Bool) -> AssistantEditOpRow {
        // While it waits, an update to another calendar reads as a move (the event's calendar now).
        let currentCalendar = open && operation.op == "update" && calendars.hasAccess
            ? operation.id.flatMap { calendars.calendarID(of: DeviceEventRef($0)) } : nil
        let line = AssistantCalendarOpLine.make(operation, currentCalendarID: currentCalendar)
        return AssistantEditOpRow(icon: line.icon, text: line.text, detail: line.detail, destructive: line.destructive,
                                  result: edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil },
                                  declined: edit.answer?.applied == false || edit.skipped)
    }

    private var noAccess: some View {
        AssistantNoAccessNote(restrictedText: "Calendars aren’t allowed on this device.",
                              deniedText: "Ohana has no access to your calendars.",
                              restricted: calendars.access == .restricted,
                              settingsURL: calendars.access == .restricted ? nil : DeviceCalendarStore.settingsURL)
    }

    private func apply() {
        // Applied right away (the answer then goes out like a message).
        refused = store.applyCalendar(edit.id) == .noAccess
    }
}

/// Notes for the family's knowledge folder the assistant suggests, like the Reminders card: each
/// note (made or changed, where, its tags) with what it writes (a new note's or a rewritten text
/// a few lines long until expanded, the text added, what is replaced), and **Apply** / **Don't
/// apply** while it waits (a new note never overwrites a file, a change only a file still as the
/// assistant read it). Once answered, each note shows how it went and the card how it ended.
struct AssistantNotesCard: View {
    let edit: AssistantNotesEdit
    let store: AssistantChatStore
    @State private var posting = false
    /// The ops whose text shows whole.
    @State private var expanded: Set<Int> = []

    /// It waits for the user (the chat's last open question or edit), and whether a turn runs:
    /// given by the chat, which works them out once for all its items, so a card isn't drawn again
    /// with every piece of an answer being written.
    var isOpen = false
    var busy = false

    var body: some View {
        let open = isOpen
        let active = open && !busy && !posting
        let declined = edit.answer?.applied == false || edit.skipped
        VStack(alignment: .leading, spacing: 8) {
            AssistantEditCardHeader(summary: edit.summary, systemImage: "note.text")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(edit.ops.enumerated()), id: \.offset) { index, operation in
                    let line = AssistantNoteOpLine.make(operation)
                    VStack(alignment: .leading, spacing: 4) {
                        AssistantEditOpRow(icon: line.icon, text: line.text, detail: line.detail, destructive: false,
                                           result: edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil },
                                           declined: declined)
                        if let preview = line.preview {
                            AssistantNotePreview(preview: preview, expanded: expanded.contains(index)) {
                                if expanded.remove(index) == nil { expanded.insert(index) }
                            }
                            .padding(.leading, 26)
                            .opacity(declined ? 0.6 : 1)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            if open || posting {
                AssistantEditApplyButtons(summary: edit.summary, busy: posting, enabled: active,
                                          decline: { store.declineNotes(edit.id) }, apply: { apply() })
            }
            AssistantEditOutcome.line(outcome: edit.outcome, answer: edit.answer)
        }
        .contentCard(cornerRadius: 18, padding: 12)
    }

    private func apply() {
        posting = true
        Task {
            defer { posting = false }
            _ = await store.applyNotes(edit.id)
        }
    }
}

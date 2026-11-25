import SwiftUI

/// The cards that offer an edit of the assistant: a question to answer, and the Reminders,
/// calendar and notes edits to apply. Drawn by `AssistantItemView` (AssistantItemViews.swift).

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
                let on = chosen.contains(option)
                Button {
                    if question.multiple {
                        store.togglePick(question, option)
                    } else {
                        store.answer(selected: [option], text: "")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on
                              ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                              : (question.multiple ? "square" : "circle"))
                            .foregroundStyle(on ? ModuleTint.assistant : .secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: option)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                    .background(on ? ModuleTint.assistant.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!active)
                .opacity(!open && !on ? 0.6 : 1)
                // The ticked box and filled circle say it only to the eye.
                .accessibilityLabel(Text(verbatim: option))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(open
                                   ? (question.multiple ? Text("Ticks or unticks it") : Text("Answers with it"))
                                   : Text(verbatim: ""))
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
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checklist").foregroundStyle(ModuleTint.assistant)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(edit.ops.enumerated()), id: \.offset) { index, op in
                    row(op, index: index, open: open)
                }
            }
            .padding(.vertical, 2)
            if open || posting {
                if open, refused || reminders.access == .denied || reminders.access == .restricted
                    || reminders.access == .writeOnly {
                    noAccess
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don’t Apply") {
                        store.declineReminders(edit.id)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        apply()
                    } label: {
                        if posting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Apply")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.assistant)
                    .accessibilityLabel(Text("Apply: \(edit.summary)"))
                }
                .disabled(!active)
            }
            if let outcome = edit.outcome {
                AssistantEditOutcome(text: outcome, answer: edit.answer)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
        .task(id: reminders.revision) { reminders.refreshAccess() }
    }

    private func row(_ op: AssistantReminderOp, index: Int, open: Bool) -> AssistantEditOpRow {
        // While it waits, an update to another list reads as a move (the reminder's list now).
        let currentList = open && op.op == "update" && reminders.access.isGranted
            ? op.id.flatMap { reminders.reminder($0)?.listID } : nil
        let line = AssistantReminderOpLine.make(op, currentListID: currentList)
        return AssistantEditOpRow(icon: line.icon, text: line.text, detail: line.detail, destructive: line.destructive,
                                  result: edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil },
                                  declined: edit.answer?.applied == false || edit.skipped)
    }

    private var noAccess: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(reminders.access == .restricted
                  ? "Reminders aren’t allowed on this device."
                  : "Ohana has no access to your reminders.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if reminders.access != .restricted, let url = RemindersStore.settingsURL {
                Link(destination: url) {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        }
        .font(.caption)
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
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "calendar").foregroundStyle(ModuleTint.assistant)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(edit.ops.enumerated()), id: \.offset) { index, op in
                    row(op, index: index, open: open)
                }
            }
            .padding(.vertical, 2)
            if open {
                if refused || !calendars.hasAccess {
                    noAccess
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don’t Apply") {
                        store.declineCalendar(edit.id)
                    }
                    .buttonStyle(.bordered)
                    Button("Apply") {
                        apply()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.assistant)
                    .accessibilityLabel(Text("Apply: \(edit.summary)"))
                }
                .disabled(!active)
            }
            if let outcome = edit.outcome {
                AssistantEditOutcome(text: outcome, answer: edit.answer)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
        .task(id: calendars.revision) { calendars.refreshAccess() }
    }

    private func row(_ op: AssistantCalendarOp, index: Int, open: Bool) -> AssistantEditOpRow {
        // While it waits, an update to another calendar reads as a move (the event's calendar now).
        let currentCalendar = open && op.op == "update" && calendars.hasAccess
            ? op.id.flatMap { calendars.calendarID(of: DeviceEventRef($0)) } : nil
        let line = AssistantCalendarOpLine.make(op, currentCalendarID: currentCalendar)
        return AssistantEditOpRow(icon: line.icon, text: line.text, detail: line.detail, destructive: line.destructive,
                                  result: edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil },
                                  declined: edit.answer?.applied == false || edit.skipped)
    }

    private var noAccess: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(calendars.access == .restricted
                  ? "Calendars aren’t allowed on this device."
                  : "Ohana has no access to your calendars.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if calendars.access != .restricted, let url = DeviceCalendarStore.settingsURL {
                Link(destination: url) {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        }
        .font(.caption)
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
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "note.text").foregroundStyle(ModuleTint.assistant)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(edit.ops.enumerated()), id: \.offset) { index, op in
                    let line = AssistantNoteOpLine.make(op)
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
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don’t Apply") {
                        store.declineNotes(edit.id)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        apply()
                    } label: {
                        if posting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Apply")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.assistant)
                    .accessibilityLabel(Text("Apply: \(edit.summary)"))
                }
                .disabled(!active)
            }
            if let outcome = edit.outcome {
                AssistantEditOutcome(text: outcome, answer: edit.answer)
            }
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

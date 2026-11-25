import SwiftUI

/// The chat's edit cards: what the assistant wants to change in the user's Reminders, in the
/// device's calendars and in the family's notes, op by op in plain words, with what each op did
/// once the user applied it here (web: components/assistant/items/*).

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

/// What an op of a notes edit writes: the text (a few lines until expanded), the text added (in
/// green), or each replacement (the old text struck through in red, the new one in green).
struct AssistantNotePreview: View {
    let preview: AssistantNoteOpLine.Preview
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch preview {
            case let .text(text):
                Text(verbatim: text)
                    .lineLimit(expanded ? nil : AssistantNoteOpLine.Preview.collapsedLines)
            case let .added(text):
                Text(verbatim: text)
                    .foregroundStyle(.green)
                    .lineLimit(expanded ? nil : AssistantNoteOpLine.Preview.collapsedLines)
                    .accessibilityLabel(Text("Added: \(text)"))
            case let .replacements(list):
                ForEach(Array(list.enumerated()), id: \.offset) { _, replacement in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: replacement.find)
                            .strikethrough()
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("Replaced: \(replacement.find)"))
                        if !replacement.with.isEmpty {
                            Text(verbatim: replacement.with)
                                .foregroundStyle(.green)
                                .accessibilityLabel(Text("With: \(replacement.with)"))
                        }
                    }
                    .lineLimit(expanded ? nil : 2)
                }
            }
            if preview.isLong {
                Button(expanded ? "Show Less" : "Show More", action: toggle)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ModuleTint.assistant)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}

/// One op of a Reminders or calendar edit: its icon, what it does and a fainter detail, and once
/// answered how it went (the error below it when it failed); faded when the edit wasn't applied.
struct AssistantEditOpRow: View {
    let icon: String
    let text: String
    let detail: String?
    let destructive: Bool
    let result: AssistantReminderResult?
    let declined: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(destructive ? Color.red : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                    .foregroundStyle(destructive ? Color.red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let error = result?.error, result?.ok == false {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let result, !result.isDeclined {
                Image(systemName: result.ok ? "checkmark" : "exclamationmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(result.ok ? Color.green : .red)
                    .transition(.symbolEffect(.appear))
                    .accessibilityLabel(result.ok ? Text("Done") : Text("Failed"))
            }
        }
        .animation(.snappy, value: result?.ok)
        .font(.callout)
        .opacity(declined || result?.isDeclined == true ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

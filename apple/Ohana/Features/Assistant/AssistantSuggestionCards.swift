import SwiftUI

// The card that offers the suggestions the assistant found, to add, and how an edit of the chat
// ended. Drawn by `AssistantItemView` (AssistantItemViews.swift).

/// Events, tasks and deadlines the assistant found (e.g. in a scanned letter), to pick from: one
/// row per suggestion with a tick (all ticked at first), what it is, when, and a fainter detail;
/// **Add N** / **Don't add** while it waits. Add asks for the access to Reminders first when a
/// task or deadline is ticked (and points to the Settings when it was refused: those can be
/// unticked and the rest added). Once answered, each row shows how it went and the card how it
/// ended.
struct AssistantSuggestionsCard: View {
    let edit: AssistantSuggestions
    let store: AssistantChatStore
    @State private var reminders = RemindersStore.shared
    @State private var posting = false
    /// Add found no access to Reminders.
    @State private var refused = false

    /// It waits for the user (the chat's last open question or edit), and whether a turn runs:
    /// given by the chat, which works them out once for all its items, so a card isn't drawn again
    /// with every piece of an answer being written.
    var isOpen = false
    var busy = false

    var body: some View {
        let open = isOpen
        let active = open && !busy && !posting
        let picks = store.picks(edit)
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.text.viewfinder").foregroundStyle(ModuleTint.assistant)
            }
            if let source = edit.source {
                Text(verbatim: source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(edit.ops.enumerated()), id: \.offset) { index, op in
                    AssistantSuggestionRow(
                        line: AssistantSuggestionLine.make(op), picked: picks.contains(index), open: open || posting,
                        enabled: active, result: edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil },
                        declined: edit.answer?.applied == false || edit.skipped
                    ) {
                        store.togglePick(edit, index)
                    }
                }
            }
            if open || posting {
                if open, edit.needsReminders(picks), refused || reminders.access == .denied
                    || reminders.access == .restricted || reminders.access == .writeOnly {
                    noAccess
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don’t Add") {
                        store.declineSuggestions(edit.id)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        add(picks)
                    } label: {
                        if posting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Add \(picks.count)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.assistant)
                    .disabled(picks.isEmpty)
                    .accessibilityLabel(Text("Add \(picks.count): \(edit.summary)"))
                }
                .disabled(!active)
            }
            if let outcome = edit.outcome {
                AssistantEditOutcome(text: outcome, answer: edit.answer)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
        .task(id: reminders.revision) { reminders.refreshAccess() }
        .onChange(of: picks) { refused = false }
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

    private func add(_ picks: Set<Int>) {
        posting = true
        Task {
            defer { posting = false }
            refused = await store.applySuggestions(edit.id, selected: picks) == .noAccess
        }
    }
}

/// One suggestion of the card: while it waits a tap ticks or unticks it; once answered it shows
/// how it went (added, left out: faded, failed: in orange with the error).
struct AssistantSuggestionRow: View {
    let line: AssistantSuggestionLine
    let picked: Bool
    /// It waits (or is being added): the tick shows.
    let open: Bool
    let enabled: Bool
    let result: AssistantReminderResult?
    /// None of them was added (Don't add, or a new message instead).
    let declined: Bool
    let toggle: () -> Void

    var body: some View {
        Group {
            if open {
                Button { withAnimation(.snappy) { toggle() } } label: { content }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                    .accessibilityHint(Text("Ticks or unticks it"))
            } else {
                content
            }
        }
        // Answered: the tick gives way to how it went.
        .animation(.snappy, value: open)
    }

    private var faded: Bool { declined || result?.isDeclined == true }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if open {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? ModuleTint.assistant : .secondary)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                    .accessibilityHidden(true)
            }
            Image(systemName: line.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: line.title)
                    .fixedSize(horizontal: false, vertical: true)
                if let when = line.when {
                    Text(verbatim: when)
                        .font(.caption)
                }
                if let detail = line.detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let result, result.failed {
                    Text(verbatim: result.error ?? "")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let result {
                if result.ok {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Added"))
                } else if result.failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Failed"))
                } else {
                    Text("Not added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 6)
        .padding(.horizontal, open ? 4 : 0)
        .frame(minHeight: open ? 44 : nil)
        .contentShape(.rect)
        .opacity(faded ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// How a Reminders or calendar edit ended: applied (some ops failed: in orange), not applied, not
/// answered.
struct AssistantEditOutcome: View {
    let text: String
    let answer: AssistantRemindersEdit.Answer?

    var body: some View {
        let applied = answer?.applied == true
        let failed = (answer?.failures ?? 0) > 0
        Label {
            Text(verbatim: text)
        } icon: {
            if applied {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.orange : .green)
                    .transition(.symbolEffect(.appear))
            } else if answer != nil {
                Image(systemName: "xmark.circle")
                    .transition(.symbolEffect(.appear))
            }
        }
        .animation(.snappy, value: answer?.applied)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

import SwiftUI

/// One item of the chat: a message, a tool call, a change with undo, a question, a Reminders,
/// calendar or notes edit to apply, suggestions to add, a document's pages to send, a note.
/// Equal for the same item (`.equatable()`): the closure would otherwise draw every item again
/// whenever the chat does (a keystroke, another module beside the panel).
struct AssistantItemView: View, Equatable {
    @Environment(FamilyContext.self) private var family
    let item: AssistantItem
    let store: AssistantChatStore
    /// The chat is its copy on the device: no undo meanwhile.
    var saved = false
    /// It is the chat's question or edit that waits for the user (`AssistantChatStore.waitingIndex`).
    var waiting = false
    /// A turn runs (or a message is on its way): what waits can't be answered meanwhile.
    var busy = false
    /// Opens a place of the app a tool call names.
    var open: (AppRoute) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // `busy` counts only for what can wait: the other items aren't drawn again as turns start and end.
        lhs.item == rhs.item && lhs.store === rhs.store && lhs.saved == rhs.saved && lhs.waiting == rhs.waiting
            && (lhs.busy == rhs.busy || !lhs.item.canWait)
    }

    var body: some View {
        switch item {
        case let .user(text, attachments):
            AssistantUserBubble(text: text, attachments: attachments)
        case let .assistant(text, sources):
            AssistantAnswerView(text: text, sources: sources, familyID: family.family.id, open: open)
                .padding(.horizontal, 4)
        case let .tool(tool):
            AssistantToolRow(tool: tool, route: AssistantToolLinks.route(tool, familyID: family.family.id), open: open)
        case let .change(change):
            AssistantChangeRow(change: change, canUndo: !saved) {
                await store.undo(change.id)
            }
        case let .question(question):
            AssistantQuestionCard(question: question, store: store, isOpen: waiting, busy: busy)
        case let .reminders(edit):
            AssistantRemindersCard(edit: edit, store: store, isOpen: waiting, busy: busy)
        case let .calendar(edit):
            AssistantCalendarCard(edit: edit, store: store, isOpen: waiting, busy: busy)
        case let .suggestions(edit):
            AssistantSuggestionsCard(edit: edit, store: store, isOpen: waiting, busy: busy)
        case let .notes(edit):
            AssistantNotesCard(edit: edit, store: store, isOpen: waiting, busy: busy)
        case let .memories(edit):
            AssistantMemoriesCard(edit: edit, store: store, isOpen: waiting, busy: busy)
        case let .pages(request):
            AssistantPagesCard(request: request, store: store, isOpen: waiting, busy: busy, open: open)
        case .compacted:
            HStack(spacing: 8) {
                VStack { Divider() }
                Text("Earlier messages condensed for the model")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
                VStack { Divider() }
            }
            .help(Text("How much of the model’s context window this chat uses. Before it is full, older messages are condensed into a summary, so long tasks can go on."))
        case let .error(text):
            Label {
                Text(verbatim: text)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .contentCard(cornerRadius: 14, padding: 10, tint: .red)
        case .unknown:
            EmptyView()
        }
    }
}

/// A message of the user: a tinted bubble on the right, with its attachments.
struct AssistantUserBubble: View {
    let text: String
    let attachments: [AssistantAttachmentRef]
    var queued = false

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    AssistantFlow(spacing: 6) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, sent in
                            AssistantSentAttachment(attachment: sent, onTint: !queued)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(verbatim: text)
                        // iOS selects in a sheet (the message's Select Text): selectable text is
                        // costly to lay out there.
                        #if os(macOS)
                        .textSelection(.enabled)
                        #endif
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(queued ? Color.primary : Color.white)
            .background {
                if queued {
                    UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6,
                                           topTrailingRadius: 18)
                        .strokeBorder(ModuleTint.assistant.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .background(ModuleTint.assistant.opacity(0.06), in: .rect(cornerRadius: 18))
                } else {
                    UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6,
                                           topTrailingRadius: 18)
                        .fill(ModuleTint.assistant.gradient)
                }
            }
        }
    }
}

/// An attachment of a sent message: the picture (tap for full size) or a file chip.
struct AssistantSentAttachment: View {
    let attachment: AssistantAttachmentRef
    var onTint = true
    @State private var image: Image?
    @State private var zoomed = false

    var body: some View {
        Group {
            if let image {
                Button { zoomed = true } label: {
                    image.resizable().scaledToFill()
                        .frame(width: 120, height: 120)
                        .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: attachment.name))
                .sheet(isPresented: $zoomed) {
                    NavigationStack {
                        image.resizable().scaledToFit()
                            .padding()
                            .navigationTitle(Text(verbatim: attachment.name))
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { zoomed = false }
                                }
                            }
                    }
                    .errorBanner()
                    .frame(minWidth: 320, minHeight: 320)
                }
            } else {
                Label {
                    Text(verbatim: attachment.name).lineLimit(1)
                } icon: {
                    Image(systemName: attachment.kind == "image" ? "photo" : "doc.text")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((onTint ? Color.white : Color.secondary).opacity(0.18), in: .rect(cornerRadius: 8))
                .help(attachment.kind == "image" ? Text("The image is no longer stored.") : Text(verbatim: attachment.name))
            }
        }
        .task(id: attachment.url) {
            image = attachment.url.flatMap(AssistantAttachments.image(dataURL:))
        }
    }
}

/// A tool call: what it does, what it is about, and how it went.
struct AssistantToolRow: View {
    let tool: AssistantToolCall
    /// Where the app shows what the call was about (a tap opens it).
    var route: AppRoute?
    var open: (AppRoute) -> Void = { _ in }

    var body: some View {
        if let route {
            Button {
                open(route)
            } label: {
                row(linked: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows it in the app"))
        } else {
            row(linked: false)
        }
    }

    private func row(linked: Bool) -> some View {
        let label = AssistantToolLabels.label(tool)
        let detail = AssistantToolLabels.detail(tool)
        return HStack(spacing: 8) {
            Image(systemName: AssistantToolLabels.icon(tool.name))
                .frame(width: 16)
            Text(Self.line(label, detail, linked: linked))
                .lineLimit(1)
                .truncationMode(.tail)
            if linked {
                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ModuleTint.assistant)
            }
            Spacer(minLength: 0)
            switch tool.status {
            case "running":
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(Text("Running"))
            case "ok":
                Image(systemName: "checkmark").font(.caption2.bold())
                    .accessibilityLabel(Text("Done"))
            default:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    .accessibilityLabel(Text("Failed"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .help(Text(verbatim: [label, detail, tool.interrupted ? String(localized: "Interrupted") : tool.summary ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")))
        .accessibilityElement(children: .combine)
    }

    /// The label, then the detail a little fainter.
    static func line(_ label: String, _ detail: String, linked: Bool = false) -> AttributedString {
        var written = AttributedString(label)
        if !detail.isEmpty {
            var fainter = AttributedString(" · " + detail)
            fainter.foregroundColor = linked ? ModuleTint.assistant : .secondary.opacity(0.7)
            written += fainter
        }
        return written
    }
}

/// A change the assistant made, with its undo.
struct AssistantChangeRow: View {
    let change: AssistantChange
    var canUndo = true
    let undo: () async -> Void
    @State private var undoing = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: change.summary)
                .strikethrough(change.undone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // The summary wraps, never the button or the note beside it.
            if change.undone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else if !change.undo.isEmpty {
                Button {
                    Task {
                        undoing = true
                        await undo()
                        undoing = false
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(undoing || !canUndo)
                .accessibilityLabel(Text("Undo: \(change.summary)"))
            }
        }
        .font(.callout)
        .opacity(change.undone ? 0.6 : 1)
        .contentCard(cornerRadius: 14, padding: 10)
    }
}

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

/// A message that waits for the answer to end (it goes next); it can be taken back until then.
struct AssistantQueuedRow: View {
    let entry: AssistantQueued
    let store: AssistantChatStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            AssistantUserBubble(
                text: entry.text,
                attachments: (entry.attachments ?? []).map { .init(kind: $0.kind, name: $0.name) },
                queued: true
            )
            HStack(spacing: 6) {
                Label("Queued", systemImage: "clock")
                if entry.isLocal {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await store.unqueue(entry.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            // A finger-sized target around the small icon, without growing the row.
                            .padding(12)
                            .contentShape(.rect)
                            .padding(-12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Take back this message"))
                    .help(Text("Take back this message"))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// What the assistant is doing right now, under the chat while it answers: the sparkles, gently
/// pulsing on iOS (still under Reduce Motion, and always on the Mac), and the status, cross-fading
/// as it changes. The only thing in the chat that moves on its own; nothing ticks: "Writing…" turns
/// into "Thinking…" after a pause by a task that waits for that moment.
struct AssistantActivityLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: AssistantChatStore

    /// After this long without a new piece of text, the model is busy with its next step.
    private static let writingPause: TimeInterval = 2

    /// The piece of text (its time) the pause came after.
    @State private var pausedAfter: Date?

    var body: some View {
        let state = store.activity
        let status = text(state)
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(ModuleTint.assistant)
                // Not on the Mac: there the repeating pulse drew a frame after frame that waited
                // for the window server (for good while the window was covered), and the main
                // actor's tasks never got their turn: the chat's stream didn't end, it showed
                // "Thinking…" for good and nothing more could be sent.
                #if os(iOS)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                #endif
                .accessibilityHidden(true)
            Text(verbatim: status)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .task(id: state?.at) {
            guard let state, state.activity.kind == "writing" else { return }
            let left = state.at.addingTimeInterval(Self.writingPause).timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled else { return }
            pausedAfter = state.at
        }
    }

    private func text(_ state: AssistantActivityState?) -> String {
        guard let state else { return String(localized: "Thinking…") }
        let running = (store.current?.items ?? []).compactMap { item -> AssistantToolCall? in
            if case let .tool(call) = item, call.status == "running" { call } else { nil }
        }
        switch state.activity.kind {
        case "retrying":
            let tries = state.activity.attempt ?? 1, max = state.activity.max ?? 1
            return String(localized: "The model didn’t answer – trying again (\(tries)/\(max))…")
        case "compacting":
            return String(localized: "Condensing the earlier conversation…")
        case "tool" where !running.isEmpty:
            let more = running.count > 1 ? " (+\(running.count - 1))" : ""
            return AssistantToolLabels.label(running[running.count - 1]) + more + "…"
        case "writing" where pausedAfter != state.at:
            return String(localized: "Writing…")
        default:
            return String(localized: "Thinking…")
        }
    }
}

/// How much of the model's context window the open chat uses; the worker condenses the older
/// messages before it is full. The composer shows it only once that is near (`shows`, in orange).
struct AssistantContextMeter: View {
    let usage: AssistantUsage

    /// From this share of the window on, the meter shows (orange).
    static let warning = 70

    static func percent(_ usage: AssistantUsage) -> Int {
        Int((min(1, usage.used / Swift.max(usage.max, 1)) * 100).rounded())
    }

    static func shows(_ usage: AssistantUsage) -> Bool {
        usage.max > 0 && percent(usage) >= warning
    }

    var body: some View {
        let fraction = min(1, usage.used / Swift.max(usage.max, 1))
        let pct = Self.percent(usage)
        let used = usage.used.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        let max = usage.max.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .tint(pct >= Self.warning ? .orange : ModuleTint.assistant)
                .frame(minWidth: 40)
            Text("Context: \(used) of \(max) tokens (\(pct)%)")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(Text("How much of the model’s context window this chat uses. Before it is full, older messages are condensed into a summary, so long tasks can go on."))
        .accessibilityElement(children: .combine)
    }
}

/// Lays out chips in rows (attachments).
struct AssistantFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var left = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: left, y: top), proposal: .unspecified)
                left += size.width + spacing
            }
            top += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

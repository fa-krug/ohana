import SwiftUI

/// One item of the chat: a message, a tool call, a change with undo, a question, a Reminders or
/// calendar edit to apply, a note.
/// Equal for the same item (`.equatable()`): the closure would otherwise draw every item again
/// whenever the chat does (a keystroke, another module beside the panel).
struct AssistantItemView: View, Equatable {
    @Environment(FamilyContext.self) private var family
    let item: AssistantItem
    let store: AssistantChatStore
    /// The chat is its copy on the device: no undo meanwhile.
    var saved = false
    /// Opens a place of the app a tool call names.
    var open: (AppRoute) -> Void = { _ in }

    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.store === b.store && a.saved == b.saved
    }

    var body: some View {
        switch item {
        case let .user(text, attachments):
            AssistantUserBubble(text: text, attachments: attachments)
        case let .assistant(text):
            AssistantMarkdownView(text: text)
                .padding(.horizontal, 4)
        case let .tool(tool):
            AssistantToolRow(tool: tool, route: AssistantToolLinks.route(tool, familyID: family.family.id), open: open)
        case let .change(change):
            AssistantChangeRow(change: change, canUndo: !saved) {
                await store.undo(change.id)
            }
        case let .question(question):
            AssistantQuestionCard(question: question, store: store)
        case let .reminders(edit):
            AssistantRemindersCard(edit: edit, store: store)
        case let .calendar(edit):
            AssistantCalendarCard(edit: edit, store: store)
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
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in
                            AssistantSentAttachment(attachment: a, onTint: !queued)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(verbatim: text)
                        .textSelection(.enabled)
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
        var s = AttributedString(label)
        if !detail.isEmpty {
            var d = AttributedString(" · " + detail)
            d.foregroundColor = linked ? ModuleTint.assistant : .secondary.opacity(0.7)
            s += d
        }
        return s
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
            if change.undone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else if !change.undo.isEmpty {
                Button {
                    Task {
                        undoing = true
                        await undo()
                        undoing = false
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
/// it), and an own answer can be written instead or as well. Once answered, it shows the answer.
struct AssistantQuestionCard: View {
    let question: AssistantQuestion
    let store: AssistantChatStore
    @State private var picked: [String] = []
    @State private var text = ""

    private var isOpen: Bool { store.openQuestion()?.question.id == question.id }

    var body: some View {
        let open = isOpen
        let active = open && !store.busy
        let chosen = question.answer?.selected ?? picked
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: question.question).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if open {
                Text(question.multiple ? "Pick one or more, or write your own answer" : "Pick one, or write your own answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(question.options, id: \.self) { option in
                let on = chosen.contains(option)
                Button {
                    if question.multiple {
                        if let i = picked.firstIndex(of: option) { picked.remove(at: i) } else { picked.append(option) }
                    } else {
                        store.answer(selected: [option], text: text)
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
            if open {
                HStack(spacing: 8) {
                    TextField("Your own answer…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                        .disabled(!active)
                    Button("Answer", action: submit)
                        .buttonStyle(.borderedProminent)
                        .tint(ModuleTint.assistant)
                        .disabled(!active || (text.trimmingCharacters(in: .whitespaces).isEmpty
                                              && !(question.multiple && !picked.isEmpty)))
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

    private func submit() {
        store.answer(selected: question.multiple ? picked : [], text: text)
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

    private var isOpen: Bool { store.openRemindersEdit()?.edit.id == edit.id }

    var body: some View {
        let open = isOpen
        let active = open && !store.busy && !posting
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checklist").foregroundStyle(ModuleTint.assistant)
            }
            if open {
                Text("Nothing changes in your Reminders until you apply it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var isOpen: Bool { store.openCalendarEdit()?.edit.id == edit.id }

    var body: some View {
        let open = isOpen
        let active = open && !store.busy
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "calendar").foregroundStyle(ModuleTint.assistant)
            }
            if open {
                Text("Nothing changes in your calendars until you apply it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            if let result {
                Image(systemName: result.ok ? "checkmark" : "exclamationmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(result.ok ? Color.green : .red)
                    .accessibilityLabel(result.ok ? Text("Done") : Text("Failed"))
            }
        }
        .font(.callout)
        .opacity(declined ? 0.6 : 1)
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
            } else if answer != nil {
                Image(systemName: "xmark.circle")
            }
        }
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

/// What the assistant is doing right now, under the chat while it answers.
struct AssistantActivityLine: View {
    let store: AssistantChatStore

    /// After this long without a new piece of text, the model is busy with its next step.
    private static let writingPause: TimeInterval = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let a = store.activity
            let since = a?.at ?? context.date
            let secs = Int(context.date.timeIntervalSince(since))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: text(a, now: context.date))
                    .lineLimit(1)
                if secs >= 5 {
                    Text(verbatim: "\(secs) s").monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private func text(_ a: AssistantActivityState?, now: Date) -> String {
        guard let a else { return String(localized: "Thinking…") }
        let running = (store.current?.items ?? []).compactMap { item -> AssistantToolCall? in
            if case let .tool(t) = item, t.status == "running" { t } else { nil }
        }
        switch a.activity.kind {
        case "retrying":
            let n = a.activity.attempt ?? 1, max = a.activity.max ?? 1
            return String(localized: "The model didn’t answer – trying again (\(n)/\(max))…")
        case "compacting":
            return String(localized: "Condensing the earlier conversation…")
        case "tool" where !running.isEmpty:
            let more = running.count > 1 ? " (+\(running.count - 1))" : ""
            return AssistantToolLabels.label(running[running.count - 1]) + more + "…"
        case "writing" where now.timeIntervalSince(a.at) < Self.writingPause:
            return String(localized: "Writing…")
        default:
            return String(localized: "Thinking…")
        }
    }
}

/// How much of the model's context window the open chat uses; the worker condenses the older
/// messages before it is full (the bar turns orange when that is near).
struct AssistantContextMeter: View {
    let usage: AssistantUsage

    var body: some View {
        let fraction = min(1, usage.used / Swift.max(usage.max, 1))
        let pct = Int((fraction * 100).rounded())
        let used = usage.used.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        let max = usage.max.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .tint(pct >= 70 ? .orange : ModuleTint.assistant)
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
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
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

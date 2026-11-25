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
            .help(AssistantContextMeter.helpNote)
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
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, sentAttachment in
                            AssistantSentAttachment(attachment: sentAttachment, onTint: !queued)
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
        var lineText = AttributedString(label)
        if !detail.isEmpty {
            var detailText = AttributedString(" · " + detail)
            detailText.foregroundColor = linked ? ModuleTint.assistant : .secondary.opacity(0.7)
            lineText += detailText
        }
        return lineText
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

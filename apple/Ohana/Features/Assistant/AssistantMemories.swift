import SwiftUI

// What the assistant offers to remember, change or forget (server: the edit_memories tool). Like
// the suggestions nothing is saved until the user picks which ops on the card
// (`AssistantMemoriesCard`, all ticked at first, a new or changed text editable in place) and taps
// Save; the app saves them through the memory routes (`AssistantMemoriesApply`: POST / PATCH /
// DELETE /ai/memories) and answers POST /ai/chats/{id}/memories with one result per op, the ones
// left out `{ok: false, declined: true}`. Ops that fail keep the card open with their error, and
// Save tries them again (the ones that went through aren't repeated); Not Now answers with what
// went through and declines the rest.

/// The memory changes of one tool call (`kind: "memories"`).
nonisolated struct AssistantMemoriesEdit: Equatable, Sendable {
    var id: String
    /// What it offers, e.g. "Remember 2 things for Finance".
    var summary: String
    var ops: [AssistantMemoryOp]
    /// Saved (with each op's result) or declined.
    var answer: Answer?
    /// The user wrote a new message instead.
    var skipped: Bool

    typealias Answer = AssistantRemindersEdit.Answer

    /// Ticked at first: every op this app can apply.
    var initialPicks: Set<Int> {
        Set(ops.indices.filter { ops[$0].action != .unknown })
    }

    /// How it ended, in a few words ("Saved 2 of 3"); nil while it waits.
    var outcome: String? {
        guard let answer else { return skipped ? String(localized: "Not answered") : nil }
        let results = answer.applied ? answer.results ?? [] : []
        let saved = results.filter(\.ok).count
        let failed = results.filter(\.failed).count
        let total = ops.count
        var text = saved == 0 ? String(localized: "Nothing saved") : String(localized: "Saved \(saved) of \(total)")
        if failed > 0 { text += ", " + String(localized: "\(failed) failed") }
        return text
    }
}

/// One change of the memory, as the server resolved it: add (`module`, `text`), update (`id`, the
/// new `module` and `text`, `old` {module, text}), remove (`id`, its `module` and `text`). Decoded
/// leniently: an action this app doesn't know keeps its name (and can't be applied).
nonisolated struct AssistantMemoryOp: Decodable, Equatable, Sendable {
    nonisolated enum Action: Equatable, Sendable {
        case add, update, remove, unknown

        init(_ name: String) {
            switch name {
            case "add": self = .add
            case "update": self = .update
            case "remove": self = .remove
            default: self = .unknown
            }
        }
    }

    nonisolated struct Old: Decodable, Equatable, Sendable {
        var module: AssistantMemoryModule?
        var text: String
    }

    /// add | update | remove
    var name: String
    /// The memory (update, remove).
    var id: String?
    var module: AssistantMemoryModule
    var text: String
    var old: Old?

    var action: Action { Action(name) }

    init(action: String, id: String? = nil, module: AssistantMemoryModule = .general, text: String, old: Old? = nil) {
        self.name = action
        self.id = id
        self.module = module
        self.text = text
        self.old = old
    }

    private enum Keys: String, CodingKey {
        case action, id, module, text, old
    }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            self.init(action: "", text: "")
            return
        }
        func opt(_ key: Keys) -> String? {
            guard let text = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init(action: opt(.action) ?? "", id: opt(.id),
                  module: opt(.module).map(AssistantMemoryModule.init(rawValue:)) ?? .general,
                  text: opt(.text) ?? "", old: try? c.decodeIfPresent(Old.self, forKey: .old))
    }

    /// Its text can be changed on the card (what's saved).
    var editable: Bool { action == .add || action == .update }
}

/// Saves memories (tests fake it).
protocol AssistantMemoryWriting {
    /// The new memory's id.
    func add(module: AssistantMemoryModule, text: String) async throws -> String
    func update(id: String, module: AssistantMemoryModule, text: String) async throws
    func remove(id: String) async throws
}

/// The memory routes of the family API.
struct FamilyMemoryWriter: AssistantMemoryWriting {
    let api: FamilyAPI

    func add(module: AssistantMemoryModule, text: String) async throws -> String {
        try await api.send(.post, "/ai/memories", body: AssistantMemoryInput(module: module.rawValue, text: text),
                           as: AssistantMemory.self).id
    }

    func update(id: String, module: AssistantMemoryModule, text: String) async throws {
        _ = try await api.send(.patch, "/ai/memories/\(id)", body: AssistantMemoryInput(module: module.rawValue, text: text),
                               as: AssistantMemory.self)
    }

    func remove(id: String) async throws {
        do {
            try await api.perform(.delete, "/ai/memories/\(id)")
        } catch APIError.http(404, _) {
            // Gone already: what was asked for.
        }
    }
}

/// Applies the picked ops, in order, and says how each went.
enum AssistantMemoriesApply {
    /// Every picked op is tried (one that fails doesn't stop the others) unless it went through
    /// before (`previous`: an earlier Save of the same card); the ones left out are `declined`.
    /// `texts`: what the user changed an op's text to.
    static func perform(_ ops: [AssistantMemoryOp], picks: Set<Int>, texts: [Int: String] = [:],
                        previous: [Int: AssistantReminderResult] = [:],
                        writer: any AssistantMemoryWriting) async -> [AssistantReminderResult] {
        var results: [AssistantReminderResult] = []
        for (index, op) in ops.enumerated() {
            guard picks.contains(index) else {
                results.append(.declined)
                continue
            }
            if let done = previous[index], done.ok {
                results.append(done)
                continue
            }
            do {
                switch op.action {
                case .add:
                    let text = try valid(texts[index] ?? op.text)
                    results.append(.done(try await writer.add(module: op.module, text: text)))
                case .update:
                    guard let id = op.id else { throw ApplyError.unsupported }
                    let text = try valid(texts[index] ?? op.text)
                    try await writer.update(id: id, module: op.module, text: text)
                    results.append(.done(id))
                case .remove:
                    guard let id = op.id else { throw ApplyError.unsupported }
                    try await writer.remove(id: id)
                    results.append(.done(id))
                case .unknown:
                    throw ApplyError.unsupported
                }
            } catch {
                results.append(.failed(error.localizedDescription))
            }
        }
        return results
    }

    /// The text trimmed, if the server takes it (1–300 characters).
    static func valid(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= AssistantMemoryModule.maxLength else { throw ApplyError.length }
        return trimmed
    }

    enum ApplyError: LocalizedError {
        case unsupported
        case length

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "This version of Ohana can’t do this.")
            case .length: String(localized: "A memory has 1 to 300 characters.")
            }
        }
    }
}

// MARK: The card

/// What the assistant offers to remember, change or forget: one row per op with a tick (all ticked
/// at first), the module, and the text (a new or changed one editable while it waits; a change
/// shows the old text above, what's forgotten is struck through); **Save N** / **Not Now** while
/// it waits. Ops that failed show their error and stay ticked for the next Save. Once answered,
/// each row shows how it went and the card how it ended.
struct AssistantMemoriesCard: View {
    let edit: AssistantMemoriesEdit
    let store: AssistantChatStore
    @Environment(FamilyContext.self) private var family
    @State private var posting = false

    /// It waits for the user (the chat's last open question or edit), and whether a turn runs:
    /// given by the chat, which works them out once for all its items.
    var isOpen = false
    var busy = false

    var body: some View {
        // Only editors save memories (the server doesn't offer the tool to viewers).
        let open = isOpen && family.canEdit
        let active = open && !busy && !posting
        let picks = store.picks(edit)
        let tried = store.memoryResults[edit.id] ?? [:]
        let declined = edit.answer?.applied == false || edit.skipped
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: edit.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "brain").foregroundStyle(ModuleTint.assistant)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(edit.ops.enumerated()), id: \.offset) { index, op in
                    let answered = edit.answer?.results.flatMap { index < $0.count ? $0[index] : nil }
                    let result = answered ?? tried[index]
                    AssistantMemoryOpRow(
                        op: op, text: text(index, op), picked: picks.contains(index), open: open || posting,
                        enabled: active && result?.ok != true, result: result, declined: declined
                    ) {
                        store.togglePick(edit, index)
                    }
                }
            }
            if open || posting {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Not Now") {
                        store.declineMemories(edit.id)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        save()
                    } label: {
                        if posting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save \(picks.count)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.assistant)
                    .disabled(picks.isEmpty)
                    .accessibilityLabel(Text("Save \(picks.count): \(edit.summary)"))
                }
                .disabled(!active)
            }
            if let outcome = edit.outcome {
                AssistantEditOutcome(text: outcome, answer: edit.answer)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
    }

    /// The op's text as the card edits it.
    private func text(_ index: Int, _ op: AssistantMemoryOp) -> Binding<String> {
        Binding {
            store.memoryText(edit, index)
        } set: {
            store.setMemoryText(edit, index, $0)
        }
    }

    private func save() {
        posting = true
        Task {
            defer { posting = false }
            await store.applyMemories(edit.id)
        }
    }
}

/// One op of the memories card: while it waits a tap on the tick ticks or unticks it and a new or
/// changed text can be edited; once answered (or tried) it shows how it went.
struct AssistantMemoryOpRow: View {
    let op: AssistantMemoryOp
    @Binding var text: String
    let picked: Bool
    /// It waits (or is being saved): the tick shows.
    let open: Bool
    let enabled: Bool
    let result: AssistantReminderResult?
    /// None of them was saved (Not Now, or a new message instead).
    let declined: Bool
    let toggle: () -> Void

    private var faded: Bool { declined || result?.isDeclined == true || (open && !picked) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if open {
                Button { withAnimation(.snappy) { toggle() } } label: {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? ModuleTint.assistant : .secondary)
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(Text(verbatim: op.text))
                .accessibilityAddTraits(picked ? .isSelected : [])
                .accessibilityHint(Text("Ticks or unticks it"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    HStack(spacing: 4) {
                        op.module.title
                        Text(verbatim: "·")
                        actionTitle
                    }
                } icon: {
                    Image(systemName: op.module.systemImage)
                        .foregroundStyle(op.module.tint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if op.action == .update, let old = op.old, !old.text.isEmpty {
                    Text(verbatim: old.text)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if op.editable, open, enabled, picked {
                    TextField("What to remember", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                } else if op.action == .remove {
                    Text(verbatim: op.text)
                        .strikethrough()
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: op.editable ? text : op.text)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .accessibilityLabel(Text("Saved"))
                } else if result.failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Failed"))
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .opacity(faded ? 0.6 : 1)
        .animation(.snappy, value: open)
    }

    private var actionTitle: Text {
        switch op.action {
        case .add: Text("Remember")
        case .update: Text("Change")
        case .remove: Text("Forget")
        case .unknown: Text(verbatim: op.name)
        }
    }
}

import SwiftUI

/// Settings → Assistant → Memory: what the assistant remembers for the family, by module (GET
/// /ai/memories). Editors add, edit (a tap) and delete (swipe, context menu); viewers and the demo
/// only read. The assistant saves them itself when told in a chat; its changes reload the page
/// (`DataArea.memories`).
struct AssistantMemoryView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<AssistantMemoryList> = .idle
    @State private var editing: AssistantMemoryEdit?

    /// Changes wait while what's shown is the copy on the device.
    private var canEdit: Bool { family.canEdit && !state.isSaved }

    var body: some View {
        LoadStateView(state: state, retry: load) { list in
            content(list)
        }
        .ohanaBackground(ModuleTint.assistant)
        .navigationTitle("Memory")
        .toolbar {
            if family.canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Memory", systemImage: "plus") { editing = .new }
                        .disabled(!canEdit)
                }
            }
        }
        .task(id: family.revision(.memories)) { await load() }
        .sheet(item: $editing) { edit in
            AssistantMemoryEditor(edit: edit, modules: AssistantMemories.modules(family))
        }
    }

    @ViewBuilder
    private func content(_ list: AssistantMemoryList) -> some View {
        if list.memories.isEmpty {
            ContentUnavailableView {
                Label("Nothing remembered yet", systemImage: "brain")
            } description: {
                Text("Tell the assistant e.g. “Always put … into …” and it remembers.")
            }
        } else {
            Form {
                ForEach(list.sections, id: \.module) { section in
                    Section {
                        ForEach(section.memories) { memory in
                            row(memory)
                        }
                    } header: {
                        Label {
                            section.module.title
                        } icon: {
                            Image(systemName: section.module.systemImage)
                                .foregroundStyle(section.module.tint)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .readableWidth()
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private func row(_ memory: AssistantMemory) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: memory.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let author = memory.createdBy {
                Text("By \(author.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if canEdit {
            Button { editing = .memory(memory) } label: { label.contentShape(.rect) }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(memory) }
                }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { editing = .memory(memory) }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(memory) }
                }
        } else {
            label
        }
    }

    private func load() async {
        await LoadState.run($state, AssistantMemories.request(family.api))
    }

    /// Gone from the list at once; back with the server's list if the server refuses.
    private func delete(_ memory: AssistantMemory) {
        if case var .loaded(list) = state {
            list.memories.removeAll { $0.id == memory.id }
            withAnimation { state = .loaded(list) }
        }
        Task {
            do {
                try await AssistantMemories.delete(family, id: memory.id)
            } catch {
                ErrorBanner.shared.show(error)
                await load()
            }
        }
    }
}

/// What the editor sheet edits: a new memory or one of the list's.
enum AssistantMemoryEdit: Identifiable {
    case new
    case memory(AssistantMemory)

    var id: String {
        switch self {
        case .new: "new"
        case let .memory(memory): memory.id
        }
    }

    var memory: AssistantMemory? {
        if case let .memory(memory) = self { return memory }
        return nil
    }
}

/// A memory's text (at most 300 characters) and module.
struct AssistantMemoryEditor: View {
    let edit: AssistantMemoryEdit
    let modules: [AssistantMemoryModule]
    @Environment(FamilyContext.self) private var family
    @State private var text: String
    @State private var module: AssistantMemoryModule

    init(edit: AssistantMemoryEdit, modules: [AssistantMemoryModule]) {
        self.edit = edit
        self.modules = modules
        _text = State(initialValue: edit.memory?.text ?? "")
        _module = State(initialValue: edit.memory?.module ?? .general)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasChanges: Bool {
        guard let memory = edit.memory else { return !trimmed.isEmpty }
        return trimmed != memory.text || module != memory.module
    }

    private var tooLong: Bool { trimmed.count > AssistantMemoryModule.maxLength }

    /// The modules offered: the family's, and the memory's own even if it isn't among them.
    private var choices: [AssistantMemoryModule] {
        modules.contains(module) ? modules : modules + [module]
    }

    var body: some View {
        FamilySheetForm(title: edit.memory == nil ? "New Memory" : "Edit Memory",
                        canSave: hasChanges && !trimmed.isEmpty && !tooLong, hasChanges: hasChanges) {
            if let memory = edit.memory {
                try await AssistantMemories.update(family, id: memory.id, module: module, text: trimmed)
            } else {
                try await AssistantMemories.create(family, module: module, text: trimmed)
            }
        } content: {
            Section {
                TextField("What to remember", text: $text, prompt: Text("E.g. Clothing from H&M goes to Kids’ clothing."),
                          axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                let count = trimmed.count
                let max = AssistantMemoryModule.maxLength
                Text(verbatim: "\(count) / \(max)")
                    .monospacedDigit()
                    .foregroundStyle(tooLong ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Section {
                Picker("Module", selection: $module) {
                    ForEach(choices, id: \.self) { choice in
                        Label {
                            choice.title
                        } icon: {
                            Image(systemName: choice.systemImage)
                        }
                        .tag(choice)
                    }
                }
            }
        }
    }
}

/// The settings' row to the memory page, with how many there are (the copy on the device first).
struct AssistantMemoryLink: View {
    @Environment(FamilyContext.self) private var family
    @State private var count: Int?

    var body: some View {
        NavigationLink {
            AssistantMemoryView().shellPageItems()
        } label: {
            LabeledContent {
                if let count { Text(count, format: .number) }
            } label: {
                Label("Memory", systemImage: "brain")
            }
        }
        .task(id: family.revision(.memories)) {
            let get = AssistantMemories.request(family.api)
            if count == nil, let saved = await get.savedOffMain() { count = saved.value.memories.count }
            if let list = try? await get.fetch() { count = list.memories.count }
        }
    }
}

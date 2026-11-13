import SwiftUI

/// The user's chats in the family, the latest first: open, delete. Pushed over the chat (from its
/// Chats button), or as a column left of it (`AssistantChatColumn`). A new chat comes from the
/// chat's own header under it.
struct AssistantChatListView: View {
    let store: AssistantChatStore
    /// Pushed in the panel beside a module: a header of its own with a back button, as the chat
    /// has (the window's toolbar is left alone, `AssistantChatView.headerInPanel`).
    var inPanel = false
    /// Back to the chat without picking one (the panel's back button).
    var back: () -> Void = {}
    let done: () -> Void

    var body: some View {
        AssistantChatListContent(store: store, done: done)
            .navigationTitle("Chats")
            .modifier(PanelHeader(enabled: inPanel, back: back))
    }

    private struct PanelHeader: ViewModifier {
        let enabled: Bool
        let back: () -> Void

        func body(content: Content) -> some View {
            if enabled {
                content
                    .navigationBarBackButtonHidden(true)
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                    .safeAreaBar(edge: .top, spacing: 0) {
                        ZStack {
                            Text("Chats")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            HStack {
                                Button(action: back) {
                                    Label("Back", systemImage: "chevron.backward")
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .help(Text("Back"))
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
            } else {
                content
            }
        }
    }
}

/// The chats as a column beside the chat (the assistant's page when there is room): a sidebar
/// list whose selection is the open chat (arrow keys move it, Delete deletes on the Mac). A new
/// chat comes from the page's toolbar and File ▸ New Chat.
struct AssistantChatColumn: View {
    let store: AssistantChatStore

    var body: some View {
        AssistantChatListContent(store: store, done: nil)
    }
}

/// The list itself. Deleting a chat asks first: it can't be brought back.
struct AssistantChatListContent: View {
    let store: AssistantChatStore
    /// Pushed over the chat: a tap opens the chat and goes back to it. Nil in the column.
    let done: (() -> Void)?
    @State private var deleting: AssistantChatSummary?

    var body: some View {
        list
            .overlay {
                if store.chatsLoaded, store.chats.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .refreshable { await store.loadChats() }
            .task { await store.loadChats() }
            .alert("Delete this chat?", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ), presenting: deleting) { chat in
                Button("Delete Chat", role: .destructive) {
                    Task { await store.remove(chat.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { chat in
                Text("“\(chat.title)” and its messages are deleted. What the assistant changed stays as it is.")
            }
    }

    @ViewBuilder private var list: some View {
        if let done {
            List {
                ForEach(store.chats) { chat in
                    Button {
                        Task { await store.open(chat.id) }
                        done()
                    } label: {
                        AssistantChatRow(chat: chat, isOpen: chat.id == store.currentID)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(chat.id == store.currentID
                                       ? RoundedRectangle(cornerRadius: 10).fill(ModuleTint.assistant.opacity(0.14))
                                       : nil)
                    .modifier(DeleteActions(chat: chat, deleting: $deleting))
                }
            }
            .scrollContentBackground(.hidden)
        } else {
            List(selection: Binding(
                get: { store.currentID },
                set: { id in if let id { Task { await store.open(id) } } }
            )) {
                Section("Chats") {
                    ForEach(store.chats) { chat in
                        AssistantChatRow(chat: chat, isOpen: chat.id == store.currentID)
                            .modifier(DeleteActions(chat: chat, deleting: $deleting))
                    }
                }
            }
            .listStyle(.sidebar)
            #if os(macOS)
            .onDeleteCommand {
                deleting = store.chats.first { $0.id == store.currentID }
            }
            #endif
        }
    }

    /// Delete from the context menu and by swiping; both ask first.
    private struct DeleteActions: ViewModifier {
        let chat: AssistantChatSummary
        @Binding var deleting: AssistantChatSummary?

        func body(content: Content) -> some View {
            content
                .contextMenu {
                    Button("Delete chat", systemImage: "trash", role: .destructive) { deleting = chat }
                }
                .swipeActions {
                    Button("Delete chat", systemImage: "trash", role: .destructive) { deleting = chat }
                }
        }
    }
}

struct AssistantChatRow: View {
    let chat: AssistantChatSummary
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOpen ? "bubble.left.fill" : "bubble.left")
                .foregroundStyle(isOpen ? ModuleTint.assistant : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy, value: isOpen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chat.title)
                    .lineLimit(2)
                if let date = chat.updatedDate {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if chat.isRunning {
                // Still, not a spinner: the list needn't move while a turn runs.
                Circle()
                    .fill(ModuleTint.assistant)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("Thinking…"))
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

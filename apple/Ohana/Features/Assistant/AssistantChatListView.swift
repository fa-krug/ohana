import SwiftUI

/// The user's chats in the family, the latest first: open, delete, start a new one. Pushed over
/// the chat (the panel, a narrow page), or as a column left of it (`AssistantChatColumn`).
struct AssistantChatListView: View {
    let store: AssistantChatStore
    let done: () -> Void

    var body: some View {
        AssistantChatListContent(store: store, done: done)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        store.newChat()
                        done()
                    }
                }
            }
    }
}

/// The chats as a column beside the chat (the assistant's page when there is room).
struct AssistantChatColumn: View {
    let store: AssistantChatStore
    let newChat: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button("New chat", systemImage: "square.and.pencil", action: newChat)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help(Text("New chat"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            AssistantChatListContent(store: store) {}
        }
    }
}

/// The list itself.
struct AssistantChatListContent: View {
    let store: AssistantChatStore
    let done: () -> Void

    var body: some View {
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
                .contextMenu {
                    Button("Delete chat", systemImage: "trash", role: .destructive) {
                        Task { await store.remove(chat.id) }
                    }
                }
                .swipeActions {
                    Button("Delete chat", systemImage: "trash", role: .destructive) {
                        Task { await store.remove(chat.id) }
                    }
                }
            }
        }
        .overlay {
            if store.chatsLoaded, store.chats.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await store.loadChats() }
        .task { await store.loadChats() }
    }
}

struct AssistantChatRow: View {
    let chat: AssistantChatSummary
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOpen ? "bubble.left.fill" : "bubble.left")
                .foregroundStyle(isOpen ? ModuleTint.assistant : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chat.title)
                    .lineLimit(1)
                if let date = chat.updatedDate {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if chat.isRunning {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text("Thinking…"))
            }
        }
        .contentShape(.rect)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

import SwiftUI

/// The assistant as a page of its own (web: /f/{id}/assistant, chat-page.tsx): the chats in a
/// column left of the chat when there is room, else over the chat from the history button. It
/// shows the panel's store, so the open chat is the same in both. Takes `.assistantChat(id:)`
/// routes (from the panel's "Open as a page", links) and the family's `ask` requests while it is
/// on screen.
struct AssistantPage: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        AssistantPageContent(store: AssistantChatStore.shared(for: family.api))
            .id(family.family.id)
    }
}

/// From this width on, the chats are a column beside the chat (web: @2xl, 42rem).
private let columnWidth: CGFloat = 640

private struct AssistantPageContent: View {
    @Environment(FamilyContext.self) private var family
    let store: AssistantChatStore
    @State private var wide = false
    @State private var onScreen = false

    var body: some View {
        HStack(spacing: 0) {
            if wide {
                AssistantChatColumn(store: store) { store.newChat() }
                    .frame(width: 260)
                Divider().ignoresSafeArea()
            }
            AssistantChatView(store: store, mode: .page, listBeside: wide, takesRequests: onScreen)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= columnWidth } action: { wide = $0 }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .assistant) else { return }
            if case let .assistantChat(id?) = route {
                Task { await store.open(id) }
            }
        }
    }
}

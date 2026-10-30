import SwiftUI

/// The assistant as a page of its own (web: /f/{id}/assistant): the chats and the chat
/// (placeholder until ported).
struct AssistantPage: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Assistant", systemImage: "sparkles")
            .navigationTitle("Assistant")
    }
}

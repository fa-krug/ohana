import SwiftUI

/// The assistant's chat, in the shell's inspector (placeholder until the module is ported).
struct AssistantPanel: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Assistant", systemImage: "sparkles")
    }
}

import SwiftUI

/// Settings → AI: provider, model, keys (placeholder until the module is ported).
struct AssistantSettingsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Assistant", systemImage: "sparkles")
            .navigationTitle("Assistant")
    }
}

#if os(macOS)
import SwiftUI

/// The Mac's menu bar assistant: the selected family's chat (the same chats as the window's
/// panel), opened ready to type.
struct MenuBarAssistant: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let family = app.selectedFamily, let context = app.context(for: family) {
                AssistantPanel()
                    .environment(context)
                    .id(family.id)
                    .onAppear { context.ask() }
            } else {
                ContentUnavailableView("Sign in to Ohana first", systemImage: "sparkles")
            }
        }
        .errorBanner()
        .frame(width: 420, height: 560)
    }
}
#endif

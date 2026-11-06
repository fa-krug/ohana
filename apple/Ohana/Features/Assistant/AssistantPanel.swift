import SwiftUI

/// The assistant over a module: the shell's floating panel (⌘J, `AssistantFloatingPanel`), a
/// sheet on iPhone (web: chat-panel.tsx in the right sidebar). The chat itself is `AssistantChatView`; the family's
/// chats are kept by `AssistantChatStore`, which follows a running turn live and tells the other
/// modules what the assistant changed. The assistant's page shows the same store.
struct AssistantPanel: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusedValue(\.shell) private var shell
    /// Shown: the floating panel is kept while it is closed (`AssistantChatView.visible`).
    var visible = true
    /// On iPhone: full height to type at once; half height keeps the page behind usable.
    @State private var detent: PresentationDetent = .large

    /// The page beside the panel (web: `pageOf`), as the server knows it: a page it has no name
    /// for (the assistant's own, the knowledge base, the search) counts as the overview.
    private var here: String {
        AssistantPages.page(of: shell?.module.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            AssistantChatView(store: AssistantChatStore.shared(for: family.api), mode: .panel, here: here,
                              visible: visible)
                // Any size, so the window doesn't measure the chat for its smallest size (as the pages).
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .id(family.family.id)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .onChange(of: shell?.module.wrappedValue) { before, after in
            // The assistant's page came on screen: no panel beside it (as on the web).
            if after == .assistant, before != .assistant, sizeClass != .compact {
                // At once: sliding shut, it would lay out the whole page's chat again every frame.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { shell?.assistant.wrappedValue = false }
            }
        }
    }
}

/// The pages a chat can belong to (the server's `PAGES`) and their names.
enum AssistantPages {
    /// The pages the server takes; any other is the overview.
    static let all = ["overview", "calendar", "finance", "meals", "appointments", "chores", "settings"]

    /// The page a chat beside `module` belongs to.
    static func page(of module: Module?) -> String {
        guard let module, all.contains(module.rawValue) else { return "overview" }
        return module.rawValue
    }

    static func name(_ page: String) -> String {
        switch page {
        case "calendar": String(localized: "Calendar")
        case "finance": String(localized: "Finance")
        case "meals": String(localized: "Meals")
        case "appointments": String(localized: "Appointments")
        case "chores": String(localized: "Chores")
        case "settings": String(localized: "Settings")
        default: String(localized: "Overview")
        }
    }
}

/// An attachment in the composer, with a remove button.
struct AssistantPendingChip: View {
    let attachment: AssistantPendingAttachment
    let remove: () -> Void
    @State private var image: Image?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    image.resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    Label {
                        Text(verbatim: attachment.name).lineLimit(1)
                    } icon: {
                        Image(systemName: attachment.kind == "image" ? "photo" : "doc.text")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: 160, minHeight: 52)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
            .help(Text(verbatim: attachment.name))
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    // A finger-sized target around the small icon, without moving it.
                    .padding(12)
                    .contentShape(.rect)
                    .padding(-12)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(Text("Remove \(attachment.name)"))
        }
        .task(id: attachment.id) {
            image = attachment.url.flatMap(AssistantAttachments.image(dataURL:))
        }
    }
}

/// Without AI settings: editors set them up, viewers ask an editor.
struct AssistantSetupView: View {
    let canEdit: Bool
    let openSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Set up the assistant", systemImage: "sparkles")
                .foregroundStyle(ModuleTint.assistant)
        } description: {
            if canEdit {
                Text("Connect any OpenAI-compatible AI (OpenAI, OpenRouter, Mistral, Gemini, a local model …) in the settings. It can then look things up on the web and plan in your calendar and finances.")
            } else {
                Text("Nobody has set up the assistant for this family yet. Ask an editor of the family to do it in the settings.")
            }
        } actions: {
            if canEdit {
                Button("Open the settings", action: openSettings)
                    .buttonStyle(.glassProminent)
                    .tint(ModuleTint.assistant)
            }
        }
    }
}

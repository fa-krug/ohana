import SwiftUI

/// The assistant beside a module: the shell's inspector (⌘J), a sheet on iPhone (web:
/// chat-panel.tsx in the right sidebar). The chat itself is `AssistantChatView`; the family's
/// chats are kept by `AssistantChatStore`, which follows a running turn live and tells the other
/// modules what the assistant changed. The assistant's page shows the same store.
struct AssistantPanel: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusedValue(\.shell) private var shell
    /// On iPhone: full height to type at once; half height keeps the page behind usable.
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            AssistantChatView(store: AssistantChatStore.shared(for: family.api), mode: .panel)
        }
        .id(family.family.id)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .onChange(of: shell?.module.wrappedValue) { before, after in
            // The assistant's page came on screen: no panel beside it (as on the web).
            if after == .assistant, before != .assistant, sizeClass != .compact {
                shell?.assistant.wrappedValue = false
            }
        }
    }
}

/// The page names the chat's banner uses.
enum AssistantPages {
    static func name(_ page: String) -> String {
        switch page {
        case "calendar": String(localized: "Calendar")
        case "finance": String(localized: "Finance")
        case "meals": String(localized: "Meals")
        case "appointments": String(localized: "Appointments")
        case "settings": String(localized: "Settings")
        default: String(localized: "Overview")
        }
    }

    /// Examples for a new chat, fitting the page it starts on.
    static func examples(_ page: String) -> [String] {
        let gaps = String(localized: "Which days this year still need cover, and who could take them?")
        let planWithout = String(localized: "Plan next week’s meals without fish.")
        switch page {
        case "calendar":
            return [gaps, String(localized: "Look up next year’s public holidays here and add them to the calendar.")]
        case "finance":
            return [String(localized: "How much did we spend on groceries this year, per month?"),
                    String(localized: "Sort our uncategorized transactions into categories.")]
        case "meals":
            return [planWithout, String(localized: "What’s still on the shopping list? Add 2 l of milk.")]
        case "appointments":
            return [String(localized: "Find a dermatologist appointment before June."),
                    String(localized: "Which searches found something, and what is the earliest slot?")]
        case "settings":
            return [String(localized: "Set up this year’s entry types: day care closed, each parent’s vacation and public holidays."),
                    String(localized: "Suggest categories for our finances and add them.")]
        default:
            return [gaps, planWithout]
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

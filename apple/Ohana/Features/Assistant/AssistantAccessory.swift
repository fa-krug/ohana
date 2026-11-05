import SwiftUI

/// The iPhone's "Ask Ohana" bar above the tabs (the shell's `tabViewBottomAccessory`): the
/// assistant one tap away on every tab, so the pages there need no ✨ of their own. One button,
/// opening the assistant's sheet ready to type; while a turn runs in the family's chat it says
/// what the assistant does (and the chat's title), the sparkles moving. Where the tab bar has
/// shrunk while scrolling, it sits beside it (`.inline`): the sparkles and a short text.
struct AssistantAccessory: View {
    let context: FamilyContext
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read here, not in the shell: what reads the store is drawn again as the turn goes on.
        let store = AssistantChatStore.shared(for: context.api)
        let turn = AssistantTurn(store)
        let inline = placement == .inline
        Button {
            context.ask()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ModuleTint.assistant)
                    .symbolEffect(.variableColor.iterative, options: .repeating,
                                  isActive: turn.running && !reduceMotion)
                if turn.running {
                    Text(verbatim: turn.status)
                        .fontWeight(.medium)
                        .contentTransition(.opacity)
                    if !inline, !turn.title.isEmpty {
                        Text(verbatim: turn.title)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                } else {
                    Text(inline ? "Ask Ohana" : "Ask Ohana…")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, inline ? 12 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy, value: turn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Ask Ohana"))
        .accessibilityValue(Text(verbatim: turn.running ? turn.status : ""))
        .accessibilityHint(Text("Opens the assistant, ready to type."))
        .accessibilityAddTraits(.isButton)
        .followsAssistantTurn(store)
    }
}

/// The assistant toggle in the toolbars (iPad, Mac, and the iPhone's page sheets): selected and in
/// the assistant's color while the panel is open, the sparkles breathing while a turn runs in the
/// family's chat. It reads only the chats' list, which changes with each step of a turn (not with
/// each piece of text written), so the pages around it aren't drawn again.
struct AssistantToolbarToggle: View {
    @Binding var isOpen: Bool
    @Environment(FamilyContext.self) private var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = AssistantChatStore.shared(for: family.api)
        Toggle(isOn: $isOpen) {
            Label("Assistant", systemImage: "sparkles")
        }
        .toggleStyle(.button)
        .tint(isOpen ? ModuleTint.assistant : nil)
        .symbolEffect(.breathe, options: .repeating, isActive: AssistantTurn.running(store) && !reduceMotion)
        .help("Assistant (⌘J)")
        .followsAssistantTurn(store)
    }
}

/// What a turn in the family's open chat does, for what shows it outside the chat (the Ask Ohana
/// bar, the ✨ toggle).
struct AssistantTurn: Equatable {
    /// A turn runs (or a message is on its way).
    var running: Bool
    /// What it does right now ("Thinking…", a tool's label); empty while none runs.
    var status: String
    /// The chat's title (empty for a new chat).
    var title: String

    init(_ store: AssistantChatStore) {
        running = Self.running(store)
        status = running ? Self.status(store) : ""
        title = running ? store.current?.title ?? "" : ""
    }

    /// A turn runs in the open chat as far as this device follows it: the chat's copy may say
    /// "running" from before (a copy on the device, a stream that broke off), which isn't trusted.
    /// From the chats' list, not the open chat: that changes with every piece of text written.
    static func running(_ store: AssistantChatStore) -> Bool {
        if store.sending { return true }
        guard store.isFollowing, let id = store.currentID else { return false }
        return store.chats.first { $0.id == id }?.isRunning == true
    }

    /// As the chat says it (`AssistantActivityView`), shorter.
    private static func status(_ store: AssistantChatStore) -> String {
        switch store.activity?.activity.kind {
        case "writing":
            return String(localized: "Writing…")
        case "tool":
            let running = (store.current?.items ?? []).compactMap { item -> AssistantToolCall? in
                if case let .tool(t) = item, t.status == "running" { t } else { nil }
            }
            guard let last = running.last else { return String(localized: "Thinking…") }
            return AssistantToolLabels.label(last) + "…"
        default:
            return String(localized: "Thinking…")
        }
    }
}

/// Counts the view as one showing the family's chat (`addViewer`): a turn started in the panel is
/// then followed to its end after the panel closes, so what shows it stops when it does (and the
/// screens reload what the assistant changed). The turn goes on on the server either way.
private struct FollowsAssistantTurn: ViewModifier {
    let store: AssistantChatStore

    func body(content: Content) -> some View {
        content
            .onAppear { store.addViewer() }
            .onDisappear { store.removeViewer() }
    }
}

extension View {
    fileprivate func followsAssistantTurn(_ store: AssistantChatStore) -> some View {
        modifier(FollowsAssistantTurn(store: store))
    }

    /// The Ask Ohana bar above the iPhone's tabs while `enabled` (the server has the assistant);
    /// elsewhere nothing (iPad and Mac have the ✨ in every toolbar).
    @ViewBuilder
    func assistantAccessory(_ context: FamilyContext, enabled: Bool) -> some View {
        #if os(iOS)
        if AssistantAccessoryHost.shows {
            if #available(iOS 26.1, *) {
                // Turned on or off without rebuilding the tab view.
                tabViewBottomAccessory(isEnabled: enabled) { AssistantAccessory(context: context) }
            } else if enabled {
                tabViewBottomAccessory { AssistantAccessory(context: context) }
            } else {
                self
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

enum AssistantAccessoryHost {
    /// The device shows the Ask Ohana bar (an iPhone), so the tabs' pages leave out the ✨.
    static var shows: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

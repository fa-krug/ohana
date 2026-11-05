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
        // Only its summary (`turn`), which changes with a step, not with each piece of text.
        let store = AssistantChatStore.shared(for: context.api)
        let turn = store.turn
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
/// the assistant's color while the panel is open, a still dot on the sparkles while a turn runs in
/// the family's chat (no symbol effect: on the Mac each frame of one would lay out the window). It
/// reads only `turnRunning`, so the pages around it aren't drawn again as the turn goes on.
struct AssistantToolbarToggle: View {
    @Binding var isOpen: Bool
    @Environment(FamilyContext.self) private var family

    var body: some View {
        let store = AssistantChatStore.shared(for: family.api)
        let running = store.turnRunning
        Toggle(isOn: $isOpen) {
            Label {
                Text("Assistant")
            } icon: {
                Image(systemName: "sparkles")
                    .overlay(alignment: .topTrailing) {
                        if running {
                            Circle()
                                .fill(ModuleTint.assistant)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -2)
                        }
                    }
            }
        }
        .toggleStyle(.button)
        .tint(isOpen ? ModuleTint.assistant : nil)
        .accessibilityValue(running ? Text("Thinking…") : Text(verbatim: ""))
        .help("Assistant (⌘J)")
        .followsAssistantTurn(store)
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

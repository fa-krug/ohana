import SwiftUI

/// The iPhone's "Ask Ohana" bar at the bottom of every page (`assistantBar`): the assistant one
/// tap away, so the pages there need no ✨ of their own. One button, opening the assistant's sheet
/// ready to type; while a turn runs in the family's chat it says what the assistant does (and the
/// chat's title), the sparkles moving.
struct AssistantBar: View {
    let context: FamilyContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read here, not in the shell: what reads the store is drawn again as the turn goes on.
        // Only its summary (`turn`), which changes with a step, not with each piece of text.
        let store = AssistantChatStore.shared(for: context.api)
        let turn = store.turn
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
                    if !turn.title.isEmpty {
                        Text(verbatim: turn.title)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                } else {
                    Text("Ask Ohana")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.capsule)
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

#if os(iOS)
/// The Ask Ohana bar under a page, the screen's full width (less the margins), glass over what
/// scrolls beneath it; gone while the keyboard is up (it would ride on it).
private struct AssistantBarHost: ViewModifier {
    let context: FamilyContext
    let enabled: Bool
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .safeAreaBar(edge: .bottom) {
                if enabled, !keyboardUp {
                    AssistantBar(context: context)
                        .frame(height: 50)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
    }
}
#endif

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

    /// The Ask Ohana bar under the page while `enabled` (the server has the assistant): the
    /// iPhone's (iPad and Mac have the ✨ in every toolbar).
    @ViewBuilder
    func assistantBar(_ context: FamilyContext, enabled: Bool) -> some View {
        #if os(iOS)
        modifier(AssistantBarHost(context: context, enabled: enabled))
        #else
        self
        #endif
    }
}

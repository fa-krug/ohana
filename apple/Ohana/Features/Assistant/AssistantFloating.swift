import SwiftUI

/// The assistant's floating parts, the same on every device: a round button at the bottom right
/// of every page (`AssistantFloatingButton`, not on the assistant's own page), and what it opens:
/// on iPad and the Mac a panel floating over the page above it (`AssistantFloatingPanel`), on
/// iPhone (and a narrow iPad) a sheet. Floating, the panel never resizes the page: opening it
/// scales and fades one view, where an inspector laid out the whole window at every step.
enum AssistantFloating {
    #if os(macOS)
    static let buttonSize: CGFloat = 44
    static let margin: CGFloat = 20
    static let panelCorner: CGFloat = 18
    #else
    static let buttonSize: CGFloat = 56
    static let margin: CGFloat = 20
    static let panelCorner: CGFloat = 28
    #endif
    static let panelWidth: CGFloat = 400
    /// Between the panel and the button below it.
    static let gap: CGFloat = 12
}

/// The round button at the bottom right of a page: opens the assistant (⌘J), and while it's open
/// closes it (an ✕ on plain glass). A still dot on the sparkles while a turn runs in
/// the family's chat (no symbol effect: on the Mac each frame of one laid out the window). It
/// reads only `turnRunning`, so the pages under it aren't drawn again as the turn goes on.
struct AssistantFloatingButton: View {
    @Binding var isOpen: Bool
    @Environment(FamilyContext.self) private var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = AssistantChatStore.shared(for: family.api)
        let running = store.turnRunning
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: isOpen ? "xmark" : "sparkles")
                .font(.system(size: AssistantFloating.buttonSize * 0.4, weight: .semibold))
                .foregroundStyle(isOpen ? Color.primary : Color.white)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .overlay(alignment: .topTrailing) {
                    if running, !isOpen {
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                            .offset(x: 5, y: -3)
                    }
                }
                .frame(width: AssistantFloating.buttonSize, height: AssistantFloating.buttonSize)
                // In the assistant's color, so it stands out on any page (a glass tint hardly shows
                // on the Mac); plain glass under the open panel.
                .background { Circle().fill(ModuleTint.assistant.gradient).opacity(isOpen ? 0 : 1) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isOpen)
        .accessibilityLabel(Text("Assistant"))
        .accessibilityValue(running ? Text("Thinking…") : Text(verbatim: ""))
        .accessibilityHint(isOpen ? Text(verbatim: "") : Text("Opens the assistant, ready to type."))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .help("Assistant (⌘J)")
        .followsAssistantTurn(store)
    }
}

/// The button at the bottom right of what it's put on (`assistantFloatingButton`), while
/// `enabled`; on iOS gone while the keyboard is up and the assistant closed (it would ride on it).
/// On iPhone a page's own bar at the bottom (the calendar's) lifts it above that bar
/// (`assistantButtonLift`); on iPad and the Mac the panel opens above the button where it is.
private struct AssistantFloatingButtonHost: ViewModifier {
    @Binding var isOpen: Bool
    let enabled: Bool
    @State private var lift: CGFloat = 0
    #if os(iOS)
    @State private var keyboardUp = false
    #endif

    private var bottom: CGFloat {
        #if os(iOS)
        Module.onPhone && lift > 0 ? lift + AssistantFloating.gap / 2 : AssistantFloating.margin
        #else
        AssistantFloating.margin
        #endif
    }

    private var shown: Bool {
        #if os(iOS)
        enabled && (isOpen || !keyboardUp)
        #else
        enabled
        #endif
    }

    func body(content: Content) -> some View {
        content
            .environment(\.assistantButtonLift, $lift)
            .overlay(alignment: .bottomTrailing) {
                if shown {
                    AssistantFloatingButton(isOpen: $isOpen)
                        .padding([.top, .horizontal], AssistantFloating.margin)
                        .padding(.bottom, bottom)
                        .animation(.snappy, value: bottom)
                        .transition(.opacity)
                }
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
            }
            #endif
    }
}

/// The panel floating over the page (iPad, Mac), at its right above the button: kept while closed
/// (built once, it opens at once, and closes without being taken apart), then invisible, out of
/// the way of clicks and VoiceOver, with no toolbar items, requests or following of the chat
/// (`AssistantPanel(visible:)`). Opening and closing only scale and fade it from the button's
/// corner: nothing under it is laid out again.
struct AssistantFloatingPanel: View {
    let isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AssistantFloating.panelCorner, style: .continuous)
    }

    var body: some View {
        AssistantPanel(visible: isOpen)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .background {
                shape.fill(Color.pageBackground)
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
            }
            .frame(maxWidth: AssistantFloating.panelWidth, maxHeight: .infinity)
            .padding(.top, Self.topInset)
            .padding(.trailing, AssistantFloating.margin)
            .padding(.bottom, AssistantFloating.margin + AssistantFloating.buttonSize + AssistantFloating.gap)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) { content in
                content
                    .scaleEffect(isOpen || reduceMotion ? 1 : 0.9, anchor: .bottomTrailing)
                    .opacity(isOpen ? 1 : 0)
            }
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }

    /// Below the page's toolbar: the Mac's window toolbar is outside the pages already; on iPad
    /// each page has its navigation bar inside the tab view, whose buttons stay clear.
    private static var topInset: CGFloat {
        #if os(macOS)
        AssistantFloating.margin / 2
        #else
        58
        #endif
    }
}

private struct LiftsAssistantButton: ViewModifier {
    @Environment(\.assistantButtonLift) private var lift
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                height = $0
                lift?.wrappedValue = $0
            }
            // A banner that goes (or a page pushed over it) gives the room back.
            .onAppear { lift?.wrappedValue = height }
            .onDisappear { lift?.wrappedValue = 0 }
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

extension EnvironmentValues {
    /// The height of a page's own bar at the bottom of its safe area, which the assistant's button
    /// stays above on iPhone (nil outside a page with the button).
    @Entry var assistantButtonLift: Binding<CGFloat>?
}

extension View {
    /// Keeps the assistant's button above this view, a bar or banner at the bottom of the page's
    /// safe area (a `safeAreaInset` or a bottom overlay): its height is the lift while it shows.
    func liftsAssistantButton() -> some View {
        modifier(LiftsAssistantButton())
    }

    fileprivate func followsAssistantTurn(_ store: AssistantChatStore) -> some View {
        modifier(FollowsAssistantTurn(store: store))
    }

    /// The assistant's round button at the bottom right while `enabled` (the server has the
    /// assistant, and this isn't the assistant's own page).
    func assistantFloatingButton(isOpen: Binding<Bool>, enabled: Bool) -> some View {
        modifier(AssistantFloatingButtonHost(isOpen: isOpen, enabled: enabled))
    }
}

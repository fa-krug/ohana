import SwiftUI

/// Which of a long chat's items are drawn: the last `page` when it opens, `page` more with each
/// "Show earlier messages" (every answer's Markdown is laid out on opening otherwise). The window
/// starts at an item's position in the chat, not at a count from its end: new items join it, and
/// nothing slips out at the top while the user reads an answer that streams.
enum AssistantItemWindow {
    static let page = 40

    /// Where the window of a chat opened with these (visible) item positions starts: at the
    /// `page`-th from the end, or at the first.
    static func start(_ positions: [Int], page: Int = page) -> Int {
        positions.count > page ? positions[positions.count - page] : 0
    }

    /// How many of the positions lie before the window; never so many that fewer than `page` are
    /// left (a chat that came back shorter than it opened).
    static func hidden(_ positions: [Int], start: Int, page: Int = page) -> Int {
        min(positions.firstIndex { $0 >= start } ?? positions.count, max(0, positions.count - page))
    }

    /// The start after "Show earlier messages": `page` more of the hidden ones (all that are left
    /// when fewer).
    static func earlier(_ positions: [Int], start: Int, page: Int = page) -> Int {
        let first = hidden(positions, start: start, page: page) - page
        return first > 0 ? positions[first] : 0
    }
}

/// An example a new chat offers, with an icon for its card.
struct AssistantExample: Hashable {
    let icon: String
    let text: String
}

/// A new chat: the sparkles, a greeting and the page's examples as cards that come up one after
/// the other. A tap puts an example into the composer, to read (and change) before it's sent: the
/// assistant may change things.
struct AssistantWelcome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let examples: [AssistantExample]
    /// On screen (the panel is kept while closed): the cards come up each time it opens.
    var visible = true
    let pick: (String) -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(ModuleTint.assistant.gradient)
                    .symbolEffect(.breathe, isActive: !reduceMotion && visible)
                    .accessibilityHidden(true)
                Text("How can I help?")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Ask me anything about your family’s plans, for example:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
            ForEach(Array(examples.enumerated()), id: \.element) { index, example in
                Button {
                    pick(example.text)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: example.icon)
                            .font(.body.weight(.medium))
                            .foregroundStyle(ModuleTint.assistant)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(verbatim: example.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentCard(cornerRadius: 16, padding: 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Puts it in the message field"))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 12)
                .animation(appeared && !reduceMotion ? .smooth(duration: 0.4).delay(0.12 + 0.06 * Double(index)) : nil,
                           value: appeared)
            }
        }
        .padding(.top, 8)
        .onChange(of: visible, initial: true) {
            // Hidden at once, so the cards come up again the next time it opens.
            appeared = visible
        }
    }
}

/// While a chat is read from the device (or asked from the server): a few grey bubbles in its
/// place, which pulse gently. They show only after a moment, so a quick load simply cross-fades.
struct AssistantChatSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Never read: redacted into grey bars of about these lengths.
            bubble("Which days still need cover this year?")
            answer("The second week of the autumn holidays and the bridge day in May still need someone. Both of you are free then, and the grandparents offered to help.")
            bubble("Plan next week’s meals")
            answer("Here is a plan for the week, with the shopping list.")
        }
        .redacted(reason: .placeholder)
        .opacity(shown ? (dimmed ? 0.45 : 1) : 0)
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { shown = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading the chat"))
    }

    private func bubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 80)
            Text(verbatim: text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(ModuleTint.assistant.opacity(0.5))
                .background(ModuleTint.assistant.opacity(0.14), in: .rect(cornerRadius: 18))
        }
    }

    private func answer(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

/// A light moving across the text (the activity line's "Thinking…"): a gradient mask that slides
/// over it, animated by the render loop, so the view isn't drawn again for it.
struct AssistantShimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if active {
            content
                .mask {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                           .init(color: .black, location: 0.5),
                                           .init(color: .black.opacity(0.35), location: 1)],
                                   startPoint: UnitPoint(x: phase - 1, y: 0.5), endPoint: UnitPoint(x: phase, y: 0.5))
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 2 }
                }
        } else {
            content
        }
    }
}

/// The one round button beside the composer's field: Send, Stop or the mic
/// (`AssistantComposerAction`). One button whose symbol morphs and whose glass fills with the
/// assistant's color while there is something to send, rather than three swapped in place.
struct AssistantComposerButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: AssistantComposerAction
    var listening = false
    /// A turn runs: Send then waits for it.
    var busy = false
    var enabled = true
    var shortcut: KeyboardShortcut?
    let perform: () -> Void

    private var symbol: String {
        switch action {
        case .send: "arrow.up"
        case .stop: "stop.fill"
        case .dictate: listening ? "waveform" : "mic"
        }
    }

    private var label: Text {
        switch action {
        case .send: busy ? Text("Send after this answer") : Text("Send")
        case .stop: Text("Stop")
        case .dictate: listening ? Text("Stop dictation") : Text("Dictate")
        }
    }

    /// Filled: Send with something to send, or the mic while it listens.
    private var prominent: Bool {
        enabled && (action == .send || listening)
    }

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .symbolEffect(.variableColor.iterative, isActive: listening && !reduceMotion)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .foregroundStyle(prominent ? AnyShapeStyle(.white) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .glassEffect(prominent ? .regular.tint(ModuleTint.assistant).interactive() : .regular.interactive(),
                             in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(shortcut)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: symbol)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: prominent)
        .accessibilityLabel(label)
        .help(label)
    }
}

extension AnyTransition {
    /// A message of the user comes up from the composer: from the bottom trailing corner.
    static var assistantUserItem: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.88, anchor: .bottomTrailing).combined(with: .opacity)
                        .combined(with: .offset(y: 10)),
                    removal: .opacity)
    }

    /// An answer, a tool call or a card fades in, sliding up a little.
    static var assistantItem: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }
}

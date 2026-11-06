import SwiftUI

/// Which of a long chat's items are drawn: the last `page` when it opens, `page` more with each
/// "Show earlier messages" (every answer's Markdown is laid out on opening otherwise). The window
/// starts at an item's position in the chat, not at a count from its end: new items join it, and
/// nothing slips out at the top while the user reads an answer that streams.
nonisolated enum AssistantItemWindow {
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

/// A new chat: the sparkles and a greeting. Still: nothing on it moves (the chat fades it in as
/// a whole).
struct AssistantWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(ModuleTint.assistant.gradient)
                .accessibilityHidden(true)
            Text("How can I help?")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 8)
    }
}

/// While a chat is read from the device (or asked from the server): a few faint bubbles in its
/// place, still. They show only after a moment, so a quick load simply cross-fades.
struct AssistantChatSkeleton: View {
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Never read: redacted into grey bars of about these lengths.
            bubble("Which days still need cover this year?")
            answer("The second week of the autumn holidays and the bridge day in May still need someone. Both of you are free then, and the grandparents offered to help.")
            bubble("Plan next week’s meals")
            answer("Here is a plan for the week, with the shopping list.")
        }
        .redacted(reason: .placeholder)
        .opacity(shown ? 0.6 : 0)
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { shown = true }
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

/// The one round button in the composer's box, at its bottom right: Send, Stop or the mic
/// (`AssistantComposerAction`). One button whose symbol morphs and which fills with the
/// assistant's color while there is something to send, rather than three swapped in place.
struct AssistantComposerButton: View {
    /// Its size, and the attach menu's beside it.
    static let size: CGFloat = 36

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
                .frame(width: Self.size, height: Self.size)
                .background {
                    // Inside the composer's glass: a plain fill, no glass on glass.
                    Circle().fill(prominent ? AnyShapeStyle(ModuleTint.assistant.gradient)
                                            : action == .stop ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                }
                .contentShape(.circle)
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

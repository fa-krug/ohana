import SwiftUI

/// The chat's items one under the other (as a leading `VStack`), the last turn (from the user's
/// last message on, `assistantTurnStart()`) at least `turnHeight` tall: sending scrolls that
/// message to the top, and its answer grows into the room below it without the chat scrolling
/// along. A layout rather than a `VStack` per part: the items keep their identity when the next
/// message makes the last turn an earlier one (moved between two stacks, each would be laid out
/// anew and fade out and in).
struct AssistantTurnLayout: Layout {
    var spacing: CGFloat = 12
    var turnHeight: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let (height, _) = arrange(sizes, subviews: subviews)
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        let (_, tops) = arrange(sizes, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + tops[index]), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: sizes[index].height))
        }
    }

    /// The height of it all (the last turn at least `turnHeight` from its start), and each item's top.
    private func arrange(_ sizes: [CGSize], subviews: Subviews) -> (CGFloat, [CGFloat]) {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        var turnStart: CGFloat?
        for (index, size) in sizes.enumerated() {
            if index > 0 { y += spacing }
            if subviews[index][AssistantTurnStart.self] { turnStart = y }
            tops.append(y)
            y += size.height
        }
        return (max(y, turnStart.map { $0 + turnHeight } ?? 0), tops)
    }
}

private nonisolated struct AssistantTurnStart: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Marks the item the last turn starts with (`AssistantTurnLayout`).
    func assistantTurnStart(_ starts: Bool) -> some View {
        layoutValue(key: AssistantTurnStart.self, value: starts)
    }
}

/// The chat's items as drawn: consecutive tool calls are one row (`AssistantToolGroupRow`),
/// everything else one row each.
enum AssistantItemGroups {
    struct Entry: Equatable, Identifiable {
        /// The position (in the chat) of its first item: it stays while a group of tool calls grows.
        var id: Int
        /// Where its items are in the list it was made from.
        var range: Range<Int>
        var isTools: Bool
    }

    static func make(_ items: [(offset: Int, item: AssistantItem)]) -> [Entry] {
        var entries: [Entry] = []
        for (index, entry) in items.enumerated() {
            let isTool = if case .tool = entry.item { true } else { false }
            if isTool, let last = entries.last, last.isTools, last.range.upperBound == index {
                entries[entries.count - 1].range = last.range.lowerBound..<index + 1
            } else {
                entries.append(Entry(id: entry.offset, range: index..<index + 1, isTools: isTool))
            }
        }
        return entries
    }

    /// What a group of tool calls says while folded: the running call (the last one started), or
    /// how many were used.
    enum Summary: Equatable {
        case running(AssistantToolCall)
        case used(count: Int, failed: Bool)
    }

    static func summary(_ tools: [AssistantToolCall]) -> Summary {
        if let running = tools.last(where: { $0.status == "running" }) { return .running(running) }
        return .used(count: tools.count, failed: tools.contains { $0.status != "ok" && $0.status != "running" })
    }
}

/// Tool calls one after the other, as one quiet row: while one runs its label with a spinner,
/// then "Used 3 tools"; a tap unfolds the calls (`AssistantToolRow`, linked ones still open what
/// they touched). A single call is its own row, as before.
struct AssistantToolGroupRow: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tools: [AssistantToolCall]
    let familyID: String
    var open: (AppRoute) -> Void = { _ in }
    @State private var expanded = false

    static func == (a: Self, b: Self) -> Bool {
        a.tools == b.tools && a.familyID == b.familyID
    }

    var body: some View {
        if tools.count == 1 {
            AssistantToolRow(tool: tools[0], route: AssistantToolLinks.route(tools[0], familyID: familyID), open: open)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded ? Text("Hides the tools") : Text("Shows each tool"))
                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            AssistantToolRow(tool: tool, route: AssistantToolLinks.route(tool, familyID: familyID), open: open)
                        }
                    }
                    .padding(.leading, 12)
                    .transition(.opacity)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            switch AssistantItemGroups.summary(tools) {
            case let .running(tool):
                Image(systemName: AssistantToolLabels.icon(tool.name))
                    .frame(width: 16)
                Text(AssistantToolRow.line(AssistantToolLabels.label(tool), AssistantToolLabels.detail(tool)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                chevron
                Spacer(minLength: 0)
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(Text("Running"))
            case let .used(count, failed):
                Image(systemName: "wrench.and.screwdriver")
                    .frame(width: 16)
                Text("Used \(count) tools")
                    .lineLimit(1)
                chevron
                Spacer(minLength: 0)
                if failed {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        .accessibilityLabel(Text("Failed"))
                } else {
                    Image(systemName: "checkmark").font(.caption2.bold())
                        .accessibilityLabel(Text("Done"))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

extension AnyTransition {
    /// A new item of the chat (a message, an answer, a tool call, a card): fades in, a little
    /// from below. Short and plain: nothing scales.
    static var assistantTurnItem: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity)
    }
}

/// A message's text to select (iOS: selecting inside the chat would lay out every message for it).
struct AssistantSelectableText: Identifiable {
    let id = UUID()
    let text: String
}

#if os(iOS)
/// "Select Text" of a message's menu: its plain text in a sheet, to select any part of it and copy.
struct AssistantSelectTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            AssistantSelectableTextView(text: text)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(Text("Select Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A read-only text view: SwiftUI's text selects only all of it at once on iOS.
private struct AssistantSelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        view.dataDetectorTypes = [.link]
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif

extension AssistantItem {
    /// The tool call, for a tool call.
    var tool: AssistantToolCall? {
        if case let .tool(tool) = self { tool } else { nil }
    }
}

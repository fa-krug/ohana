import SwiftUI

// What the chat shows beside its messages: a message that still waits for its answer, what the
// assistant is doing right now, how full the model context window is, and the layout that puts
// the attachment chips in rows. Drawn by `AssistantItemView` and the composer.

/// A message that waits for the answer to end (it goes next); it can be taken back until then.
struct AssistantQueuedRow: View {
    let entry: AssistantQueued
    let store: AssistantChatStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            AssistantUserBubble(
                text: entry.text,
                attachments: (entry.attachments ?? []).map { .init(kind: $0.kind, name: $0.name) },
                queued: true
            )
            HStack(spacing: 6) {
                Label("Queued", systemImage: "clock")
                if entry.isLocal {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await store.unqueue(entry.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            // A finger-sized target around the small icon, without growing the row.
                            .padding(12)
                            .contentShape(.rect)
                            .padding(-12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Take back this message"))
                    .help(Text("Take back this message"))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// What the assistant is doing right now, under the chat while it answers: the sparkles, gently
/// pulsing on iOS (still under Reduce Motion, and always on the Mac), and the status, cross-fading
/// as it changes. The only thing in the chat that moves on its own; nothing ticks: "Writing…" turns
/// into "Thinking…" after a pause by a task that waits for that moment.
struct AssistantActivityLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: AssistantChatStore

    /// After this long without a new piece of text, the model is busy with its next step.
    private static let writingPause: TimeInterval = 2

    /// The piece of text (its time) the pause came after.
    @State private var pausedAfter: Date?

    var body: some View {
        let activityState = store.activity
        let status = text(activityState)
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(ModuleTint.assistant)
                // Not on the Mac: there the repeating pulse drew a frame after frame that waited
                // for the window server (for good while the window was covered), and the main
                // actor's tasks never got their turn: the chat's stream didn't end, it showed
                // "Thinking…" for good and nothing more could be sent.
                #if os(iOS)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                #endif
                .accessibilityHidden(true)
            Text(verbatim: status)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .task(id: activityState?.at) {
            guard let activityState, activityState.activity.kind == "writing" else { return }
            let left = activityState.at.addingTimeInterval(Self.writingPause).timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled else { return }
            pausedAfter = activityState.at
        }
    }

    private func text(_ activityState: AssistantActivityState?) -> String {
        guard let activityState else { return String(localized: "Thinking…") }
        let running = (store.current?.items ?? []).compactMap { item -> AssistantToolCall? in
            if case let .tool(toolCall) = item, toolCall.status == "running" { toolCall } else { nil }
        }
        switch activityState.activity.kind {
        case "retrying":
            let attemptNumber = activityState.activity.attempt ?? 1, max = activityState.activity.max ?? 1
            return String(localized: "The model didn’t answer – trying again (\(attemptNumber)/\(max))…")
        case "compacting":
            return String(localized: "Condensing the earlier conversation…")
        case "tool" where !running.isEmpty:
            let more = running.count > 1 ? " (+\(running.count - 1))" : ""
            return AssistantToolLabels.label(running[running.count - 1]) + more + "…"
        case "writing" where pausedAfter != activityState.at:
            return String(localized: "Writing…")
        default:
            return String(localized: "Thinking…")
        }
    }
}

/// How much of the model's context window the open chat uses; the worker condenses the older
/// messages before it is full. The composer shows it only once that is near (`shows`, in orange).
struct AssistantContextMeter: View {
    let usage: AssistantUsage

    /// From this share of the window on, the meter shows (orange).
    static let warning = 70

    static func percent(_ usage: AssistantUsage) -> Int {
        Int((min(1, usage.used / Swift.max(usage.max, 1)) * 100).rounded())
    }

    static func shows(_ usage: AssistantUsage) -> Bool {
        usage.max > 0 && percent(usage) >= warning
    }

    var body: some View {
        let fraction = min(1, usage.used / Swift.max(usage.max, 1))
        let pct = Self.percent(usage)
        let used = usage.used.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        let max = usage.max.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .tint(pct >= Self.warning ? .orange : ModuleTint.assistant)
                .frame(minWidth: 40)
            Text("Context: \(used) of \(max) tokens (\(pct)%)")
                .monospacedDigit()
                .fixedSize()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(Self.helpNote)
        .accessibilityElement(children: .combine)
    }

    /// What the meter explains when the pointer rests on it; each part is a key of its own.
    static var helpNote: Text {
        Text("How much of the model’s context window this chat uses.")
            + Text(" Before it is full, older messages are condensed into a summary, so long tasks can go on.")
    }
}

/// Lays out chips in rows (attachments).
struct AssistantFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rowTop = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var chipLeft = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: chipLeft, y: rowTop), proposal: .unspecified)
                chipLeft += size.width + spacing
            }
            rowTop += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let last = rows[rows.count - 1]
            let extra = last.indices.isEmpty ? size.width : last.width + spacing + size.width
            if extra > width, !last.indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

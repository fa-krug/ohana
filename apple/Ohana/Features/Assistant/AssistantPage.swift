import SwiftUI

/// The assistant as a page of its own (web: /f/{id}/assistant, chat-page.tsx): the chats in a
/// resizable column left of the chat when there is room, else over the chat from the history
/// button. It shows the panel's store, so the open chat is the same in both. Takes
/// `.assistantChat(id:)` routes (from the panel's "Open as a page", links) and the family's `ask`
/// requests while it is on screen.
struct AssistantPage: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        AssistantPageContent(store: AssistantChatStore.shared(for: family.api))
            .id(family.family.id)
    }
}

/// How wide the chat list column is: dragged between `minWidth` and `maxWidth`, and never so
/// wide that the chat gets narrower than `minChatWidth`. Below `minWidth + minChatWidth` (web:
/// @2xl, 42rem) the list moves behind the history button.
enum AssistantChatColumnLayout {
    static let minWidth: CGFloat = 220
    static let idealWidth: CGFloat = 280
    static let maxWidth: CGFloat = 420
    static let minChatWidth: CGFloat = 420

    static func showsColumn(totalWidth: CGFloat) -> Bool {
        totalWidth >= minWidth + minChatWidth
    }

    static func clamp(_ width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let upper = max(minWidth, min(maxWidth, totalWidth - minChatWidth))
        return min(max(width, minWidth), upper)
    }
}

private struct AssistantPageContent: View {
    @Environment(FamilyContext.self) private var family
    let store: AssistantChatStore
    @State private var totalWidth: CGFloat = 0
    @State private var onScreen = false

    private var wide: Bool { AssistantChatColumnLayout.showsColumn(totalWidth: totalWidth) }

    var body: some View {
        split
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { totalWidth = $0 }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .onChange(of: family.pendingRoute, initial: true) {
                guard let route = family.takeRoute(for: .assistant) else { return }
                if case let .assistantChat(id?) = route {
                    Task { await store.open(id) }
                }
            }
    }

    private var chat: some View {
        AssistantChatView(store: store, mode: .page, listBeside: wide, takesRequests: onScreen)
    }

    /// The Mac's own split view with its resizable divider; on iPad a column with a divider to
    /// drag. The chat keeps its place either way, so the composer keeps what's typed when the
    /// column comes and goes.
    @ViewBuilder private var split: some View {
        #if os(macOS)
        HSplitView {
            if wide {
                AssistantChatColumn(store: store)
                    .frame(minWidth: AssistantChatColumnLayout.minWidth, idealWidth: AssistantChatColumnLayout.idealWidth,
                           maxWidth: AssistantChatColumnLayout.maxWidth)
            }
            chat
                .frame(minWidth: wide ? AssistantChatColumnLayout.minChatWidth : nil)
        }
        #else
        AssistantResizableColumns(totalWidth: totalWidth, showsColumn: wide) {
            AssistantChatColumn(store: store)
        } detail: {
            chat
        }
        #endif
    }
}

#if os(iOS)
/// The iPad's chat list column and the chat, with a divider between them to drag (or adjust with
/// VoiceOver); the width is kept per device.
private struct AssistantResizableColumns<Column: View, Detail: View>: View {
    let totalWidth: CGFloat
    let showsColumn: Bool
    @ViewBuilder var column: Column
    @ViewBuilder var detail: Detail
    @AppStorage("assistant.chatColumnWidth") private var storedWidth = Double(AssistantChatColumnLayout.idealWidth)
    @State private var dragStart: CGFloat?

    private var width: CGFloat { AssistantChatColumnLayout.clamp(CGFloat(storedWidth), totalWidth: totalWidth) }

    var body: some View {
        HStack(spacing: 0) {
            if showsColumn {
                column
                    .frame(width: width)
                divider
            }
            detail
        }
    }

    private var divider: some View {
        Divider()
            .ignoresSafeArea()
            .overlay {
                // A wider grip than the hairline, for a finger or the pointer.
                Color.clear
                    .frame(width: 24)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? width
                                dragStart = start
                                storedWidth = Double(AssistantChatColumnLayout.clamp(start + value.translation.width,
                                                                                      totalWidth: totalWidth))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Chat list width"))
            .accessibilityValue(Text(verbatim: Int(width).formatted()))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 40 : -40
                storedWidth = Double(AssistantChatColumnLayout.clamp(width + step, totalWidth: totalWidth))
            }
    }
}
#endif

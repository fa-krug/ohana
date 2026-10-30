import SwiftUI
import Testing
@testable import Ohana

/// The chat view's decisions: what Return does, when the chat follows new content, how wide the
/// page's chat list is, which provider an API URL is.
struct AssistantComposerTests {
    @Test func returnSendsAndShiftReturnBreaksTheLine() {
        // A hardware keyboard's plain Return sends on both.
        #expect(AssistantReturnKey.action(for: [], mac: true) == .send)
        #expect(AssistantReturnKey.action(for: [], mac: false) == .send)
        // Caps Lock (or the keypad) changes nothing.
        #expect(AssistantReturnKey.action(for: .capsLock, mac: false) == .send)
        // Shift- or Option-Return: the Mac's field needs the line break put in, the iPad's puts
        // it in itself.
        #expect(AssistantReturnKey.action(for: .shift, mac: true) == .lineBreak)
        #expect(AssistantReturnKey.action(for: .option, mac: true) == .lineBreak)
        #expect(AssistantReturnKey.action(for: .shift, mac: false) == .system)
        #expect(AssistantReturnKey.action(for: .option, mac: false) == .system)
        // ⌘↩ is the Send button's shortcut.
        #expect(AssistantReturnKey.action(for: .command, mac: true) == .system)
        #expect(AssistantReturnKey.action(for: [.command, .shift], mac: false) == .system)
        #expect(AssistantReturnKey.action(for: .control, mac: true) == .system)
    }

    @Test func putsTheLineBreakAtTheCursor() {
        let text = "Plan meals"
        // At the cursor, which then stands after it.
        let cursor = text.index(text.startIndex, offsetBy: 4)
        let (broken, selection) = AssistantReturnKey.insertingLineBreak(into: text, at: TextSelection(insertionPoint: cursor))
        #expect(broken == "Plan\n meals")
        #expect(Self.offset(selection, in: broken) == 5)
        // In place of a selection.
        let range = text.index(text.startIndex, offsetBy: 4)..<text.index(text.startIndex, offsetBy: 5)
        #expect(AssistantReturnKey.insertingLineBreak(into: text, at: TextSelection(range: range)).0 == "Plan\nmeals")
        // At the end without a selection.
        let (end, endSelection) = AssistantReturnKey.insertingLineBreak(into: "Hi 👋", at: nil)
        #expect(end == "Hi 👋\n")
        #expect(Self.offset(endSelection, in: end) == end.utf16.count)
        // A selection from a longer text (dictation replaced it) is clamped to the end.
        let long = "A much longer text"
        let stale = TextSelection(insertionPoint: long.index(long.startIndex, offsetBy: 15))
        #expect(AssistantReturnKey.insertingLineBreak(into: "Short", at: stale).0 == "Short\n")
    }

    private static func offset(_ selection: TextSelection, in text: String) -> Int? {
        guard case let .selection(range) = selection.indices else { return nil }
        return range.lowerBound.utf16Offset(in: text)
    }

    typealias Metrics = AssistantScrollFollow.Metrics

    @Test func followsTheEndUntilTheUserScrollsUp() {
        let atEnd = Metrics(offset: 500, maxOffset: 500)
        #expect(atEnd.isAtBottom)
        // The answer grew: the end moved away, the user didn't move. Still following, so pin.
        let grown = Metrics(offset: 500, maxOffset: 620)
        #expect(!grown.isAtBottom)
        #expect(AssistantScrollFollow.follows(true, from: atEnd, to: grown))
        #expect(AssistantScrollFollow.shouldPin(following: true, metrics: grown, scrolling: false))
        // Not while the user scrolls; an animation doesn't count (on macOS it may never end).
        #expect(!AssistantScrollFollow.shouldPin(following: true, metrics: grown, scrolling: true))
        #expect(AssistantScrollFollow.userScrolls(.interacting))
        #expect(AssistantScrollFollow.userScrolls(.decelerating))
        #expect(!AssistantScrollFollow.userScrolls(.animating))
        #expect(!AssistantScrollFollow.userScrolls(.idle))
        // The user scrolled up: no longer following, even while the answer grows on.
        let up = Metrics(offset: 300, maxOffset: 620)
        #expect(!AssistantScrollFollow.follows(true, from: grown, to: up))
        let more = Metrics(offset: 300, maxOffset: 700)
        #expect(!AssistantScrollFollow.follows(false, from: up, to: more))
        #expect(!AssistantScrollFollow.shouldPin(following: false, metrics: more, scrolling: false))
        // Back near the end (within the threshold): following again.
        let back = Metrics(offset: 670, maxOffset: 700)
        #expect(AssistantScrollFollow.follows(false, from: more, to: back))
    }

    @Test func aShrinkingChatIsntTheUserScrolling() {
        // Another chat opened, the keyboard went away: the offset drops with the end.
        let before = Metrics(offset: 900, maxOffset: 900)
        let shorter = Metrics(offset: 600, maxOffset: 800)
        #expect(!shorter.isAtBottom)
        #expect(AssistantScrollFollow.follows(true, from: before, to: shorter))
        #expect(AssistantScrollFollow.shouldPin(following: true, metrics: shorter, scrolling: false))
        let clamped = Metrics(offset: 380, maxOffset: 300)
        #expect(AssistantScrollFollow.follows(true, from: Metrics(offset: 500, maxOffset: 500), to: clamped))
        // A chat shorter than the view is always at its end.
        #expect(Metrics(offset: 0, maxOffset: -200).isAtBottom)
        #expect(!AssistantScrollFollow.shouldPin(following: true, metrics: Metrics(offset: 0, maxOffset: -200), scrolling: false))
    }

    #if os(macOS)
    @Test func macOSContainerLeavesOutTheBars() {
        // As measured in the menu bar's panel: toolbar 52, composer 118, already outside the
        // container. At the top the offset is -52; at the end, content - container - 52.
        let insets = EdgeInsets(top: 52, leading: 0, bottom: 118, trailing: 0)
        let size = CGSize(width: 420, height: 390)
        let content = CGSize(width: 420, height: 800)
        let top = Metrics(ScrollGeometry(contentOffset: CGPoint(x: 0, y: -52), contentSize: content,
                                         contentInsets: insets, containerSize: size))
        #expect(!top.isAtBottom)
        let end = Metrics(ScrollGeometry(contentOffset: CGPoint(x: 0, y: 358), contentSize: content,
                                         contentInsets: insets, containerSize: size))
        #expect(end.isAtBottom)
        #expect(!AssistantScrollFollow.shouldPin(following: true, metrics: end, scrolling: false))
        // A short chat with the toolbar's inset just applied: still at its end, so still following.
        let short = Metrics(ScrollGeometry(contentOffset: CGPoint(x: 0, y: -52), contentSize: CGSize(width: 420, height: 330),
                                           contentInsets: insets, containerSize: size))
        #expect(short.isAtBottom)
        #expect(AssistantScrollFollow.follows(true, from: Metrics(offset: 0, maxOffset: -4), to: short))
    }
    #endif

    @Test func sizesThePagesChatList() {
        typealias Layout = AssistantChatColumnLayout
        #expect(!Layout.showsColumn(totalWidth: 600))
        #expect(Layout.showsColumn(totalWidth: 640))
        #expect(Layout.clamp(100, totalWidth: 1200) == Layout.minWidth)
        #expect(Layout.clamp(300, totalWidth: 1200) == 300)
        #expect(Layout.clamp(900, totalWidth: 1200) == Layout.maxWidth)
        // The chat keeps its minimum: a narrow page caps the column.
        #expect(Layout.clamp(400, totalWidth: 700) == 700 - Layout.minChatWidth)
        #expect(Layout.clamp(400, totalWidth: 500) == Layout.minWidth)
    }

    @Test func namesTheProviderOfAnAPIURL() {
        #expect(AssistantProviders.provider(for: "") == "")
        #expect(AssistantProviders.provider(for: "https://api.openai.com/v1") == "OpenAI")
        #expect(AssistantProviders.provider(for: " https://openrouter.ai/api/v1/ ") == "OpenRouter")
        #expect(AssistantProviders.provider(for: "https://llm.example.com/v1") == AssistantProviders.other)
        #expect(AssistantProviders.url(of: "Gemini") == "https://generativelanguage.googleapis.com/v1beta/openai")
        #expect(AssistantProviders.url(of: AssistantProviders.other) == nil)
    }
}

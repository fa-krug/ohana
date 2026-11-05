import SwiftUI
import Testing
@testable import Ohana

/// The chat view's decisions: what Return does, what the button beside the field is, when the
/// context meter shows, the page a chat belongs to, how the chat scrolls, how wide
/// the page's chat list is, which of a long chat's items are drawn, which provider an API URL is.
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

    @Test func sharesOneSlotForSendStopAndTheMic() {
        // Empty: the mic where there is one, else a Send that can't send.
        #expect(AssistantComposerAction.make(filled: false, busy: false, canQueue: true, dictation: true, listening: false) == .dictate)
        #expect(AssistantComposerAction.make(filled: false, busy: false, canQueue: true, dictation: false, listening: false) == .send)
        #expect(AssistantComposerAction.make(filled: true, busy: false, canQueue: false, dictation: true, listening: false) == .send)
        // While it answers: Stop, or Send when the message can wait in the chat.
        #expect(AssistantComposerAction.make(filled: false, busy: true, canQueue: true, dictation: true, listening: false) == .stop)
        #expect(AssistantComposerAction.make(filled: true, busy: true, canQueue: true, dictation: true, listening: false) == .send)
        #expect(AssistantComposerAction.make(filled: true, busy: true, canQueue: false, dictation: true, listening: false) == .stop)
        // Listening: the mic stays, to stop it.
        #expect(AssistantComposerAction.make(filled: true, busy: false, canQueue: true, dictation: true, listening: true) == .dictate)
    }

    @Test func showsTheContextMeterOnlyWhenItGetsFull() {
        #expect(!AssistantContextMeter.shows(AssistantUsage(used: 60, max: 100)))
        #expect(AssistantContextMeter.shows(AssistantUsage(used: 70, max: 100)))
        #expect(!AssistantContextMeter.shows(AssistantUsage(used: 10, max: 0)))
    }

    @Test func pagesTheServerDoesntKnowAreTheOverview() {
        #expect(AssistantPages.page(of: .finance) == "finance")
        #expect(AssistantPages.page(of: .settings) == "settings")
        #expect(AssistantPages.page(of: .knowledge) == "overview")
        #expect(AssistantPages.page(of: .search) == "overview")
        #expect(AssistantPages.page(of: .assistant) == "overview")
        #expect(AssistantPages.page(of: nil) == "overview")
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
    typealias Follow = AssistantScrollFollow

    @Test func followsAnAnswerPastTheBottom() {
        let atEnd = Metrics(offset: 500, maxOffset: 500, visibleHeight: 600)
        #expect(atEnd.isAtBottom)
        // The answer grew past the bottom with the end in view: to the new end.
        let grown = Metrics(offset: 500, maxOffset: 620, visibleHeight: 600)
        #expect(!grown.isAtBottom)
        #expect(Follow.pin(pending: false, from: atEnd, to: grown, scrolling: false) == (true, false))
        // Not while the sent message scrolls to the top, nor while the user scrolls.
        #expect(Follow.pin(pending: false, from: atEnd, to: grown, scrolling: false, follows: false) == (false, false))
        #expect(Follow.pin(pending: false, from: atEnd, to: grown, scrolling: true) == (false, false))
        // Read further up: the chat stays, "Jump to latest" shows.
        let up = Metrics(offset: 200, maxOffset: 500, visibleHeight: 600)
        #expect(Follow.pin(pending: false, from: up, to: Metrics(offset: 200, maxOffset: 620, visibleHeight: 600),
                           scrolling: false) == (false, false))
        // Within the last turn's room the end doesn't move: nothing scrolls.
        #expect(Follow.pin(pending: false, from: atEnd, to: atEnd, scrolling: false) == (false, false))
        // Back near the end (within the threshold): at the end again.
        #expect(Metrics(offset: 590, maxOffset: 620, visibleHeight: 600).isAtBottom)
        // A chat shorter than the view is always at its end.
        #expect(Metrics(offset: 0, maxOffset: -200).isAtBottom)
    }

    @Test func keepsTheEndInViewWhenTheKeyboardComesUp() {
        // At the end, the keyboard takes 300 points: back to the end until it is there.
        let atEnd = Metrics(offset: 500, maxOffset: 500, visibleHeight: 600)
        let keyboard = Metrics(offset: 500, maxOffset: 800, visibleHeight: 300)
        #expect(Follow.pin(pending: false, from: atEnd, to: keyboard, scrolling: false) == (true, true))
        // Still on the way (the keyboard slides in): on.
        let sliding = Metrics(offset: 650, maxOffset: 800, visibleHeight: 300)
        #expect(Follow.pin(pending: true, from: keyboard, to: sliding, scrolling: false) == (true, true))
        // There: done; the answer growing afterwards is followed (no longer pending).
        let there = Metrics(offset: 800, maxOffset: 800, visibleHeight: 300)
        #expect(Follow.pin(pending: true, from: sliding, to: there, scrolling: false) == (false, false))
        #expect(Follow.pin(pending: false, from: there, to: Metrics(offset: 800, maxOffset: 900, visibleHeight: 300),
                           scrolling: false) == (true, false))
        // Read further up: the keyboard leaves the chat where it is.
        let up = Metrics(offset: 100, maxOffset: 500, visibleHeight: 600)
        #expect(Follow.pin(pending: false, from: up, to: Metrics(offset: 100, maxOffset: 800, visibleHeight: 300),
                           scrolling: false) == (false, false))
        // The user scrolling ends it.
        #expect(Follow.pin(pending: true, from: keyboard, to: sliding, scrolling: true) == (false, false))
        // The first measurement (the last turn gets its room below): to the end it opened at.
        let first = Metrics(offset: 0, maxOffset: 0, visibleHeight: 0)
        #expect(Follow.pin(pending: false, from: first, to: Metrics(offset: 0, maxOffset: 400, visibleHeight: 600),
                           scrolling: false) == (true, true))
        // An animation isn't the user scrolling (on macOS it may never end).
        #expect(Follow.userScrolls(.interacting))
        #expect(Follow.userScrolls(.decelerating))
        #expect(!Follow.userScrolls(.animating))
        #expect(!Follow.userScrolls(.idle))
    }

    @Test func givesTheLastTurnTheVisibleHeight() {
        #expect(Follow.turnHeight(visible: 600.6) == 600 - 2 * Follow.padding)
        #expect(Follow.turnHeight(visible: 10) == 0)
        #expect(Follow.turnHeight(visible: 0) == 0)
    }

    @Test func scrollsANewMessageToTheTop() {
        // Sent, or come in while the user reads at the end.
        #expect(Follow.scrollsToTurn(from: 4, to: 9, sameChat: true, sent: true, atEnd: false))
        #expect(Follow.scrollsToTurn(from: 4, to: 9, sameChat: true, sent: false, atEnd: true))
        // Not while the user reads further up and didn't send it.
        #expect(!Follow.scrollsToTurn(from: 4, to: 9, sameChat: true, sent: false, atEnd: false))
        // Not on opening a chat (it opens at its end), nor for another chat.
        #expect(!Follow.scrollsToTurn(from: nil, to: 9, sameChat: true, sent: true, atEnd: true))
        #expect(!Follow.scrollsToTurn(from: 4, to: 9, sameChat: false, sent: true, atEnd: true))
        // Nor when the chat came back shorter.
        #expect(!Follow.scrollsToTurn(from: 9, to: 4, sameChat: true, sent: true, atEnd: true))
        #expect(!Follow.scrollsToTurn(from: 9, to: nil, sameChat: true, sent: true, atEnd: true))
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
        #expect(top.visibleHeight == 390)
        let end = Metrics(ScrollGeometry(contentOffset: CGPoint(x: 0, y: 358), contentSize: content,
                                         contentInsets: insets, containerSize: size))
        #expect(end.isAtBottom)
        // A short chat with the toolbar's inset just applied: still at its end.
        let short = Metrics(ScrollGeometry(contentOffset: CGPoint(x: 0, y: -52), contentSize: CGSize(width: 420, height: 330),
                                           contentInsets: insets, containerSize: size))
        #expect(short.isAtBottom)
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

    @Test func drawsTheLastItemsOfALongChatFirst() {
        typealias Window = AssistantItemWindow
        // A short chat: all of it.
        #expect(Window.start([0, 1, 2], page: 5) == 0)
        #expect(Window.hidden([0, 1, 2], start: 0, page: 5) == 0)
        // Positions with gaps (items that aren't shown): the window starts at the 3rd from the end.
        let positions = [0, 2, 3, 5, 8, 9, 12]
        let start = Window.start(positions, page: 3)
        #expect(start == 8)
        #expect(Window.hidden(positions, start: start, page: 3) == 4)
        // New items join the window: it still starts there, and nothing moves out at the top.
        #expect(Window.hidden(positions + [13, 14], start: start, page: 3) == 4)
        // Earlier: three more, then the rest.
        let earlier = Window.earlier(positions, start: start, page: 3)
        #expect(earlier == 2)
        #expect(Window.hidden(positions, start: earlier, page: 3) == 1)
        #expect(Window.earlier(positions, start: earlier, page: 3) == 0)
        #expect(Window.hidden(positions, start: 0, page: 3) == 0)
        // A chat that came back shorter than its window's start: its last items still show.
        #expect(Window.hidden([0, 1, 2, 3], start: 8, page: 3) == 1)
        #expect(Window.start([], page: 3) == 0)
        #expect(Window.hidden([], start: 0, page: 3) == 0)
    }

    @Test func offersAnExampleWithAnIconForEveryPage() {
        for page in AssistantPages.all + ["knowledge"] {
            let examples = AssistantPages.examples(page)
            #expect(examples.count == 2)
            #expect(examples.allSatisfy { !$0.icon.isEmpty && !$0.text.isEmpty })
        }
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

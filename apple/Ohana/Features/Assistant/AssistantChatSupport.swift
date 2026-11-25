import SwiftUI

// The pieces around the chat: the menu and commands of the assistant's own page, the paste
// monitor, what the composer's button and Return do, following the end of the chat, and reading
// the dismiss action without observing it. Used by `AssistantChatView` (AssistantChatView.swift).

/// File ▸ New Chat (⌘N) and the Assistant menu, on the assistant's page only: the panel beside
/// another module leaves both to that module (it doesn't even set them empty).
struct AssistantPageCommands: ViewModifier {
    let enabled: Bool
    let menu: ModuleMenu
    let newChat: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusedSceneValue(\.newItem, NewItemAction(title: "New Chat", action: newChat))
                .focusedSceneValue(\.moduleMenu, menu)
        } else {
            content
        }
    }
}

/// Paste (the edit menu, ⌘V) attaches the clipboard's pictures, and long text as a file
/// (`AssistantAttachments.isLongPaste`); shorter text goes into the field as usual. Pictures:
/// iOS 27's `pasteDestination`, before it the field's UIKit text view (`AssistantTextPaste`),
/// which takes the text on every version.
struct AssistantPaste: ViewModifier {
    let enabled: Bool
    let empty: Bool
    let images: ([Data]) -> Void
    let text: (String) -> Void

    func body(content: Content) -> some View {
        // Only the iOS 27 SDK (Swift 6.4, Xcode 27) has `pasteDestination` on iOS; older Xcodes
        // (CI's) build without it.
        #if os(iOS) && compiler(>=6.4)
        if #available(iOS 27, *) {
            content
                .background(AssistantTextPaste(enabled: enabled, empty: empty, takesImages: false,
                                               images: images, text: text))
                .pasteDestination(for: AssistantPastedImage.self) { pasted in
                    images(pasted.map(\.data))
                } validator: { pasted in
                    enabled ? pasted : []
                }
        } else {
            content.background(AssistantTextPaste(enabled: enabled, empty: empty, takesImages: true,
                                                  images: images, text: text))
        }
        #elseif os(iOS)
        content.background(AssistantTextPaste(enabled: enabled, empty: empty, takesImages: true,
                                              images: images, text: text))
        #else
        content
        #endif
    }
}

/// The one button beside the composer's field: Send with something to send (while a turn runs,
/// once the chat has an id to wait in), Stop while a turn runs, else the mic where there is one
/// (dictating goes on until it's stopped there) or a disabled Send.
enum AssistantComposerAction: Equatable {
    case send, stop, dictate

    static func make(filled: Bool, busy: Bool, canQueue: Bool, dictation: Bool, listening: Bool) -> Self {
        if listening { return .dictate }
        if busy { return filled && canQueue ? .send : .stop }
        if filled || !dictation { return .send }
        return .dictate
    }
}

/// What Return does in the composer. Only a hardware keyboard's Return gets here (iPad, Mac); the
/// on-screen keyboard's puts in a line break as in Messages, and the Send button sends.
enum AssistantReturnKey {
    enum Action: Equatable {
        case send
        /// The composer puts the line break in itself (the Mac's field would end editing instead).
        case lineBreak
        /// Left to the system: ⌘↩ is the Send button's, and the iPad's field puts in a line break
        /// for Shift- and Option-Return by itself.
        case system
    }

    static func action(for modifiers: EventModifiers, mac: Bool = isMac) -> Action {
        let held = modifiers.intersection([.shift, .option, .command, .control])
        if held.isEmpty { return .send }
        if held.contains(.command) || held.contains(.control) { return .system }
        return mac ? .lineBreak : .system
    }

    private static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// `text` with a line break in place of the selection (at the end without one), and the
    /// cursor after it. A selection older than the text (dictation changed it) is clamped.
    static func insertingLineBreak(into text: String, at selection: TextSelection?) -> (String, TextSelection) {
        let count = text.utf16.count
        var lower = count, upper = count
        if case let .selection(range)? = selection?.indices {
            // Clamped before measuring: an index past the end would trap.
            lower = min(range.lowerBound, text.endIndex).utf16Offset(in: text)
            upper = max(min(range.upperBound, text.endIndex).utf16Offset(in: text), lower)
        }
        let start = String.Index(utf16Offset: lower, in: text)
        let end = String.Index(utf16Offset: upper, in: text)
        let result = text.replacingCharacters(in: start..<end, with: "\n")
        return (result, TextSelection(insertionPoint: String.Index(utf16Offset: lower + 1, in: result)))
    }
}

/// How the chat scrolls. Sending scrolls the message to the top of the chat, and its answer grows
/// into the room below it (the last turn is at least as tall as the visible part) without moving
/// the chat; once it grows past the bottom, the chat follows it while the end was in view (scrolled
/// up, "Jump to latest" shows instead). A change of the visible height (the keyboard, the window,
/// the first measurement) keeps the end in view that was.
enum AssistantScrollFollow {
    /// Closer than this to the end counts as at the end.
    static let threshold: CGFloat = 48
    /// The chat's padding above and below its items: the last turn leaves it free, so its message
    /// stands that far below the top.
    static let padding: CGFloat = 12

    struct Metrics: Equatable {
        /// The vertical content offset, and the largest it can be (the end of the chat).
        var offset: CGFloat
        var maxOffset: CGFloat
        /// How much of the chat is in view (the scroll view less its bars).
        var visibleHeight: CGFloat = 0

        var distanceFromBottom: CGFloat { max(0, maxOffset - offset) }
        var isAtBottom: Bool { distanceFromBottom <= AssistantScrollFollow.threshold }
    }

    /// The last turn's least height for this visible height: all of it but the padding above and
    /// below, in whole points (a fraction would lay the chat out again for nothing).
    static func turnHeight(visible: CGFloat) -> CGFloat {
        max(0, (visible - 2 * padding).rounded(.down))
    }

    /// After the scroll view changed: whether to scroll to the end now, and whether to go on doing
    /// so until it is there. The visible height changed while the end was in view (or was first
    /// measured): back to the end. The content grew past the end that was in view (an answer
    /// longer than its room), with `follows`: to the new end. The user scrolling ends both.
    static func pin(pending: Bool, from old: Metrics, to new: Metrics, scrolling: Bool,
                    follows: Bool = true) -> (scroll: Bool, pending: Bool) {
        if scrolling { return (false, false) }
        let resized = abs(new.visibleHeight - old.visibleHeight) > 0.5
        let pending = pending || resized && (old.isAtBottom || old.visibleHeight <= 0)
        if pending, new.distanceFromBottom > 0.5 { return (true, true) }
        let grew = !resized && new.maxOffset > old.maxOffset + 0.5
        if follows, grew, old.isAtBottom, new.distanceFromBottom > 0.5 { return (true, false) }
        return (false, false)
    }

    /// Whether the last turn's start (the user's last message) scrolls to the top: a later one in
    /// the same chat (not the one it opened with), when the user sent it or reads at the end.
    static func scrollsToTurn(from old: Int?, to new: Int?, sameChat: Bool, sent: Bool, atEnd: Bool) -> Bool {
        guard sameChat, let old, let new, new > old else { return false }
        return sent || atEnd
    }

    /// The user's own scrolling, not an animation: on macOS an animated scroll to where the chat
    /// already is stays `.animating` and would hold the chat off its end for good.
    static func userScrolls(_ phase: ScrollPhase) -> Bool {
        phase.isScrolling && phase != .animating
    }
}

extension AssistantScrollFollow.Metrics {
    init(_ geometry: ScrollGeometry) {
        // The container leaves out the bars (toolbar or header, composer, keyboard): it is what's in
        // view. The offset starts at -top.
        offset = geometry.contentOffset.y
        maxOffset = geometry.contentSize.height - geometry.containerSize.height - geometry.contentInsets.top
        visibleHeight = geometry.containerSize.height
    }
}

/// Holds the dismiss action for a view that mustn't observe it (`AssistantChatView`).
final class AssistantDismissBox {
    var action: DismissAction?
}

/// Reads `\.dismiss` into a box: only this view is drawn again when it changes.
struct AssistantDismissReader: View {
    let box: AssistantDismissBox
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = (box.action = dismiss)
        Color.clear.accessibilityHidden(true)
    }
}

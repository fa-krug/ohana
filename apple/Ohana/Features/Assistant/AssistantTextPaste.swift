#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Paste in the composer's edit menu (and ⌘V) attaches long text as a file
/// (`AssistantAttachments.isLongPaste`), and pictures before iOS 27, where SwiftUI has no
/// `pasteDestination` (`takesImages`): put as the text field's background, it finds the field's
/// UIKit text view and becomes its paste delegate (`UITextPasteDelegate`). Shorter text goes into
/// the field (through the field's own delegate, if it has one). It also scrolls the emptied field
/// back to its top (`empty`).
struct AssistantTextPaste: UIViewRepresentable {
    let enabled: Bool
    let empty: Bool
    let takesImages: Bool
    let images: ([Data]) -> Void
    let text: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Finder {
        let view = Finder()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: Finder, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.takesImages = takesImages
        context.coordinator.images = images
        context.coordinator.text = text
        context.coordinator.offerPaste()
        view.attach()
        if empty { context.coordinator.scrollToTop() }
    }

    static func dismantleUIView(_ view: Finder, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Looks for the text view beside it once it's in a window.
    final class Finder: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard window != nil, let coordinator, coordinator.textView == nil else { return }
            // SwiftUI builds the text view after its background at times: look again shortly.
            if let textView = nearestTextView() {
                coordinator.attach(to: textView)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, let coordinator = self.coordinator,
                          coordinator.textView == nil, let textView = self.nearestTextView() else { return }
                    coordinator.attach(to: textView)
                }
            }
        }

        /// The editable text view closest above this one: the field's (a vertical `TextField`
        /// is a `UITextView`).
        private func nearestTextView() -> UITextView? {
            var ancestor = superview
            for _ in 0..<6 {
                guard let current = ancestor else { return nil }
                if let found = Self.editableTextView(in: current) { return found }
                ancestor = current.superview
            }
            return nil
        }

        private static func editableTextView(in view: UIView) -> UITextView? {
            if let textView = view as? UITextView, textView.isEditable { return textView }
            for subview in view.subviews {
                if let found = editableTextView(in: subview) { return found }
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UITextPasteDelegate {
        var enabled = true
        var takesImages = true
        var images: ([Data]) -> Void = { _ in }
        var text: (String) -> Void = { _ in }
        weak var textView: UITextView?
        private weak var original: (any UITextPasteDelegate)?
        private var originalConfiguration: UIPasteConfiguration?
        private var originalAttributes = false
        private var observers: [any NSObjectProtocol] = []

        func attach(to textView: UITextView) {
            self.textView = textView
            original = textView.pasteDelegate
            originalConfiguration = textView.pasteConfiguration
            originalAttributes = textView.allowsEditingTextAttributes
            textView.pasteDelegate = self
            let center = NotificationCenter.default
            for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification,
                         UITextView.textDidBeginEditingNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.offerPaste() }
                })
            }
            // Pictures among what it takes, so a paste hands them to the delegate.
            let configuration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
            if let current = textView.pasteConfiguration {
                configuration.addAcceptableTypeIdentifiers(current.acceptableTypeIdentifiers)
            }
            textView.pasteConfiguration = configuration
            offerPaste()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let textView else { return }
            if textView.pasteDelegate === self { textView.pasteDelegate = original }
            textView.pasteConfiguration = originalConfiguration
            textView.allowsEditingTextAttributes = originalAttributes
            self.textView = nil
        }

        /// Sending a long message empties the field, but its text view stays scrolled to where the
        /// message ended: the cursor then shows above the placeholder. Back to the top once SwiftUI
        /// has put the empty text in.
        func scrollToTop() {
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView, textView.text.isEmpty else { return }
                let top = CGPoint(x: -textView.adjustedContentInset.left, y: -textView.adjustedContentInset.top)
                if textView.contentOffset != top { textView.setContentOffset(top, animated: false) }
            }
        }

        /// A plain text view offers Paste only for text: while the clipboard holds a picture and
        /// no text it takes rich text, which offers Paste for pictures too (they come here, never
        /// into the text). Otherwise not, so there's no Format menu and pasted text stays plain.
        /// (`hasImages` / `hasStrings` don't ask the user's permission to paste.)
        func offerPaste() {
            guard let textView else { return }
            let board = UIPasteboard.general
            textView.allowsEditingTextAttributes = originalAttributes
                || (enabled && takesImages && board.hasImages && !board.hasStrings)
        }

        /// A picture (nothing that's also text) is attached, long text too (as a file); anything
        /// else pastes as it would.
        func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting,
                                              transform item: any UITextPasteItem) {
            let provider = item.itemProvider
            guard enabled else { return pasteAsUsual(supporting, item) }
            if provider.canLoadObject(ofClass: NSString.self) {
                // The paste waits for the item's result.
                Task {
                    guard let pasted = await Self.text(provider) else { return pasteAsUsual(supporting, item) }
                    if AssistantAttachments.isLongPaste(pasted) {
                        item.setNoResult()
                        text(pasted)
                    } else {
                        // Plain: the field holds plain text anyway.
                        item.setResult(string: pasted)
                    }
                }
                return
            }
            guard takesImages, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                return pasteAsUsual(supporting, item)
            }
            item.setNoResult()
            Task {
                guard let data = await Self.imageData(provider) else {
                    ErrorBanner.shared.show(AssistantAttachmentError.unreadable(String(localized: "Image")))
                    return
                }
                images([data])
            }
        }

        private func pasteAsUsual(_ supporting: any UITextPasteConfigurationSupporting, _ item: any UITextPasteItem) {
            if let original, original.responds(to: #selector(textPasteConfigurationSupporting(_:transform:))) {
                original.textPasteConfigurationSupporting?(supporting, transform: item)
            } else {
                item.setDefaultResult()
            }
        }

        private nonisolated static func text(_ provider: NSItemProvider) async -> String? {
            await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    continuation.resume(returning: (object as? NSString).map { $0 as String })
                }
            }
        }

        private nonisolated static func imageData(_ provider: NSItemProvider) async -> Data? {
            await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
            }
        }

        func textPasteConfigurationSupporting(_ supporting: any UITextPasteConfigurationSupporting,
                                              shouldAnimatePasteOf attributedString: NSAttributedString,
                                              to textRange: UITextRange) -> Bool {
            original?.textPasteConfigurationSupporting?(supporting, shouldAnimatePasteOf: attributedString,
                                                        to: textRange) ?? true
        }
    }
}
#endif

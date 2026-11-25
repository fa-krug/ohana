import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// What goes into the chat: the field with its one button, sending, and the attachments read from
// a picker, a scan, a drop or the pasteboard. Part of `AssistantChatView` (AssistantChatView.swift).

extension AssistantChatView {
    // MARK: Composer

    var filled: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// While the assistant answers, a message waits and goes next (once the chat has its id).
    /// Not while a chat opens: a message then would start a new chat in its place.
    private var canSend: Bool {
        store.ready && preparing == 0 && !opening && (!store.busy || !(store.current?.id.isEmpty ?? true))
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The settings couldn't be loaded (and there's no copy here): the chat shows, sending waits.
            if store.settings == nil, let error = store.settingsError {
                HStack(spacing: 8) {
                    Label {
                        Text(verbatim: error).lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Try again") { Task { await store.loadSettings() } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
            }
            if !attachments.isEmpty || preparing > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { pendingAttachment in
                            AssistantPendingChip(attachment: pendingAttachment) {
                                attachments.removeAll { $0.id == pendingAttachment.id }
                            }
                        }
                        ForEach(0..<preparing, id: \.self) { _ in
                            ProgressView()
                                .frame(width: 52, height: 52)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                // Bounces only once the chips don't fit.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            // One box, as in Claude's app: the text over the whole width (two lines at least, it
            // grows to ten), the attach menu and Send / Stop / the mic in a row under it.
            VStack(alignment: .leading, spacing: 2) {
                field
                HStack(spacing: 8) {
                    attachMenu
                    Spacer(minLength: 0)
                    actionButton
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            .contentShape(.rect(cornerRadius: 24))
            // A tap anywhere in the box (not on its buttons) starts typing.
            .onTapGesture { if store.ready { composerFocused = true } }
            // Only once the chat nears the point where older messages get condensed.
            if let usage = store.current?.usage, AssistantContextMeter.shows(usage) {
                AssistantContextMeter(usage: usage)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // Here, not beside the attachments' file picker: two on one view don't both work.
        .letterScanFlow(isPresented: $scanningLetter, findsItems: false) { outcome in attachLetter(outcome) }
    }

    private var attachMenu: some View {
        Menu {
            // A button, not a `PhotosPicker`: that opens the photo library (a synchronous call to
            // the system) as soon as the menu is built, which held up the panel's opening.
            Button("Photo library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            Button("Choose files", systemImage: "folder") { importing = true }
            // Only the text read on the device is attached, never the picture.
            Button("Scan Letter", systemImage: "doc.text.viewfinder") { scanningLetter = true }
            #if os(iOS)
            // Paste in the field takes pictures too; this works without the edit menu.
            Button("Paste image", systemImage: "doc.on.clipboard") { pasteImages() }
            #endif
        } label: {
            Image(systemName: "paperclip")
                .font(.body.weight(.semibold))
                .frame(width: AssistantComposerButton.size, height: AssistantComposerButton.size)
                .contentShape(.circle)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(store.ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .disabled(!store.ready)
        .accessibilityLabel(Text("Attach images or text files"))
        .help(Text("Attach images or text files"))
    }

    var field: some View {
        TextField(placeholder, text: $text, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain)
            // At least two lines high: longer messages are common.
            .lineLimit(2...10)
            .focused($composerFocused)
            // The on-screen keyboard's Return puts in a line break and the Send button sends
            // (as in Messages); a hardware keyboard's Return sends. Only hardware keys get here.
            .onKeyPress(.return, phases: .down) { press in
                switch AssistantReturnKey.action(for: press.modifiers) {
                case .send:
                    send()
                    return .handled
                case .lineBreak:
                    (text, selection) = AssistantReturnKey.insertingLineBreak(into: text, at: selection)
                    return .handled
                case .system:
                    return .ignored
                }
            }
            #if os(macOS)
            .onSubmit { send() }
            #else
            .modifier(AssistantPaste(enabled: store.ready, empty: text.isEmpty, images: { attach(pasted: $0) },
                                     text: { attach(pastedText: $0) }))
            #endif
            .disabled(!store.ready)
            .padding(.horizontal, 16)
            .padding(.top, 14)
    }

    /// What the button beside the field does: one slot for Send, Stop and (on iPhone and iPad)
    /// the mic.
    var action: AssistantComposerAction {
        AssistantComposerAction.make(filled: filled, busy: store.busy,
                                     canQueue: !(store.current?.id.isEmpty ?? true),
                                     dictation: AssistantDictation.isAvailable, listening: listening)
    }

    /// One button that morphs between Send, Stop and the mic (`AssistantComposerButton`).
    private var actionButton: some View {
        let action = action
        return AssistantComposerButton(action: action, listening: listening, busy: store.busy,
                                       enabled: enabled(action), shortcut: shortcut(action)) {
            perform(action)
        }
        // Typing while the assistant answers puts Send in Stop's place: ⌘. still stops it.
        .background {
            if action == .send, store.busy, mode != .page {
                Button("Stop") { Task { await store.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    func enabled(_ action: AssistantComposerAction) -> Bool {
        switch action {
        case .send: canSend && filled
        case .stop: true
        case .dictate: store.ready
        }
    }

    func shortcut(_ action: AssistantComposerAction) -> KeyboardShortcut? {
        switch action {
        case .send: KeyboardShortcut(.return, modifiers: .command)
        // On the page, Assistant ▸ Stop has it.
        case .stop: mode == .page ? nil : KeyboardShortcut(".", modifiers: .command)
        case .dictate: nil
        }
    }

    private func perform(_ action: AssistantComposerAction) {
        switch action {
        case .send:
            send()
        case .stop:
            Task { await store.stop() }
        case .dictate:
            // iPhone and iPad only: the Mac's keyboard has dictation of its own (Edit ▸ Start Dictation).
            #if os(iOS)
            if dictation.isListening {
                dictation.stop()
            } else {
                composerFocused = false
                let base = text
                Task { await dictation.start(base: base) { text = $0 } }
            }
            #endif
        }
    }

    var listening: Bool {
        #if os(iOS)
        dictation.isListening
        #else
        false
        #endif
    }

    var placeholder: LocalizedStringKey {
        // Until the settings are known the field just waits (disabled), without a word of setting up.
        if store.settings?.configured == false { return "Set up the assistant in the settings first" }
        if listening { return "Listening…" }
        if store.busy { return "Next message – sent once this answer is done…" }
        // Send answers the open question (a tap on an option does too).
        return store.composerAnswers ? "Your own answer…" : "Ask me anything…"
    }

    func send() {
        #if os(iOS)
        dictation.stop()
        #endif
        let message = text
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              canSend else { return }
        let files = attachments
        text = ""
        selection = nil
        attachments = []
        // Scrolled to the top once it is in the chat (a waiting message: once its turn comes).
        sentPending = true
        Task {
            do {
                try await store.send(message, attachments: files.map(\.outgoing))
            } catch {
                sentPending = false
                // It couldn't wait: back in the box, to send again.
                if text.isEmpty { text = message }
                if attachments.isEmpty { attachments = files }
            }
        }
    }

    // MARK: Attachments

    var room: Int { AssistantAttachments.maxCount - attachments.count - preparing }

    /// Reads attachments one by one (each shows a spinner meanwhile); more than there is room
    /// for are left out with a note.
    private func prepare(_ count: Int, _ read: @escaping (Int) async throws -> AssistantPendingAttachment?) {
        if count > room { ErrorBanner.shared.show(AssistantAttachments.limitMessage) }
        for itemIndex in 0..<min(count, max(0, room)) {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                do {
                    guard let attachment = try await read(itemIndex) else { return }
                    attachments.append(attachment)
                    if AssistantAttachments.wasCut(attachment) {
                        ErrorBanner.shared.show(AssistantAttachments.cutMessage(attachment.name))
                    }
                } catch {
                    ErrorBanner.shared.show(error)
                }
            }
        }
    }

    func attach(_ urls: [URL]) {
        prepare(urls.count) { itemIndex in
            let url = urls[itemIndex]
            return try await Task.detached { try AssistantAttachments.read(url) }.value
        }
    }

    func attach(_ items: [PhotosPickerItem]) {
        let first = attachments.count
        prepare(items.count) { itemIndex in
            let name = String(localized: "Photo \(first + itemIndex + 1).jpg")
            guard let data = try await items[itemIndex].loadTransferable(type: Data.self) else {
                throw AssistantAttachmentError.unreadable(name)
            }
            return try await Task.detached { try AssistantAttachments.image(data, name: name) }.value
        }
    }

    /// A scanned letter's text (read on the device; its PDF saved by the review sheet), with the
    /// request to find what to add in it when nothing is typed yet (sent once the user taps Send).
    private func attachLetter(_ outcome: LetterScanOutcome) {
        guard let letter = outcome.text else { return }
        prepare(1) { _ in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = AssistantLetter.prompt }
            return AssistantLetter.attachment(letter)
        }
        focusComposer()
    }

    /// Images from the clipboard.
    func attach(pasted images: [Data]) {
        let first = attachments.count
        prepare(images.count) { itemIndex in
            let name = String(localized: "Photo \(first + itemIndex + 1).jpg")
            let data = images[itemIndex]
            return try await Task.detached { try AssistantAttachments.image(data, name: name) }.value
        }
    }

    /// Long pasted text, as a text file (`AssistantAttachments.isLongPaste`).
    func attach(pastedText text: String) {
        prepare(1) { _ in AssistantAttachments.pastedText(text) }
    }

    /// Files and pictures dropped on the chat.
    func drop(_ providers: [NSItemProvider]) {
        prepare(providers.count) { itemIndex in
            try await AssistantAttachments.load(providers[itemIndex])
        }
    }

    #if os(iOS)
    /// The pictures on the clipboard (the attach menu's "Paste image").
    private func pasteImages() {
        let board = UIPasteboard.general
        guard board.hasImages else {
            ErrorBanner.shared.show(String(localized: "There is no picture on the clipboard."))
            return
        }
        let images = (board.images ?? []).compactMap { $0.jpegData(compressionQuality: 0.95) }
        attach(pasted: images)
    }
    #endif

    #if os(macOS)
    /// ⌘V in the composer with a picture (or image files) on the clipboard attaches them; text
    /// pastes as usual. (The text field would ignore pictures.)
    func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v", composerFocused, store.ready,
                  let content = AssistantPasteboard.content() else { return event }
            switch content {
            case let .files(urls): attach(urls)
            case let .image(data): attach(pasted: [data])
            case let .text(text): attach(pastedText: text)
            }
            return nil
        }
    }

    func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
    #endif
}

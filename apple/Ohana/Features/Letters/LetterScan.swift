import CoreGraphics
import SwiftUI

// Scanning a letter (a school letter, a daycare's closure notice, an invitation): the pages are
// photographed with the document camera (or picked as a photo or PDF, then cropped to the paper:
// `ScanCrop`), their text is read on the device, and a review sheet (`LetterReviewSheet`) offers
// to save them as a searchable PDF in a folder of the user's (`ScanFiling`) and, from the shell,
// lists the events, tasks and deadlines the server found in the text (`LetterFind.swift`: only
// the text goes to the server), to edit and tick; Done adds the ticked ones. From the family
// menu, Spotlight / Siri / Shortcuts (`ScanLetterIntent`; both `FamilyContext.scanLetter()`,
// hosted by the shell: `ShellLetterScan`) and the assistant composer's attach menu (which attaches
// the text to the chat instead). Photos and PDFs shared to Ohana (the share sheet, Open With on the
// Mac: `LetterScanInbox`) skip the scanner and go to the shell's review as picked pages.

enum LetterScanError: LocalizedError {
    case noText
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noText: String(localized: "No text found in the scan.")
        case .unreadable: String(localized: "The letter couldn’t be read.")
        }
    }
}

/// A letter of up to 20 pages; more aren't read.
enum LetterScan {
    static let maxPages = 20
    /// The most of its text sent on (to `POST /ai/letter` or as a chat attachment): 20 dense pages.
    static let maxText = 100_000
}

extension View {
    /// Scans paper when `isPresented` turns on: the document camera on an iPhone or iPad with
    /// one, else (the Mac, the Simulator) a file picker for a photo or PDF. `onScan` gets the
    /// pages' images (never none) and whether they still need cropping (picked, not from the
    /// camera).
    func paperScanner(isPresented: Binding<Bool>, maxPages: Int,
                      onScan: @escaping (_ images: [CGImage], _ needsCrop: Bool) -> Void) -> some View {
        modifier(PaperScanner(isPresented: isPresented, maxPages: maxPages, onScan: onScan))
    }

    /// The whole flow for a letter: the scanner when `isPresented` turns on, then the review sheet
    /// (saving the PDF, and with `findsItems` what the server finds in the letter to add). A
    /// `shared` letter goes to the review without the scanner (it's cleared). `onDone` gets the
    /// letter once the sheet has gone (the PDF saved and the ticked items added by then).
    func letterScanFlow(isPresented: Binding<Bool>, shared: Binding<SharedLetter?> = .constant(nil),
                        findsItems: Bool, onDone: @escaping (LetterScanOutcome) -> Void = { _ in }) -> some View {
        modifier(LetterScanFlow(isPresented: isPresented, shared: shared, findsItems: findsItems, onDone: onDone))
    }
}

/// What the review sheet hands back.
struct LetterScanOutcome {
    /// The letter's text; nil when none could be read.
    let text: String?
}

private struct PaperScanner: ViewModifier {
    @Binding var isPresented: Bool
    let maxPages: Int
    let onScan: ([CGImage], Bool) -> Void
    @State private var importing = false
    @State private var camera = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) {
                guard isPresented else { return }
                isPresented = false
                #if os(iOS)
                if DocumentCamera.isSupported {
                    camera = true
                    return
                }
                #endif
                importing = true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: ReceiptReader.fileTypes) { result in
                switch result {
                case let .success(url):
                    Task {
                        do {
                            let images = try await ReceiptReader.images(at: url, maxPages: maxPages)
                            guard !images.isEmpty else { throw LetterScanError.unreadable }
                            onScan(images, true)
                        } catch is ReceiptError {
                            ErrorBanner.shared.show(LetterScanError.unreadable)
                        } catch {
                            ErrorBanner.shared.show(error)
                        }
                    }
                case let .failure(error):
                    ErrorBanner.shared.show(error)
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $camera) {
                DocumentCamera(maxPages: maxPages) { pages in
                    camera = false
                    if !pages.isEmpty { onScan(pages, false) }
                }
                .ignoresSafeArea()
            }
            #endif
    }
}

private struct LetterScanFlow: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var shared: SharedLetter?
    let findsItems: Bool
    let onDone: (LetterScanOutcome) -> Void
    @Environment(FamilyContext.self) private var family
    @State private var review: LetterReview?
    /// What the sheet was done with, handed on once it has gone (the assistant may show next).
    @State private var finished: LetterScanOutcome?

    func body(content: Content) -> some View {
        content
            .paperScanner(isPresented: $isPresented, maxPages: LetterScan.maxPages) { images, needsCrop in
                Task {
                    // After the camera or the file picker has gone: one presentation at a time.
                    try? await Task.sleep(for: .milliseconds(350))
                    show(images, needsCrop: needsCrop)
                }
            }
            .onChange(of: shared?.id, initial: true) {
                guard let letter = shared else { return }
                shared = nil
                // Shared files are pages as picked: cropped to the paper first.
                show(letter.images, needsCrop: true)
            }
            .sheet(item: $review, onDismiss: {
                guard let outcome = finished else { return }
                finished = nil
                onDone(outcome)
            }) { review in
                LetterReviewSheet(review: review, events: FamilyEventCreator(api: family.api),
                                  eventsAdded: { family.didChange(.events) }) { finished = $0 }
                    .errorBanner()
            }
    }

    private func show(_ images: [CGImage], needsCrop: Bool) {
        let review = LetterReview(images: images, needsCrop: needsCrop,
                                  finder: findsItems ? FamilyLetterFinder(api: family.api) : nil)
        review.start(names: LetterReview.familyNames(family.api))
        self.review = review
    }
}

/// The shell's letter scan (`FamilyContext.scanLetter()`, the family menu, "Scan Letter" from
/// Spotlight, Siri or Shortcuts): the flow, with what the server finds in the letter to add. On
/// iPhone the assistant's sheet or a page's sheet closes first: one presentation at a time.
struct ShellLetterScan: ViewModifier {
    let context: FamilyContext
    @Binding var assistantSheet: Bool
    @Binding var phonePage: Module?
    @State private var scanning = false
    @State private var shared: SharedLetter?

    /// The server can look for what to add: the assistant on, an editor, a server (not the demo).
    private var findsItems: Bool {
        context.isEnabled(.assistant) && context.canEdit && !context.api.client.isDemo
    }

    func body(content: Content) -> some View {
        content
            .letterScanFlow(isPresented: $scanning, shared: $shared, findsItems: findsItems)
            .onChange(of: context.letterScanRequest) {
                guard context.takeLetterScanRequest() else { return }
                let covered = uncover()
                Task {
                    try? await Task.sleep(for: .milliseconds(covered ? 500 : 150))
                    scanning = true
                }
            }
            .onChange(of: LetterScanInbox.shared.pending, initial: true) {
                // "Scan Letter" from Spotlight, Siri or Shortcuts.
                if LetterScanInbox.shared.take() { context.scanLetter() }
            }
            .onChange(of: LetterScanInbox.shared.letter?.id, initial: true) {
                // Photos and PDFs shared to Ohana: straight to the review, once all of them are read.
                guard LetterScanInbox.shared.letter != nil else { return }
                let covered = uncover()
                Task {
                    try? await Task.sleep(for: .milliseconds(covered ? 500 : 150))
                    await LetterScanInbox.shared.settled()
                    if let letter = LetterScanInbox.shared.takeLetter() { shared = letter }
                }
            }
    }

    /// Closes what would cover the scanner on iPhone (a page's sheet, the assistant's); whether
    /// anything did.
    private func uncover() -> Bool {
        var covered = phonePage != nil
        #if os(iOS)
        covered = covered || assistantSheet && UIDevice.current.userInterfaceIdiom == .phone
        #endif
        if covered {
            phonePage = nil
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone { assistantSheet = false }
            #endif
        }
        return covered
    }
}

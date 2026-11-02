import AppIntents
import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

/// "Scan Letter" for Spotlight (the Home Screen search), Siri, Shortcuts and the Action button:
/// opens the app with the letter scanner over whatever it shows, for the family on screen. Works
/// without a server too (the demo): the PDF is saved on the device.
struct ScanLetterIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan Letter"
    static let description = IntentDescription("Scans a letter and saves it as a PDF, or has the assistant suggest the dates and tasks in it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LetterScanInbox.shared.post()
        return .result()
    }
}

/// Pages handed to Ohana from outside: images and PDFs shared to it (the share sheet) or opened
/// with it (the Mac's Open With, the Dock icon). They go to the letter review as if just scanned.
struct SharedLetter: Identifiable {
    let id = UUID()
    var images: [CGImage]
}

/// What the shell (`ShellLetterScan`) picks up once it shows: the intent's request to scan, and
/// files shared to Ohana.
@Observable
final class LetterScanInbox {
    static let shared = LetterScanInbox()

    private(set) var pending: UUID?
    /// Files read and waiting for the review; several arriving together make one letter.
    private(set) var letter: SharedLetter?

    func post() { pending = UUID() }

    /// Whether there was a request (it's cleared).
    func take() -> Bool {
        defer { pending = nil }
        return pending != nil
    }

    /// The pages of the files shared so far (cleared).
    func takeLetter() -> SharedLetter? {
        defer { letter = nil }
        return letter
    }

    /// Whether Ohana takes the file: a photo or a PDF (`CFBundleDocumentTypes` in project.yml).
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// The files being read, one after the other (their pages in the order they came).
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// Reads a shared file's pages and adds them to the waiting letter (at most
    /// `LetterScan.maxPages`); the copy iOS handed over is deleted then.
    func receive(_ url: URL) {
        let previous = reading
        reading = Task {
            await previous?.value
            await read(url)
        }
    }

    /// Once every file shared so far is read.
    func settled() async {
        while let task = reading {
            await task.value
            if reading == task { reading = nil }
        }
    }

    private func read(_ url: URL) async {
        defer { Self.discard(url) }
        do {
            let images = try await ReceiptReader.images(at: url, maxPages: LetterScan.maxPages)
            guard !images.isEmpty else { throw LetterScanError.unreadable }
            add(images)
        } catch {
            ErrorBanner.shared.show(LetterScanError.unreadable)
        }
    }

    func add(_ images: [CGImage]) {
        if var letter {
            letter.images = Array((letter.images + images).prefix(LetterScan.maxPages))
            self.letter = letter
        } else {
            letter = SharedLetter(images: Array(images.prefix(LetterScan.maxPages)))
        }
    }

    /// iOS hands over a copy in the app's own container (its Inbox): gone once read. A file opened
    /// on the Mac is the user's own and stays.
    private static func discard(_ url: URL) {
        #if os(iOS)
        let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath().path
        if url.resolvingSymlinksInPath().path.hasPrefix(home + "/") {
            try? FileManager.default.removeItem(at: url)
        }
        #endif
    }
}

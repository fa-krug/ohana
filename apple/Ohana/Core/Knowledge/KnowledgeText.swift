import CoreGraphics
import Foundation
import ImageIO
import PDFKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Reads a knowledge file's text on the device, page by page: a PDF's text layer (`KnowledgeOCR` for
/// a page without one: a scan, turned upright, tables as Markdown), an image's text (the same),
/// plain text, Markdown and CSV, RTF, HTML,
/// and on the Mac Word and OpenDocument files (what `NSAttributedString` reads there). nil for a
/// format this device can't read (Pages, a spreadsheet, a Word file on iOS) or a file that can't
/// be read (a locked PDF, OCR failing): the indexer skips it, the server keeps asking, and another
/// device may read it. Pages without text are kept (empty) only when the file truly has none.
nonisolated enum KnowledgeText {
    /// A PDF page with fewer letters than this in its text layer is read by OCR (a scan).
    static let ocrThreshold = 20
    /// The long side of a PDF page rendered for OCR, in pixels (about 2× its size in points).
    static let ocrScale: CGFloat = 2
    static let maxOCRPixels: CGFloat = 4000

    /// The reader's version for files whose text may come from OCR (PDFs, images); other files are
    /// read as by version 1. A newer one makes the server ask for those files again (the manifest's
    /// `reader`), and a file the device couldn't read before is tried again.
    static let readerVersion = 2
    /// At most this many page images go to the family's AI per document (the server's limit).
    static let maxScans = 20

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    static let htmlExtensions: Set<String> = ["html", "htm"]

    /// The formats `NSAttributedString` reads on this device, by extension.
    static var attributedTypes: [String: NSAttributedString.DocumentType] {
        #if os(macOS)
        ["rtf": .rtf, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument]
        #else
        ["rtf": .rtf]
        #endif
    }

    /// The reader version a file at `path` is read with: `readerVersion` for PDFs and images, else 1.
    static func reader(forPath path: String) -> Int {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "pdf" || imageExtensions.contains(ext) ? readerVersion : 1
    }

    /// Which pages' images to keep for the family's AI while reading.
    enum ScanCapture: Equatable, Sendable {
        case none
        /// Every page (the family's *Read with the assistant*, *Read Again with the Assistant*).
        case all
    }

    /// A page's image for the family's AI: upright JPEG; `page` from 1.
    struct PageScan: Equatable, Sendable {
        var page: Int
        var jpeg: Data
    }

    /// Whether this device reads files like `url` at all.
    static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || textExtensions.contains(ext) || imageExtensions.contains(ext)
            || htmlExtensions.contains(ext) || attributedTypes[ext] != nil
    }

    /// What reading a file came to.
    enum Outcome: Equatable, Sendable {
        /// Its text by page, within the server's limits.
        case pages([String])
        /// A format this device doesn't read.
        case unsupported
        /// Its content couldn't be loaded (iCloud didn't, it's gone): worth trying again.
        case unavailable
        /// Loaded, but no text came out (a locked or broken PDF, OCR failing): not tried again
        /// while the file is the same.
        case failed
    }

    /// What reading a file came to, with the page images `capture` asked for (at most `maxScans`;
    /// only with `.pages`).
    struct Reading: Sendable {
        var outcome: Outcome
        var scans: [PageScan] = []
    }

    /// The file's text by page, within the server's limits (`limited`); nil when this device can't
    /// read it.
    @concurrent
    static func pages(of url: URL) async -> [String]? {
        if case let .pages(pages) = await read(url).outcome { pages } else { nil }
    }

    /// Reads the file (off the main actor: loading it from iCloud and OCR may take a while).
    @concurrent
    static func read(_ url: URL, capture: ScanCapture = .none) async -> Reading {
        guard canRead(url) else { return Reading(outcome: .unsupported) }
        guard let data = coordinatedData(url) else { return Reading(outcome: .unavailable) }
        guard let read = await read(data, ext: url.pathExtension.lowercased(), capture: capture) else {
            return Reading(outcome: .failed)
        }
        return Reading(outcome: .pages(limited(read.pages)), scans: read.scans)
    }

    private static func read(_ data: Data, ext: String, capture: ScanCapture) async -> (pages: [String], scans: [PageScan])? {
        let pages: [String]?
        if ext == "pdf" {
            return await pdfPages(data, capture: capture)
        } else if imageExtensions.contains(ext) {
            return await imagePages(data, capture: capture)
        } else if textExtensions.contains(ext) {
            pages = [plainText(data)]
        } else if htmlExtensions.contains(ext) {
            pages = [htmlText(plainText(data))]
        } else if let type = attributedTypes[ext] {
            pages = attributedText(data, type: type).map { [$0] }
        } else {
            pages = nil
        }
        return pages.map { ($0, []) }
    }

    /// The file's content, read coordinated: iCloud loads a file that isn't on the device first.
    static func coordinatedData(_ url: URL) -> Data? {
        var data: Data?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        return data
    }

    // MARK: Formats

    /// A PDF's pages: the text layer, OCR where a page has (almost) none; with the images of the
    /// pages `capture` asks for.
    static func pdfPages(_ data: Data, capture: ScanCapture = .none) async -> (pages: [String], scans: [PageScan])? {
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        var pages: [String] = []
        var scans: [PageScan] = []
        for index in 0..<min(document.pageCount, KnowledgeLimits.maxPages) {
            guard let page = document.page(at: index) else {
                pages.append("")
                continue
            }
            let text = page.string ?? ""
            let room = scans.count < maxScans
            if letterCount(text) >= ocrThreshold {
                pages.append(text)
                if capture == .all, room, let image = render(page), let jpeg = KnowledgeOCR.scanJPEG(image, orientation: .up) {
                    scans.append(PageScan(page: index + 1, jpeg: jpeg))
                }
                continue
            }
            guard let image = render(page) else {
                pages.append(text)
                continue
            }
            guard let read = await KnowledgeOCR.read(image) else { return nil }
            pages.append(letterCount(read.text) > letterCount(text) ? read.text : text)
            if room, capture == .all,
               let jpeg = KnowledgeOCR.scanJPEG(image, orientation: read.orientation) {
                scans.append(PageScan(page: index + 1, jpeg: jpeg))
            }
        }
        return (pages, scans)
    }

    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// The page as an image about `ocrScale` times its size, white behind it, rotated as shown.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let turned = page.rotation % 180 != 0
        let width = turned ? bounds.height : bounds.width, height = turned ? bounds.width : bounds.height
        guard width > 0, height > 0 else { return nil }
        let scale = min(ocrScale, maxOCRPixels / max(width, height))
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let image = page.thumbnail(of: size, for: .mediaBox)
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// The text of a photo or scanned image (its EXIF orientation applied, then turned the way its
    /// text runs), as one page; with its image when `capture` asks for it.
    static func imagePages(_ data: Data, capture: ScanCapture = .none) async -> (pages: [String], scans: [PageScan])? {
        guard let image = KnowledgeOCR.uprightImage(data, maxSide: maxOCRPixels),
              let read = await KnowledgeOCR.read(image) else { return nil }
        var scans: [PageScan] = []
        if capture == .all,
           let jpeg = KnowledgeOCR.scanJPEG(image, orientation: read.orientation) {
            scans.append(PageScan(page: 1, jpeg: jpeg))
        }
        return ([read.text], scans)
    }

    /// Text as UTF-8 (a byte order mark dropped), else Windows-1252 / Latin-1.
    static func plainText(_ data: Data) -> String {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// RTF (and Word, OpenDocument on the Mac) through `NSAttributedString`.
    static func attributedText(_ data: Data, type: NSAttributedString.DocumentType) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string
    }

    /// The text of an HTML page: without scripts, styles and tags, entities decoded, a line break
    /// for each block. Not `NSAttributedString` (it needs WebKit on the main thread).
    static func htmlText(_ html: String) -> String {
        var text = html.replacing(/(?s)<!--.*?-->/, with: "")
        text = text.replacing(/(?is)<(script|style|noscript|template|head)\b.*?<\/\1\s*>/, with: "")
        text = text.replacing(/(?i)<br\s*\/?>/, with: "\n")
        text = text.replacing(
            /(?i)<\/?(p|div|li|tr|h[1-6]|ul|ol|table|section|article|header|footer|blockquote|pre|dt|dd|title)\b[^>]*>/,
            with: "\n")
        text = text.replacing(/(?i)<\/(td|th)\s*>/, with: "\t")
        text = text.replacing(/<[^>]*>/, with: "")
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" || $0 == "\r" }).joined(separator: " ")
        }
        return lines.joined(separator: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "euro": "€", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®", "sect": "§",
        "laquo": "«", "raquo": "»", "bdquo": "„", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "deg": "°", "middot": "·", "bull": "•",
    ]

    static func decodeEntities(_ text: String) -> String {
        text.replacing(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});/) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#") {
                let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = hex ? name.dropFirst(2) : name.dropFirst()
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    return String(Character(scalar))
                }
                return String(match.output.0)
            }
            return entities[name] ?? String(match.output.0)
        }
    }

    // MARK: Limits

    /// The pages within the server's limits (NFC, as the server counts): at most `maxPages`, at
    /// most `maxTextBytes` of UTF-8 in all; the text beyond is cut off, not refused.
    static func limited(_ pages: [String], maxPages: Int = KnowledgeLimits.maxPages,
                        maxBytes: Int = KnowledgeLimits.maxTextBytes) -> [String] {
        var budget = maxBytes
        var result: [String] = []
        for page in pages.prefix(maxPages) {
            let page = page.precomposedStringWithCanonicalMapping
            let bytes = page.utf8.count
            if bytes <= budget {
                result.append(page)
                budget -= bytes
                continue
            }
            var cut = String.UnicodeScalarView()
            for scalar in page.unicodeScalars {
                let length = String(scalar).utf8.count
                guard length <= budget else { break }
                cut.append(scalar)
                budget -= length
            }
            result.append(String(cut))
            break
        }
        return result
    }
}

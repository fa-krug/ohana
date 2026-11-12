import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import Vision
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Reads a scanned page (a PDF page without a text layer, a photo) on the device: Vision's text
/// read upright first, the page turned the way its lines run (a timetable photographed sideways),
/// then Vision's document reader in that orientation, which keeps tables as tables (Markdown), and
/// a verdict whether the result looks right (`KnowledgeOCRQuality`). Nothing here runs on the main
/// actor but the spell checker's few look-ups.
nonisolated enum KnowledgeOCR {
    static let languages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
    /// A page image for the family's AI: its longest side at most this, JPEG at this quality, and
    /// never more than `maxScanBytes` (the server's limit).
    static let maxScanSide: CGFloat = 2000
    static let scanQuality: CGFloat = 0.7
    static let maxScanBytes = 4_000_000
    /// A page is paper when at least this share of it is light (the timetable: 0.9).
    static let minPaperShare = 0.6

    private static let log = Logger(subsystem: "de.fa-krug.Ohana", category: "knowledge")

    /// What a page came to.
    struct Page: Sendable {
        var text: String
        /// The orientation the page was read in (applied to the image, it's upright).
        var orientation: CGImagePropertyOrientation
        var verdict: KnowledgeOCRQuality.Verdict
        var measures: KnowledgeOCRQuality.Measures
    }

    /// The page's text, the orientation it was read in and how good it looks; nil when Vision fails.
    static func read(_ image: CGImage) async -> Page? {
        let upright: [RecognizedTextObservation]
        do {
            upright = try await recognizeText(image, orientation: .up)
        } catch {
            log.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let size = CGSize(width: image.width, height: image.height)
        let samples = upright.compactMap { observation -> KnowledgeOCROrientation.Sample? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return KnowledgeOCROrientation.Sample(
                angle: KnowledgeOCROrientation.angle(from: observation.bottomLeft.cgPoint,
                                                     to: observation.bottomRight.cgPoint, size: size),
                weight: text.count)
        }
        let orientation = KnowledgeOCROrientation.vote(samples)

        var text = ""
        var lines: [KnowledgeOCRLine] = []
        var tables: [[KnowledgeOCRCell]] = []
        if let document = try? await recognizeDocument(image, orientation: orientation) {
            text = document.text
            lines = document.lines
            tables = document.tables
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The document reader found nothing: the lines of the best orientation.
            let observations = orientation == .up ? upright
                : ((try? await recognizeText(image, orientation: orientation)) ?? upright)
            lines = observations.compactMap { observation in
                observation.topCandidates(1).first.map { KnowledgeOCRLine($0.string, $0.confidence) }
            }
            text = lines.map(\.text).joined(separator: "\n")
            tables = []
        }
        let words = KnowledgeOCRQuality.checkableWords(lines)
        let known = await KnowledgeSpelling.known(words)
        let measures = KnowledgeOCRQuality.measure(lines: lines, tables: tables, known: known.map { set in { set.contains($0) } })
        let verdict = KnowledgeOCRQuality.verdict(measures, ink: inkShare(image))
        return Page(text: text, orientation: orientation, verdict: verdict, measures: measures)
    }

    private static func recognizeText(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws
        -> [RecognizedTextObservation] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        return try await request.perform(on: image, orientation: orientation)
    }

    private struct DocumentText {
        var text: String
        var lines: [KnowledgeOCRLine]
        var tables: [[KnowledgeOCRCell]]
    }

    /// The page as Vision's document reader sees it in `orientation`: the paragraphs and tables in
    /// reading order (`KnowledgeOCRLayout`), its lines and the tables' cells.
    private static func recognizeDocument(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws
        -> DocumentText? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = languages
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: image, orientation: orientation)
        guard !observations.isEmpty else { return nil }
        var texts: [String] = []
        var lines: [KnowledgeOCRLine] = []
        var tables: [[KnowledgeOCRCell]] = []
        for observation in observations {
            let container = observation.document
            let cells = container.tables.map { table in
                table.rows.flatMap { row in
                    row.map { KnowledgeOCRCell(row: $0.rowRange.lowerBound, column: $0.columnRange.lowerBound,
                                               text: $0.content.text.transcript) }
                }
            }
            tables += cells
            let paragraphs = container.paragraphs.map {
                KnowledgeOCRLayout.Block(text: $0.transcript, box: $0.boundingRegion.boundingBox.cgRect)
            }
            let tableBlocks = zip(container.tables, cells).map { table, cells in
                KnowledgeOCRLayout.Block(text: KnowledgeOCRLayout.markdownTable(cells),
                                         box: table.boundingRegion.boundingBox.cgRect)
            }
            texts.append(KnowledgeOCRLayout.arrange(paragraphs: paragraphs, tables: tableBlocks))
            lines += container.text.lines.compactMap { line in
                line.topCandidates(1).first.map { KnowledgeOCRLine($0.string, $0.confidence) }
            }
        }
        return DocumentText(text: texts.filter { !$0.isEmpty }.joined(separator: "\n\n"), lines: lines, tables: tables)
    }

    // MARK: Images

    /// The share of the page's pixels that are ink (darker than mid-gray), measured on a small copy;
    /// nil for an image that doesn't look like paper (less than `minPaperShare` of it light: a
    /// photo), whose lack of text says nothing.
    static func inkShare(_ image: CGImage) -> Double? {
        let side = 300.0
        let scale = min(1, side / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var dark = 0, light = 0
        for index in 0..<(width * height) {
            let value = pixels[index]
            if value < 160 { dark += 1 } else if value > 200 { light += 1 }
        }
        let count = Double(width * height)
        return Double(light) / count < minPaperShare ? nil : Double(dark) / count
    }

    /// `image` turned as `orientation` says (`.left`: a quarter turn counterclockwise, `.right`
    /// clockwise, `.down` half a turn; a mirrored one isn't turned: image files come upright from
    /// `uprightImage`), scaled to at most `maxSide`.
    static func turned(_ image: CGImage, _ orientation: CGImagePropertyOrientation, maxSide: CGFloat? = nil) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let swaps = orientation == .left || orientation == .right
        let outWidth = swaps ? height : width, outHeight = swaps ? width : height
        let scale = maxSide.map { min(1, $0 / max(outWidth, outHeight)) } ?? 1
        if !swaps, orientation != .down, scale == 1 { return image }
        let pixelWidth = max(1, Int((outWidth * scale).rounded())), pixelHeight = max(1, Int((outHeight * scale).rounded()))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(pixelWidth) / outWidth, y: CGFloat(pixelHeight) / outHeight)
        // CoreGraphics' y runs up: a positive angle turns counterclockwise.
        switch orientation {
        case .down: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height))
        case .left: context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0))
        case .right: context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width))
        default: break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The page for the family's AI: upright, at most `maxScanSide`, JPEG under `maxScanBytes`.
    static func scanJPEG(_ image: CGImage, orientation: CGImagePropertyOrientation) -> Data? {
        guard let upright = turned(image, orientation, maxSide: maxScanSide) else { return nil }
        for quality in [scanQuality, 0.5, 0.3] {
            guard let data = jpeg(upright, quality: quality) else { return nil }
            if data.count <= maxScanBytes { return data }
        }
        return nil
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// An image file's first image, upright (its EXIF orientation applied), at most `maxSide`.
    static func uprightImage(_ data: Data, maxSide: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The words the system's spell checker knows in German or English (`KnowledgeOCRQuality`'s known
/// share). Asked on the main actor, where the checkers live; nil when neither language is there.
@MainActor
enum KnowledgeSpelling {
    static func known(_ words: Set<String>) -> Set<String>? {
        guard !words.isEmpty else { return [] }
        let languages = checkerLanguages
        guard !languages.isEmpty else { return nil }
        return words.filter { word in languages.contains { isKnown(word, language: $0) } }
    }

    #if os(macOS)
    private static var checkerLanguages: [String] {
        let available = NSSpellChecker.shared.availableLanguages
        return ["de", "en"].compactMap { prefix in
            available.first { $0 == prefix } ?? available.first { $0.hasPrefix(prefix + "_") }
        }
    }

    private static func isKnown(_ word: String, language: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
    #else
    private static let checker = UITextChecker()

    private static var checkerLanguages: [String] {
        let available = UITextChecker.availableLanguages
        return ["de", "en"].compactMap { prefix in
            available.first { $0 == prefix } ?? available.first { $0.hasPrefix(prefix + "_") || $0.hasPrefix(prefix + "-") }
        }
    }

    private static func isKnown(_ word: String, language: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                             language: language).location == NSNotFound
    }
    #endif
}

import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision
#if os(iOS)
import VisionKit
#endif

/// Reads a receipt on the device: Vision's text recognition, page by page, then
/// `ReceiptParser` for the total, the date and the shop. Nothing leaves the device.
nonisolated enum ReceiptReader {
    /// What the file picker takes: a photo or a PDF of the receipt.
    static let fileTypes: [UTType] = [.image, .pdf]
    /// A long receipt can take a few pages; more aren't read.
    static let maxPages = 5

    /// The receipt's text pieces, per page.
    @concurrent
    static func pieces(of images: [CGImage]) async throws -> [[ReceiptTextPiece]] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Amounts and dates read better without the dictionary.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        var pages: [[ReceiptTextPiece]] = []
        for image in images.prefix(maxPages) {
            let observations = try await request.perform(on: image)
            pages.append(observations.compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                // Vision's origin is at the bottom left.
                let box = observation.boundingBox.cgRect
                return ReceiptTextPiece(text: text, x: box.minX, y: 1 - box.midY, height: box.height)
            })
        }
        return pages
    }

    /// The pages of a picked photo (turned upright) or PDF.
    @concurrent
    static func images(at url: URL) async throws -> [CGImage] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return pdfPages(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4000,
              ] as CFDictionary)
        else { throw ReceiptError.unreadable }
        return [image]
    }

    /// A PDF's first pages, drawn on white about 2000 pixels wide.
    private static func pdfPages(_ url: URL) -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        return (1...max(1, min(document.numberOfPages, maxPages))).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            let scale = 2000 / box.width
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            return context.makeImage()
        }
    }
}

enum ReceiptError: LocalizedError {
    case unreadable

    var errorDescription: String? { String(localized: "The receipt couldn’t be read.") }
}

extension ReceiptParser {
    /// Reads the pages' text (off the main actor), then the receipt's total, date and shop.
    static func scan(_ images: [CGImage], today: Day = .today) async throws -> ReceiptScan {
        let pages = try await ReceiptReader.pieces(of: images)
        // An ambiguous "1/2/2026" is read the way the device writes dates.
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: .current) ?? ""
        let monthFirst = (format.firstIndex(of: "M") ?? format.endIndex) < (format.firstIndex(of: "d") ?? format.endIndex)
        return parse(pages.flatMap(lines), today: today, monthFirst: monthFirst)
    }
}

#if os(iOS)
/// VisionKit's document camera: finds the receipt's edges, straightens it and takes one or more
/// pages. Hands over the pages, or none when cancelled.
struct ReceiptCamera: UIViewControllerRepresentable {
    var done: ([CGImage]) -> Void

    /// Not in the Simulator or on devices without a camera: the file picker then.
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([CGImage]) -> Void

        init(done: @escaping ([CGImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<min(scan.pageCount, ReceiptReader.maxPages)).compactMap { scan.imageOfPage(at: $0).cgImage })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            ErrorBanner.shared.show(error)
            done([])
        }
    }
}
#endif

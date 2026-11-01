import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Reads a receipt on the device: Vision's text recognition, page by page, then
/// `ReceiptParser` for the total, the date and the shop. Nothing leaves the device.
nonisolated enum ReceiptReader {
    /// What the file picker takes: a photo or a PDF of the receipt.
    static let fileTypes: [UTType] = [.image, .pdf]
    /// A long receipt can take a few pages; more aren't read.
    static let maxPages = 5

    /// The receipt's pages with their text (cropped first when picked, not from the camera).
    static func read(_ images: [CGImage], needsCrop: Bool) async throws -> [ScanPage] {
        let images = needsCrop ? await ScanCrop.cropped(Array(images.prefix(maxPages))) : images
        // Amounts and dates read better without the dictionary.
        return try await ScanReader.read(images, maxPages: maxPages, languageCorrection: false)
    }

    /// The pages of a picked photo (turned upright) or PDF.
    @concurrent
    static func images(at url: URL, maxPages: Int = maxPages) async throws -> [CGImage] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return pdfPages(url, maxPages: maxPages)
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
    private static func pdfPages(_ url: URL, maxPages: Int) -> [CGImage] {
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
    /// The receipt's total, date and shop from its read pages.
    static func scan(_ pages: [ScanPage], today: Day = .today) -> ReceiptScan {
        // An ambiguous "1/2/2026" is read the way the device writes dates.
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: .current) ?? ""
        let monthFirst = (format.firstIndex(of: "M") ?? format.endIndex) < (format.firstIndex(of: "d") ?? format.endIndex)
        return parse(pages.flatMap { lines($0.lines.map(\.piece)) }, today: today, monthFirst: monthFirst)
    }
}

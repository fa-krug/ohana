import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// Scanned paper (letters, receipts): the pages' images, cropped to the document where they come
// from a picked photo or PDF (the document camera crops them itself), and the text Vision reads
// on them, line by line with where each line is (for the PDF's invisible text layer).

/// One line of text Vision found on a page, where it is: `box` in the page's unit square with
/// the origin at the bottom left (Vision's and PDF's).
nonisolated struct ScanLine: Sendable, Hashable {
    var text: String
    var box: CGRect

    /// As the receipt reader's piece (origin top left), for putting the lines in reading order.
    var piece: ReceiptTextPiece {
        ReceiptTextPiece(text: text, x: box.minX, y: 1 - box.midY, height: box.height)
    }
}

/// A scanned page and the text on it.
nonisolated struct ScanPage: Sendable {
    let image: CGImage
    var lines: [ScanLine]
}

/// Reads the pages' text on the device with Vision.
nonisolated enum ScanReader {
    /// The pages with their lines of text, at most `maxPages`. `languageCorrection`: the
    /// dictionary helps prose (letters), not amounts and dates (receipts).
    @concurrent
    static func read(_ images: [CGImage], maxPages: Int, languageCorrection: Bool) async throws -> [ScanPage] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        request.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        var pages: [ScanPage] = []
        for image in images.prefix(maxPages) {
            let observations = try await request.perform(on: image)
            pages.append(ScanPage(image: image, lines: observations.compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return ScanLine(text: text, box: observation.boundingBox.cgRect)
            }))
        }
        return pages
    }
}

/// Crops a photographed or picked page to the paper and straightens it, like the document camera
/// does: Vision finds the document (its segmentation, else a rectangle), Core Image corrects the
/// perspective. A page without a document that stands out from its background stays whole.
nonisolated enum ScanCrop {
    /// A document's corners in the image's unit square, origin at the bottom left.
    struct Quad: Sendable, Equatable {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint

        var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

        /// Its share of the image (shoelace formula).
        var area: CGFloat {
            let points = corners
            var sum: CGFloat = 0
            for index in points.indices {
                let a = points[index], b = points[(index + 1) % points.count]
                sum += a.x * b.y - b.x * a.y
            }
            return abs(sum) / 2
        }

        func contains(_ point: CGPoint) -> Bool {
            let points = corners
            var inside = false
            var j = points.count - 1
            for i in points.indices {
                let a = points[i], b = points[j]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
    }

    /// A smaller find is something on the page, not the page.
    static let minArea: CGFloat = 0.2

    /// The pages cropped (each stays as it is where no document is found).
    @concurrent
    static func cropped(_ images: [CGImage]) async -> [CGImage] {
        var result: [CGImage] = []
        for image in images { result.append(await cropped(image)) }
        return result
    }

    @concurrent
    static func cropped(_ image: CGImage) async -> CGImage {
        guard let quad = await detect(image) else { return image }
        return perspectiveCorrected(image, quad: quad) ?? image
    }

    /// The document on the image: Vision's document segmentation, else the largest rectangle;
    /// either only when it is big enough and lighter than what's around it (paper on a table).
    @concurrent
    static func detect(_ image: CGImage) async -> Quad? {
        var candidates: [Quad] = []
        if let document = try? await DetectDocumentSegmentationRequest().perform(on: image) {
            candidates.append(Quad(topLeft: document.topLeft.cgPoint, topRight: document.topRight.cgPoint,
                                   bottomRight: document.bottomRight.cgPoint, bottomLeft: document.bottomLeft.cgPoint))
        }
        var rectangles = DetectRectanglesRequest()
        rectangles.minimumSize = Float(minArea)
        rectangles.minimumConfidence = 0.6
        rectangles.maximumObservations = 3
        rectangles.minimumAspectRatio = 0.2
        rectangles.maximumAspectRatio = 1
        rectangles.quadratureToleranceDegrees = 25
        if let found = try? await rectangles.perform(on: image) {
            candidates += found
                .map { Quad(topLeft: $0.topLeft.cgPoint, topRight: $0.topRight.cgPoint,
                            bottomRight: $0.bottomRight.cgPoint, bottomLeft: $0.bottomLeft.cgPoint) }
                .sorted { $0.area > $1.area }
        }
        return candidates.first { $0.area >= minArea && standsOut($0, in: image) }
    }

    /// Whether the area inside `quad` is clearly lighter than the rest of the image; false when
    /// there's hardly anything outside it (nothing to crop).
    static func standsOut(_ quad: Quad, in image: CGImage) -> Bool {
        let side = 48
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side)
        var inside = (sum: 0.0, count: 0), outside = (sum: 0.0, count: 0)
        for row in 0..<side {
            for column in 0..<side {
                // The bitmap's first row is the image's top.
                let point = CGPoint(x: (Double(column) + 0.5) / Double(side), y: 1 - (Double(row) + 0.5) / Double(side))
                let value = Double(pixels[row * side + column]) / 255
                if quad.contains(point) {
                    inside.sum += value
                    inside.count += 1
                } else {
                    outside.sum += value
                    outside.count += 1
                }
            }
        }
        guard inside.count > 0, outside.count >= side * side / 20 else { return false }
        return inside.sum / Double(inside.count) - outside.sum / Double(outside.count) >= 0.1
    }

    private static let context = CIContext()

    /// The part of `image` inside `quad`, as a straight rectangle.
    static func perspectiveCorrected(_ image: CGImage, quad: Quad) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixel(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * width, y: point.y * height) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = pixel(quad.topLeft)
        filter.topRight = pixel(quad.topRight)
        filter.bottomRight = pixel(quad.bottomRight)
        filter.bottomLeft = pixel(quad.bottomLeft)
        guard let output = filter.outputImage, output.extent.width >= 1, output.extent.height >= 1 else { return nil }
        return context.createCGImage(output, from: output.extent.integral)
    }
}

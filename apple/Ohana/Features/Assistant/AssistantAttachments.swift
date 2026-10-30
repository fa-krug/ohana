import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A file or picture attached to the next message (web: components/assistant/attachments.ts):
/// images are shrunk to a JPEG data URL, text files are read as text. The server passes both on
/// to the assistant.
nonisolated struct AssistantPendingAttachment: Identifiable, Equatable {
    let id = UUID()
    /// image | file
    let kind: String
    let name: String
    /// A JPEG data URL (images).
    var url: String?
    /// The file's text (files).
    var text: String?

    var outgoing: AssistantOutgoingAttachment {
        .init(kind: kind, name: name, url: kind == "image" ? url : nil, text: kind == "file" ? text : nil)
    }
}

nonisolated enum AssistantAttachmentError: LocalizedError {
    case unsupported(String)
    case tooBig(String, Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(name):
            String(localized: "Can’t attach “\(name)”: only images and text files (like .txt, .csv, .json) are supported.")
        case let .tooBig(name, max):
            String(localized: "“\(name)” is too big (max. \(max) MB).")
        case let .unreadable(name):
            String(localized: "Couldn’t read “\(name)”.")
        }
    }
}

nonisolated enum AssistantAttachments {
    static let maxCount = 4
    static let maxImageBytes = 20 * 1024 * 1024
    static let maxTextBytes = 2 * 1024 * 1024
    static let maxTextChars = 50_000
    static let maxSide = 1600
    static let maxURL = 2_000_000

    static let textExtensions = ["txt", "csv", "tsv", "md", "json", "ics", "xml", "html", "log", "yaml", "yml"]

    /// For the file importer.
    static let contentTypes: [UTType] = [.image, .plainText, .commaSeparatedText, .json, .xml, .html, .text]
        + textExtensions.compactMap { UTType(filenameExtension: $0) }

    /// What a file can be attached as, or nil if it can't.
    static func kind(of url: URL) -> String? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .image) == true { return "image" }
        if textExtensions.contains(url.pathExtension.lowercased()) { return "file" }
        if let type, type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .xml) { return "file" }
        return nil
    }

    /// Reads a file the user picked (security-scoped) into an attachment.
    static func read(_ url: URL) throws -> AssistantPendingAttachment {
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        guard let kind = kind(of: url) else { throw AssistantAttachmentError.unsupported(name) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if kind == "image" {
            if size > maxImageBytes { throw AssistantAttachmentError.tooBig(name, 20) }
            guard let data = try? Data(contentsOf: url) else { throw AssistantAttachmentError.unreadable(name) }
            return try image(data, name: name)
        }
        if size > maxTextBytes { throw AssistantAttachmentError.tooBig(name, 2) }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw AssistantAttachmentError.unreadable(name) }
        return AssistantPendingAttachment(kind: "file", name: name, text: cut(text))
    }

    /// Long text is cut (the server takes 50,000 characters of it).
    static func cut(_ text: String) -> String {
        text.count > maxTextChars ? String(text.prefix(maxTextChars)) + "\n…(cut off)" : text
    }

    /// An image (from a file, the photo library or the clipboard) as an attachment.
    static func image(_ data: Data, name: String) throws -> AssistantPendingAttachment {
        if data.count > maxImageBytes { throw AssistantAttachmentError.tooBig(name, 20) }
        guard let url = jpegDataURL(data) else { throw AssistantAttachmentError.unreadable(name) }
        return AssistantPendingAttachment(kind: "image", name: name, url: url)
    }

    /// Downscales an image (long side ≤ 1600 px) onto white and exports it as a JPEG data URL;
    /// still too big for the server, it tries smaller and with lower quality.
    static func jpegDataURL(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var side = maxSide
        var quality = 0.85
        while side >= 400 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let flat = onWhite(thumb) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            let url = "data:image/jpeg;base64," + (out as Data).base64EncodedString()
            if url.count <= maxURL { return url }
            side = Int((Double(side) * 0.75).rounded())
            quality -= 0.1
        }
        return nil
    }

    /// The image drawn onto white (transparency would turn black in a JPEG).
    private static func onWhite(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The image of a data URL, for showing it.
    static func image(dataURL: String) -> Image? {
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = PlatformImage(data: data) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: image)
        #else
        return Image(nsImage: image)
        #endif
    }
}

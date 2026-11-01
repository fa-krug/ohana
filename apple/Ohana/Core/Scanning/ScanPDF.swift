import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Filing a scan (a letter, a receipt): a searchable PDF (the page images with the recognized text
// invisible on top, like a scanner's OCR) under a cleaned-up name, in the folder the user picked
// last (a bookmark, device-wide and shared by letters and receipts), with Finder / Files tags.
// All on the device: nothing of it goes to the server.

/// What kind of paper: "Save as PDF" is remembered for each.
nonisolated enum ScanKind: String, Sendable {
    case letter, receipt

    /// "Save as PDF" the first time: letters are kept, receipts mostly not.
    var savesPDFByDefault: Bool { self == .letter }
}

/// What scanning remembers on this device (UserDefaults, not per family or server).
nonisolated struct ScanFilingSettings: @unchecked Sendable {
    var defaults: UserDefaults = .standard

    static let recentTagsKey = "scanRecentTags"
    static let folderKey = "scanFolderBookmark"
    static let maxRecentTags = 12

    static func savesPDFKey(_ kind: ScanKind) -> String { "scanSavesPDF.\(kind.rawValue)" }

    /// Whether "Save as PDF" is on for `kind`: its last setting.
    func savesPDF(_ kind: ScanKind) -> Bool {
        defaults.object(forKey: Self.savesPDFKey(kind)) as? Bool ?? kind.savesPDFByDefault
    }

    func setSavesPDF(_ on: Bool, for kind: ScanKind) {
        defaults.set(on, forKey: Self.savesPDFKey(kind))
    }

    /// The tags used last, the latest first.
    var recentTags: [String] { defaults.stringArray(forKey: Self.recentTagsKey) ?? [] }

    /// Puts `tags` in front of the recent ones (no duplicates, case ignored), keeping `maxRecentTags`.
    func remember(tags: [String]) {
        var seen = Set<String>()
        let unique = (tags + recentTags).filter { seen.insert($0.lowercased()).inserted }
        defaults.set(Array(unique.prefix(Self.maxRecentTags)), forKey: Self.recentTagsKey)
    }

    // MARK: The folder

    var folderBookmark: Data? {
        get { defaults.data(forKey: Self.folderKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.folderKey) }
    }

    #if os(macOS)
    /// The sandbox lets the app back into the folder after a restart only with a security-scoped
    /// bookmark (entitlement `com.apple.security.files.bookmarks.app-scope`).
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    /// Remembers `url` (a folder from the file picker, security-scoped).
    func rememberFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        folderBookmark = try url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil,
                                              relativeTo: nil)
    }

    /// The remembered folder: `.none` without one, `.missing` when it can't be found or reached
    /// any more (deleted, in the trash, another device's), else the folder (a stale bookmark is
    /// renewed).
    func folder() -> ScanFolder {
        guard let bookmark = folderBookmark else { return .none }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: Self.resolutionOptions, relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return .missing }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ScanFiler.isFolder(url), !url.pathComponents.contains(".Trash") else { return .missing }
        if stale, let renewed = try? url.bookmarkData(options: Self.creationOptions, includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) {
            folderBookmark = renewed
        }
        return .folder(url)
    }
}

/// The folder scans are saved in.
nonisolated enum ScanFolder: Equatable, Sendable {
    case none
    case missing
    case folder(URL)

    var url: URL? {
        if case let .folder(url) = self { url } else { nil }
    }
}

// MARK: - The file

nonisolated enum ScanFileName {
    static let maxLength = 120
    static let fallback = "Scan"

    /// A name that works as a file name everywhere: no "/", ":", "\" and the other characters
    /// Windows and the Files app refuse, no control characters, spaces tidied, no dot in front,
    /// without a ".pdf" the user typed, at most `maxLength` characters; "Scan" when nothing is left.
    static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        clean = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if clean.lowercased().hasSuffix(".pdf") { clean = String(clean.dropLast(4)) }
        let edges = CharacterSet(charactersIn: " .-")
        clean = clean.trimmingCharacters(in: edges)
        if clean.count > maxLength { clean = String(clean.prefix(maxLength)).trimmingCharacters(in: edges) }
        return clean.isEmpty ? fallback : clean
    }

    /// "Name.pdf" in `folder`, or "Name 2.pdf", "Name 3.pdf", … when that is taken.
    static func unique(_ name: String, in folder: URL,
                       exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = sanitized(name)
        var number = 1
        while true {
            let file = folder.appendingPathComponent(number == 1 ? "\(base).pdf" : "\(base) \(number).pdf",
                                                     isDirectory: false)
            if !exists(file) { return file }
            number += 1
        }
    }
}

/// Finder and Files tags: the extended attribute `com.apple.metadata:_kMDItemUserTags`, a binary
/// property list of the tag names.
nonisolated enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    static func encode(_ tags: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
    }

    /// The names in an attribute's value (a tag's colour, "\n6" after its name, left out).
    static func decode(_ data: Data) -> [String] {
        let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
        return list.map { $0.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? $0 }
    }

    /// Sets the file's tags (none: removes the attribute).
    static func write(_ tags: [String], to url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteUnknown) }
            if tags.isEmpty {
                if removexattr(path, attribute, 0) != 0, errno != ENOATTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return
            }
            let data = try encode(tags)
            let result = data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, 0) }
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    static func read(_ url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, 0) }
            return read == size ? decode(data) : []
        }
    }
}

/// Writes the PDF into the folder.
nonisolated enum ScanFiler {
    /// Saves `data` as `name`.pdf in `folder` (a free name: `ScanFileName.unique`) with `tags`; the
    /// folder's security scope is taken around the write. Returns the file.
    static func save(_ data: Data, name: String, tags: [String], in folder: URL) throws -> URL {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard isFolder(folder) else { throw ScanFilingError.folderMissing }
        let file = ScanFileName.unique(name, in: folder)
        // Coordinated: the folder may be a file provider's (iCloud Drive, a cloud service).
        var coordination: NSError?
        var failure: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordination) { url in
            do {
                try data.write(to: url, options: [.withoutOverwriting])
                // Tags that don't stick aren't worth losing the PDF over.
                try? FinderTags.write(tags, to: url)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
        return file
    }

    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

nonisolated enum ScanFilingError: LocalizedError {
    case noFolder
    case folderMissing

    var errorDescription: String? {
        switch self {
        case .noFolder: String(localized: "Choose a folder for the PDF first.")
        case .folderMissing: String(localized: "The folder can’t be found any more. Choose it again.")
        }
    }
}

// MARK: - The PDF

/// A searchable PDF of the scanned pages: each page the size of its image scaled to A4's long
/// side (842 pt), the image recompressed as JPEG (about 200 dpi), and the recognized lines drawn
/// invisibly where they are on the page, so Spotlight, Files, Finder and Preview find and select
/// the text.
nonisolated enum ScanPDF {
    /// A4's long side in points.
    static let pageLongSide: CGFloat = 842
    /// About 200 dpi on A4.
    static let maxPixels = 2339
    static let jpegQuality = 0.7

    static func make(pages: [ScanPage], title: String, tags: [String]) -> Data {
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "Ohana"]
        if !title.isEmpty { info[kCGPDFContextTitle] = title }
        if !tags.isEmpty { info[kCGPDFContextKeywords] = tags as CFArray }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary)
        else { return Data() }
        for page in pages {
            let width = CGFloat(page.image.width), height = CGFloat(page.image.height)
            guard width > 0, height > 0 else { continue }
            let scale = pageLongSide / max(width, height)
            var box = CGRect(x: 0, y: 0, width: (width * scale).rounded(), height: (height * scale).rounded())
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.draw(compressed(page.image), in: box)
            drawText(page.lines, in: box, context: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The lines as invisible text, each fitted to its box.
    private static func drawText(_ lines: [ScanLine], in page: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let box = CGRect(x: page.minX + line.box.minX * page.width, y: page.minY + line.box.minY * page.height,
                             width: line.box.width * page.width, height: line.box.height * page.height)
            guard !text.isEmpty, box.width > 1, box.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.8, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + CTFontGetDescent(font))
            context.scaleBy(x: box.width / width, y: 1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// The page image at most `maxPixels` on its long side, as JPEG (kept as JPEG in the PDF):
    /// a few hundred KB a page instead of several MB.
    static func compressed(_ image: CGImage) -> CGImage {
        let longSide = max(image.width, image.height)
        var source = image
        if longSide > maxPixels {
            let scale = CGFloat(maxPixels) / CGFloat(longSide)
            let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let scaled = context.makeImage() { source = scaled }
            }
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            return source
        }
        CGImageDestinationAddImage(destination, source,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let decoded = CGImageSourceCreateWithData(jpeg, nil),
              let result = CGImageSourceCreateImageAtIndex(decoded, 0, nil)
        else { return source }
        return result
    }
}

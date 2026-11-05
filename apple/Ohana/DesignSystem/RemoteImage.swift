import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// An image from the Ohana server (recipe photos, member photos under /api/images/…), fetched
/// with the device's token: `AsyncImage` can't send one. Decoded off the main thread at most
/// `maxPixelSize` on its long side, kept in memory for the session and its file on the device
/// (`RemoteImageStore`: the paths name a version, so a kept file never goes stale). One already
/// in memory shows at once, without its placeholder first.
struct RemoteImage<Placeholder: View>: View {
    @Environment(AppModel.self) private var app
    let path: String?
    var contentMode: ContentMode = .fill
    var maxPixelSize: Int = RemoteImageStore.fullSize
    @ViewBuilder var placeholder: Placeholder
    @State private var loaded: (key: String, image: CGImage)?

    var body: some View {
        let key = key
        let image = key.flatMap { key in loaded?.key == key ? loaded?.image : RemoteImageStore.memory(key) }
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: key) { await load(key) }
    }

    private var key: String? {
        guard let path, let client = app.client else { return nil }
        return RemoteImageStore.key(client.baseURL, path, maxPixelSize)
    }

    private func load(_ key: String?) async {
        guard let key, let path, let client = app.client else { loaded = nil; return }
        if let image = RemoteImageStore.memory(key) { loaded = (key, image); return }
        let file = client.cache.map { RemoteImageStore.file($0, path: path) }
        if let file, let image = await RemoteImageStore.decode(file: file, maxPixelSize: maxPixelSize) {
            RemoteImageStore.remember(image, key)
            loaded = (key, image.cgImage)
            return
        }
        guard let (data, _) = try? await client.data(for: client.request(.get, path)),
              let image = await RemoteImageStore.decode(data, keepingAt: file, maxPixelSize: maxPixelSize),
              !Task.isCancelled else { return }
        RemoteImageStore.remember(image, key)
        loaded = (key, image.cgImage)
    }
}

extension RemoteImage where Placeholder == Color {
    init(path: String?, contentMode: ContentMode = .fill, maxPixelSize: Int = RemoteImageStore.fullSize) {
        self.init(path: path, contentMode: contentMode, maxPixelSize: maxPixelSize) { Color.secondary.opacity(0.12) }
    }
}

/// Where `RemoteImage` keeps what it loaded: the decoded images in memory, the files under the
/// server's `ResponseCache` folder (`images/`, cleared with it on sign out and a new pairing).
nonisolated enum RemoteImageStore {
    /// The server's photos are at most 1024 px (recipes; members' 512).
    static let fullSize = 1024

    /// A decoded image, handed from the decoding thread to the view.
    struct Decoded: @unchecked Sendable {
        let cgImage: CGImage
    }

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private nonisolated(unsafe) static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        // About 300 MB of decoded pixels at most.
        cache.totalCostLimit = 300 << 20
        return cache
    }()

    static func key(_ server: URL, _ path: String, _ size: Int) -> String {
        "\(server.absoluteString)|\(path)|\(size)"
    }

    static func memory(_ key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    static func remember(_ image: Decoded, _ key: String) {
        let image = image.cgImage
        cache.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    static func file(_ cache: ResponseCache, path: String) -> URL {
        let name = String(path.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
        return cache.directory.appending(path: "images/\(name)")
    }

    /// The kept file, decoded; nil without one.
    @concurrent
    static func decode(file: URL, maxPixelSize: Int) async -> Decoded? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return decoded(data, maxPixelSize: maxPixelSize)
    }

    /// A loaded image, decoded, and its file kept at `file` when it decodes.
    @concurrent
    static func decode(_ data: Data, keepingAt file: URL?, maxPixelSize: Int) async -> Decoded? {
        guard let image = decoded(data, maxPixelSize: maxPixelSize) else { return nil }
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return image
    }

    /// Decoded now (not when first drawn, on the main thread), upright, at most `maxPixelSize`.
    private static func decoded(_ data: Data, maxPixelSize: Int) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Decoded.init)
    }
}

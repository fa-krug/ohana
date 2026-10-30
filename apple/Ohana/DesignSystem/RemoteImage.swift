import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// An image from the Ohana server (recipe photos under /api/images/…), fetched with the device's
/// token: `AsyncImage` can't send one. Cached in memory for the session.
struct RemoteImage<Placeholder: View>: View {
    @Environment(AppModel.self) private var app
    let path: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: Placeholder
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                #else
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else {
                placeholder
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let path, let client = app.client else { image = nil; return }
        let key = client.url(path).absoluteString as NSString
        if let cached = ImageCache.shared.object(forKey: key) { image = cached; return }
        guard let (data, _) = try? await client.data(for: client.request(.get, path)),
              let loaded = PlatformImage(data: data) else { return }
        ImageCache.shared.setObject(loaded, forKey: key)
        image = loaded
    }
}

extension RemoteImage where Placeholder == Color {
    init(path: String?, contentMode: ContentMode = .fill) {
        self.init(path: path, contentMode: contentMode) { Color.secondary.opacity(0.12) }
    }
}

enum ImageCache {
    static let shared: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 200
        return cache
    }()
}

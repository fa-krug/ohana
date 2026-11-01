import Foundation
import UniformTypeIdentifiers

/// What the share sheet hands the extension: the page's address, and on iOS what
/// `Preprocess.js` read in Safari (title, text, og:image). Other apps share just a URL.
nonisolated struct SharedPage: Equatable, Sendable {
    var url: URL?
    var title: String?
    var text: String?
    var imageUrl: String?

    /// The key Safari puts the preprocessing script's result under.
    static let resultsKey = "NSExtensionJavaScriptPreprocessingResultsKey"

    /// The script's result (`{url, title, text, imageUrl}`).
    init(preprocessingResults results: [String: Any]) {
        url = (results["url"] as? String).flatMap(Self.webURL)
        title = Self.nonEmpty(results["title"] as? String)
        text = Self.nonEmpty(results["text"] as? String)
        imageUrl = Self.nonEmpty(results["imageUrl"] as? String)
    }

    init(url: URL? = nil, title: String? = nil, text: String? = nil, imageUrl: String? = nil) {
        self.url = url
        self.title = title
        self.text = text
        self.imageUrl = imageUrl
    }

    /// Only http(s) pages can be imported.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Reads the shared items: Safari's preprocessing result first, else a URL attachment; the
    /// item's text (Safari on the Mac puts the page title there) as the title.
    static func read(_ items: [NSExtensionItem]) async -> SharedPage {
        var page = SharedPage()
        for item in items {
            if page.title == nil {
                page.title = nonEmpty(item.attributedContentText?.string) ?? nonEmpty(item.attributedTitle?.string)
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let found = await load(provider, type: UTType.propertyList.identifier) {
                    return found.merging(page)
                }
                if page.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    page.url = await load(provider, type: UTType.url.identifier)?.url
                }
            }
        }
        return page
    }

    /// This page, with what it lacks taken from `other`.
    func merging(_ other: SharedPage) -> SharedPage {
        SharedPage(url: url ?? other.url, title: title ?? other.title, text: text ?? other.text,
                   imageUrl: imageUrl ?? other.imageUrl)
    }

    private static func load(_ provider: NSItemProvider, type: String) async -> SharedPage? {
        await withCheckedContinuation { continuation in
            // @Sendable: the provider calls back on a queue of its own, not the main actor.
            provider.loadItem(forTypeIdentifier: type, options: nil) { @Sendable item, _ in
                continuation.resume(returning: page(from: item))
            }
        }
    }

    private static func page(from item: (any NSSecureCoding)?) -> SharedPage? {
        if let dictionary = item as? NSDictionary,
           let results = dictionary[resultsKey] as? [String: Any] {
            return SharedPage(preprocessingResults: results)
        }
        if let url = item as? URL {
            return SharedPage(url: webURL(url.absoluteString))
        }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return SharedPage(url: webURL(url.absoluteString))
        }
        if let text = item as? String {
            return SharedPage(url: webURL(text))
        }
        return nil
    }
}

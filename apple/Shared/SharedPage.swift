import Foundation
import UniformTypeIdentifiers

/// What the share sheet hands the extension: the page's address, and on iOS what
/// `Preprocess.js` read in Safari (title, text, og:image, the recipe of its JSON-LD). Other apps
/// share just a URL.
nonisolated struct SharedPage: Equatable, Sendable {
    var url: URL?
    var title: String?
    var text: String?
    var imageUrl: String?
    /// Whether the page's JSON-LD describes a schema.org Recipe; nil when the page wasn't read
    /// (no usable preprocessing result: the server is asked instead).
    var recipe: Bool?
    var recipeName: String?
    var recipeImage: String?
    /// Safari handed over a preprocessing result at all, even one without a page (its crashed
    /// or blank tab's placeholder).
    var preprocessed = false

    /// The key Safari puts the preprocessing script's result under.
    static let resultsKey = "NSExtensionJavaScriptPreprocessingResultsKey"

    /// The script's result (`{url, title, text, imageUrl, recipe, recipeName, recipeImage}`).
    init(preprocessingResults results: [String: Any]) {
        url = (results["url"] as? String).flatMap(Self.webURL)
        title = Self.nonEmpty(results["title"] as? String)
        text = Self.nonEmpty(results["text"] as? String)
        imageUrl = Self.nonEmpty(results["imageUrl"] as? String)
        recipe = results["recipe"] as? Bool
        recipeName = Self.nonEmpty(results["recipeName"] as? String)
        recipeImage = Self.nonEmpty(results["recipeImage"] as? String)
        preprocessed = true
    }

    init(url: URL? = nil, title: String? = nil, text: String? = nil, imageUrl: String? = nil,
         recipe: Bool? = nil, recipeName: String? = nil, recipeImage: String? = nil, preprocessed: Bool = false) {
        self.url = url
        self.title = title
        self.text = text
        self.imageUrl = imageUrl
        self.recipe = recipe
        self.recipeName = recipeName
        self.recipeImage = recipeImage
        self.preprocessed = preprocessed
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

    /// Reads every shared item: Safari's preprocessing result, a URL attachment (or a text that is
    /// one), and the item's text (Safari on the Mac puts the page title there), then `combine`s
    /// them.
    static func read(_ items: [NSExtensionItem]) async -> SharedPage {
        var result: SharedPage?
        var attachmentURL: URL?
        var itemTitle: String?
        for item in items {
            if itemTitle == nil {
                itemTitle = nonEmpty(item.attributedContentText?.string) ?? nonEmpty(item.attributedTitle?.string)
            }
            for provider in item.attachments ?? [] {
                if result == nil, provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let found = await load(provider, type: UTType.propertyList.identifier), found.preprocessed {
                    result = found
                }
                for type in [UTType.url, UTType.plainText] where attachmentURL == nil {
                    if provider.hasItemConformingToTypeIdentifier(type.identifier),
                       let found = await load(provider, type: type.identifier), !found.preprocessed {
                        attachmentURL = found.url
                    }
                }
            }
        }
        return combine(result: result, attachmentURL: attachmentURL, itemTitle: itemTitle)
    }

    /// The shared page from what the items held. A preprocessing result is only the page when it
    /// has its own http(s) address; one without is Safari's placeholder for a crashed or blank
    /// tab, so its title, text and recipe are dropped (as is the item's title when it is the
    /// placeholder's) and the URL attachment is the page.
    static func combine(result: SharedPage?, attachmentURL: URL?, itemTitle: String?) -> SharedPage {
        if var result, result.url != nil {
            result.title = result.title ?? itemTitle
            return result
        }
        let title = itemTitle == result?.title ? nil : itemTitle
        return SharedPage(url: attachmentURL, title: title, preprocessed: result != nil)
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

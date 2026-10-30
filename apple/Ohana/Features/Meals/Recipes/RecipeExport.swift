import CoreGraphics
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Sharing a recipe (the web's export-recipe-dialog.tsx and lib/meals/recipes/export.ts): as
// Markdown text or as an A4 PDF (title, photo, description, servings and times, ingredients,
// steps), for any number of portions and with the parts chosen.

/// The recipe laid out on A4 pages (export.ts generatePdf): lines of text and the photo, each
/// with its frame in points from the page's top left. Text wraps to the content width; a block
/// that doesn't fit the rest of a page continues on the next.
struct RecipePDFLayout {
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    /// 15 mm.
    static let margin: CGFloat = 42.52
    /// The photo is at most 100 mm high.
    static let maxImageHeight: CGFloat = 283.46

    enum Content {
        case text(NSAttributedString)
        case image(CGImage)
    }

    struct Item {
        let content: Content
        /// From the page's top left; a line's frame spans its line height, the baseline at
        /// `frame.minY + ascent`.
        let frame: CGRect
        var ascent: CGFloat = 0

        var text: String? {
            if case let .text(string) = content { string.string } else { nil }
        }
    }

    struct Page {
        var items: [Item] = []
    }

    private(set) var pages: [Page] = [Page()]
    private var y = margin

    static var contentWidth: CGFloat { pageSize.width - 2 * margin }

    /// The pages of `recipe` for `portions`.
    init(recipe: RecipeResolved, portions: Int, sections: RecipeExportSections, image: CGImage?,
         german: Bool = RecipeLocale.isGerman) {
        let labels = RecipeResolved.ExportLabels(german: german)
        let detail = recipe.detail
        let title = Self.font(20, bold: true), heading = Self.font(14, bold: true)
        let body = Self.font(10), small = Self.font(9)
        let gray = CGColor(gray: 0.4, alpha: 1)

        paragraph(detail.title, font: title, spacingAfter: 12)
        if sections.image, let image {
            place(image)
        }
        if sections.description, !detail.description.isEmpty {
            paragraph(detail.description, font: body, spacingAfter: 11)
        }
        paragraph(recipe.exportMeta(portions: portions, german: german), font: small, color: gray, spacingAfter: 12)

        let ingredients = recipe.exportIngredients("• ", portions: portions, german: german)
        if sections.ingredients, !ingredients.isEmpty {
            paragraph(labels.ingredients, font: heading, spacingBefore: 4, spacingAfter: 6, keepWithNext: true)
            for line in ingredients { paragraph(line, font: body, indent: 6) }
            y += 11
        }
        if sections.steps {
            for (method, label) in [(RecipeCookMethod.manual, labels.steps), (.machine, labels.machine)] {
                let steps = recipe.exportSteps(method, prefix: "– ", portions: portions, german: german)
                guard !steps.isEmpty else { continue }
                paragraph(label, font: heading, spacingBefore: 4, spacingAfter: 6, keepWithNext: true)
                for (i, step) in steps.enumerated() {
                    paragraph("\(i + 1). \(step.instruction)", font: body, indent: 6, spacingAfter: 4)
                    for line in step.ingredients {
                        paragraph(line, font: small, color: gray, indent: 18)
                    }
                    if !step.ingredients.isEmpty { y += 3 }
                }
                y += 11
            }
        }
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    // MARK: Placing

    private var bottom: CGFloat { Self.pageSize.height - Self.margin }

    private mutating func newPage() {
        pages.append(Page())
        y = Self.margin
    }

    private mutating func place(_ image: CGImage) {
        let width = Self.contentWidth
        let natural = image.width > 0 ? CGFloat(image.height) / CGFloat(image.width) * width : 170
        let height = min(natural, Self.maxImageHeight)
        if y + height > bottom { newPage() }
        pages[pages.count - 1].items.append(Item(content: .image(image), frame: CGRect(x: Self.margin, y: y, width: width, height: height)))
        y += height + 17
    }

    /// Wraps `text` into lines and places them; with `keepWithNext` (a heading) a new page
    /// starts unless the heading and two more lines fit.
    private mutating func paragraph(_ text: String, font: CTFont, color: CGColor = CGColor(gray: 0, alpha: 1),
                                    indent: CGFloat = 0, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 2,
                                    keepWithNext: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let string = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attributes)
        let lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * 1.15
        let width = Self.contentWidth - indent
        let lines = Self.wrap(string, width: width)
        y += spacingBefore
        if keepWithNext, y + lineHeight * 3 > bottom { newPage() }
        for line in lines {
            if y + lineHeight > bottom { newPage() }
            pages[pages.count - 1].items.append(Item(content: .text(line),
                                                     frame: CGRect(x: Self.margin + indent, y: y, width: width, height: lineHeight),
                                                     ascent: CTFontGetAscent(font)))
            y += lineHeight
        }
        y += spacingAfter
    }

    /// The lines `string` breaks into at `width` (hard line breaks kept).
    static func wrap(_ string: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = string.length
        var start = 0
        var lines: [NSAttributedString] = []
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            var line = string.attributedSubstring(from: NSRange(location: start, length: min(count, length - start)))
            if line.string.hasSuffix("\n") {
                line = line.attributedSubstring(from: NSRange(location: 0, length: line.length - 1))
            }
            lines.append(line)
            start += count
        }
        return lines
    }

    // MARK: Drawing

    /// The pages as a PDF document.
    func render(title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Ohana"] as CFDictionary)
        else { return Data() }
        let height = Self.pageSize.height
        for page in pages {
            context.beginPDFPage(nil)
            for item in page.items {
                switch item.content {
                case let .text(string):
                    let line = CTLineCreateWithAttributedString(string)
                    context.textMatrix = .identity
                    context.textPosition = CGPoint(x: item.frame.minX, y: height - item.frame.minY - item.ascent)
                    CTLineDraw(line, context)
                case let .image(image):
                    let rect = CGRect(x: item.frame.minX, y: height - item.frame.maxY,
                                      width: item.frame.width, height: item.frame.height)
                    context.saveGState()
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                    context.clip()
                    // Fills the frame, cropping what doesn't fit.
                    let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                    context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                   width: size.width, height: size.height))
                    context.restoreGState()
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

enum RecipeExportFile {
    /// "tomato-soup" (export.ts slugify); "recipe" when nothing is left.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        for ch in folded {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "recipe" : trimmed
    }

    /// Writes `data` to a temporary file named after the recipe, for sharing.
    static func write(_ data: Data, title: String, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Recipes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(slug(title)).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// A finished export for "Save…".
struct RecipeExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf, .plainText]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The share dialog of a recipe: Text (Markdown) or PDF, how many portions, which parts; copy
/// the text, share or save the file.
struct RecipeExportSheet: View {
    let recipe: RecipeResolved

    enum Format: String, CaseIterable, Identifiable {
        case markdown, pdf
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .markdown ? "Text" : "PDF" }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("meals.export.format") private var format: Format = .markdown
    @State private var portions: Int
    @State private var sections = RecipeExportSections.all
    @State private var photo: CGImage?
    @State private var file: URL?
    @State private var pdf: Data?
    @State private var saving = false

    init(recipe: RecipeResolved, portions: Int) {
        self.recipe = recipe
        _portions = State(initialValue: portions)
    }

    private struct Options: Hashable {
        let format: Format
        let portions: Int
        let sections: RecipeExportSections
        let hasPhoto: Bool
    }

    private var markdown: String { recipe.markdown(portions: portions, sections: sections) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $portions, in: 1...100) {
                        LabeledContent("Portions", value: "\(portions)")
                    }
                }
                Section("What to include") {
                    if recipe.detail.imagePath != nil, format == .pdf {
                        Toggle("Photo", isOn: $sections.image)
                    }
                    Toggle("Description", isOn: $sections.description)
                        .disabled(recipe.detail.description.isEmpty)
                    Toggle("Ingredients", isOn: $sections.ingredients)
                    Toggle("Steps", isOn: $sections.steps)
                }
                Section {
                    if format == .markdown {
                        Text(markdown)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let pdf {
                        LabeledContent("PDF", value: ByteCountFormatter.string(fromByteCount: Int64(pdf.count), countStyle: .file))
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    Text("Preview")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share Recipe")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", role: .close) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if format == .markdown {
                        Button("Copy", systemImage: "doc.on.doc") { copy() }
                    }
                    Button("Save…", systemImage: "square.and.arrow.down") { saving = true }
                        .disabled(format == .pdf && pdf == nil)
                    if let file {
                        ShareLink(item: file, subject: Text(recipe.detail.title)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .fileExporter(isPresented: $saving, document: RecipeExportDocument(data: exportData),
                          contentType: format == .pdf ? .pdf : .plainText,
                          defaultFilename: "\(RecipeExportFile.slug(recipe.detail.title)).\(format == .pdf ? "pdf" : "md")") { result in
                if case let .failure(error) = result { ErrorBanner.shared.show(error) }
            }
        }
        .task { await loadPhoto() }
        .task(id: Options(format: format, portions: portions, sections: sections, hasPhoto: photo != nil)) { build() }
        .errorBanner()
        .presentationDetents([.large])
        .recipeSheetFrame(minWidth: 520, minHeight: 600)
    }

    private var exportData: Data {
        format == .pdf ? (pdf ?? Data()) : Data(markdown.utf8)
    }

    private func loadPhoto() async {
        guard let path = recipe.detail.imagePath, let client = app.client,
              let (data, _) = try? await client.data(for: client.request(.get, path)) else { return }
        photo = RecipeExportFile.cgImage(data)
    }

    /// The file to share for the current options.
    private func build() {
        do {
            if format == .pdf {
                let layout = RecipePDFLayout(recipe: recipe, portions: portions, sections: sections, image: photo)
                let data = layout.render(title: recipe.detail.title)
                pdf = data
                file = try RecipeExportFile.write(data, title: recipe.detail.title, ext: "pdf")
            } else {
                file = try RecipeExportFile.write(Data(markdown.utf8), title: recipe.detail.title, ext: "md")
            }
        } catch {
            file = nil
            ErrorBanner.shared.show(String(localized: "Couldn’t share the recipe. Try again?"))
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = markdown
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        #endif
        ErrorBanner.shared.success(String(localized: "Copied to clipboard."))
    }
}

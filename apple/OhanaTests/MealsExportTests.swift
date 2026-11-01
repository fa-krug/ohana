import CoreGraphics
import Foundation
import Testing
@testable import Ohana

/// Sharing a recipe: the Markdown's sections, the PDF's pages (export.ts generatePdf), file
/// names, and the plural strings of the meals screens.
struct MealsExportTests {
    static func soup() throws -> RecipeResolved {
        RecipeResolved(try MealsRecipeDecodingTests.detail())
    }

    /// A recipe with `steps` long manual steps.
    static func long(steps: Int) throws -> RecipeResolved {
        let instruction = String(repeating: "Stir the pot slowly and keep an eye on the heat. ", count: 6)
        var root = try #require(try JSONSerialization.jsonObject(with: Data(MealsRecipeDecodingTests.detailJSON.utf8)) as? [String: Any])
        var recipe = try #require(root["recipe"] as? [String: Any])
        recipe["manualSteps"] = (1...steps).map { n -> [String: Any] in
            ["id": 100 + n, "method": "MANUAL", "stepNumber": n, "instruction": instruction, "programType": "",
             "temperature": NSNull(), "durationSeconds": NSNull(), "speed": NSNull(), "turbo": false, "direction": "",
             "weightGrams": NSNull(), "ingredients": [["recipeIngredientId": 11, "quantity": "10"]]]
        }
        root["recipe"] = recipe
        let response = try APIClient.decoder.decode(RecipeDetailResponse.self,
                                                    from: JSONSerialization.data(withJSONObject: root))
        try #require(response.recipe.manualSteps.count == steps)
        return RecipeResolved(response)
    }

    static func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func leavesOutTheSectionsNotWanted() throws {
        let recipe = try Self.soup()
        var sections = RecipeExportSections.all
        sections.description = false
        sections.steps = false
        let text = recipe.markdown(portions: 2, sections: sections, german: false)
        #expect(text == """
        # Tomato soup

        2 Servings · Prep: 10 min

        ## Ingredients

        - 400 g Tomato
        - 2 pc Basil

        """)
        sections.ingredients = false
        #expect(!recipe.markdown(portions: 2, sections: sections, german: false).contains("Ingredients"))
        // German labels and names.
        let german = recipe.markdown(portions: 1, german: true)
        #expect(german.contains("1 Portionen · Vorbereitung: 10 min"))
        #expect(german.contains("## Zutaten"))
        #expect(german.contains("- 200 g Tomate"))
        #expect(german.contains("## Maschinenschritte"))
    }

    @Test func laysOutTheRecipeOnAPage() throws {
        let layout = RecipePDFLayout(recipe: try Self.soup(), portions: 4, sections: .all,
                                     image: try Self.image(width: 400, height: 150), german: false)
        #expect(layout.pages.count == 1)
        let items = layout.pages[0].items
        #expect(items.first?.text == "Tomato soup")
        // The photo follows the title over the content width, at its aspect ratio.
        guard case .image = items[1].content else { Issue.record("no photo"); return }
        #expect(abs(items[1].frame.width - RecipePDFLayout.contentWidth) < 0.01)
        #expect(abs(items[1].frame.height - RecipePDFLayout.contentWidth * 0.375) < 0.01)
        let texts = items.compactMap(\.text)
        #expect(texts.contains("4 Servings · Prep: 10 min"))
        #expect(texts.contains("• 800 g Tomato"))
        #expect(texts.contains("1. Chop"))
        #expect(texts.contains("– 800 g Tomato"))
        #expect(texts.contains("Machine Steps"))
        // Everything stays within the margins.
        for item in items {
            #expect(item.frame.minX >= RecipePDFLayout.margin)
            #expect(item.frame.maxY <= RecipePDFLayout.pageSize.height - RecipePDFLayout.margin + 0.01)
        }
    }

    @Test func capsATallPhotoAndSkipsItWhenNotWanted() throws {
        let tall = try Self.image(width: 300, height: 1200)
        let layout = RecipePDFLayout(recipe: try Self.soup(), portions: 2, sections: .all, image: tall, german: false)
        #expect(layout.pages[0].items[1].frame.height == RecipePDFLayout.maxImageHeight)
        var sections = RecipeExportSections.all
        sections.image = false
        let without = RecipePDFLayout(recipe: try Self.soup(), portions: 2, sections: sections, image: tall, german: false)
        #expect(without.pages[0].items.allSatisfy { $0.text != nil })
    }

    @Test func continuesALongRecipeOnMorePages() throws {
        let recipe = try Self.long(steps: 40)
        let layout = RecipePDFLayout(recipe: recipe, portions: 2, sections: .all, image: nil, german: false)
        #expect(layout.pages.count > 2)
        // Long instructions wrap into several lines, none wider than the page allows.
        let lines = layout.pages.flatMap(\.items)
        #expect(lines.filter { $0.text?.hasPrefix("1. Stir") == true }.count == 1)
        #expect(lines.count > 40 * 3)
        for page in layout.pages {
            #expect(!page.items.isEmpty)
            for item in page.items {
                #expect(item.frame.maxY <= RecipePDFLayout.pageSize.height - RecipePDFLayout.margin + 0.01)
                #expect(item.frame.minY >= RecipePDFLayout.margin - 0.01)
            }
        }
        // Lines on a page go down.
        for page in layout.pages {
            let ys = page.items.map(\.frame.minY)
            #expect(ys == ys.sorted())
        }
    }

    @Test func rendersAPDFWithItsPages() throws {
        let layout = RecipePDFLayout(recipe: try Self.long(steps: 40), portions: 2, sections: .all,
                                     image: try Self.image(width: 40, height: 30), german: false)
        let data = layout.render(title: "Tomato soup")
        #expect(data.starts(with: Data("%PDF".utf8)))
        let provider = try #require(CGDataProvider(data: data as CFData))
        let document = try #require(CGPDFDocument(provider))
        #expect(document.numberOfPages == layout.pages.count)
        let box = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(abs(box.width - 595.28) < 0.01)    }

    @Test func namesTheFiles() {
        #expect(RecipeExportFile.slug("Tomato soup") == "tomato-soup")
        #expect(RecipeExportFile.slug("  Crème brûlée (fast!) ") == "creme-brulee-fast")
        #expect(RecipeExportFile.slug("!!!") == "recipe")
    }

    @Test func pluralizesTheMealsStrings() {
        #expect(String(localized: "\(1) servings") == "1 serving")
        #expect(String(localized: "\(3) servings") == "3 servings")
        #expect(String(localized: "\(1) recipes") == "1 recipe")
        #expect(String(localized: "Save \(1) recipes") == "Save 1 recipe")
        #expect(String(localized: "\(2) ingredients") == "2 ingredients")
        #expect(String(localized: "\(1) ingredients") == "1 ingredient")
    }
}

import CoreSpotlight
import Foundation
import Testing
@testable import Ohana

/// Recipes in Spotlight (`RecipeSpotlight`): identifiers, the link a result opens, attributes.
struct RecipeSpotlightTests {
    @Test func identifiersRoundTrip() throws {
        let id = RecipeSpotlightID.make(familyID: "fam1", recipeID: "rec9")
        #expect(id == "recipe/fam1/rec9")
        let parsed = try #require(RecipeSpotlightID.parse(id))
        #expect(parsed.familyID == "fam1" && parsed.recipeID == "rec9")
        #expect(RecipeSpotlightID.domain(familyID: "fam1") == "recipes/fam1")
    }

    @Test func refusesOtherIdentifiers() {
        #expect(RecipeSpotlightID.parse("recipe/fam1") == nil)
        #expect(RecipeSpotlightID.parse("recipe//rec9") == nil)
        #expect(RecipeSpotlightID.parse("event/fam1/rec9") == nil)
        #expect(RecipeSpotlightID.parse("recipe/fam1/rec9/extra") == nil)
        #expect(RecipeSpotlightID.url(for: "nonsense") == nil)
    }

    @Test func aResultOpensTheRecipeInItsFamily() throws {
        let url = try #require(RecipeSpotlightID.url(for: "recipe/fam1/rec9"))
        #expect(url.absoluteString == "ohana://f/fam1/meals/recipes/rec9")
        // The app's own link mapping takes it to the recipe of that family.
        let path = "/" + (url.host() ?? "") + url.path(percentEncoded: false)
        let parsed = try #require(AppRoute.parse(webPath: path))
        #expect(parsed.familyID == "fam1")
        #expect(parsed.route == .recipe(id: "rec9"))
    }

    @Test func entryOfARecipe() {
        let tags = [RecipeTag(id: "t1", category: "CUISINE", nameEn: "Italian", nameDe: "Italienisch"),
                    RecipeTag(id: "t2", category: "DIETARY", nameEn: "Vegan", nameDe: "Vegan")]
        let recipe = RecipeSummary(id: "rec9", title: "Risotto", description: "Creamy and slow.", listType: "KNOWN",
                                   defaultServings: 2, prepTimeMinutes: 10, cookTimeMinutes: 30, leftoverDays: nil,
                                   image: "", createdAt: "", updatedAt: "", tags: tags)
        let entry = RecipeSpotlightEntry(recipe: recipe, familyID: "fam1", familyName: "Krug")
        #expect(entry.identifier == "recipe/fam1/rec9")
        #expect(entry.domain == "recipes/fam1")
        // Both languages' tag names, once each, and the family.
        #expect(entry.keywords == ["Italian", "Italienisch", "Vegan", "Krug"])

        let attributes = entry.attributes
        #expect(attributes.title == "Risotto")
        #expect(attributes.contentDescription == "Creamy and slow.")
        #expect(attributes.keywords == ["Italian", "Italienisch", "Vegan", "Krug"])

        let item = entry.item
        #expect(item.uniqueIdentifier == "recipe/fam1/rec9")
        #expect(item.domainIdentifier == "recipes/fam1")
    }

    @Test func withoutADescriptionTheTagsDescribeIt() {
        let entry = RecipeSpotlightEntry(familyID: "f", recipeID: "r", title: "Soup", description: "  ",
                                         keywords: ["Vegan", "Krug"])
        #expect(entry.attributes.contentDescription == "Vegan, Krug")
        let bare = RecipeSpotlightEntry(familyID: "f", recipeID: "r", title: "Soup", description: "", keywords: [])
        #expect(bare.attributes.contentDescription == nil)
    }
}

/// The import sheet's web address (`RecipeImportURL`).
struct RecipeImportURLTests {
    @Test func acceptsWebAddresses() {
        #expect(RecipeImportURL.parse("https://example.com/recipe/1")?.absoluteString == "https://example.com/recipe/1")
        #expect(RecipeImportURL.parse("  http://example.com/a?b=c \n")?.absoluteString == "http://example.com/a?b=c")
        // Without a scheme: https, when it looks like a domain.
        #expect(RecipeImportURL.parse("chefkoch.de/rezepte/123")?.absoluteString == "https://chefkoch.de/rezepte/123")
    }

    @Test func refusesEverythingElse() {
        #expect(RecipeImportURL.parse("") == nil)
        #expect(RecipeImportURL.parse("lasagne") == nil)
        #expect(RecipeImportURL.parse("ftp://example.com/x") == nil)
        #expect(RecipeImportURL.parse("file:///etc/passwd") == nil)
        #expect(RecipeImportURL.parse("javascript:alert(1)") == nil)
        #expect(RecipeImportURL.parse("https://") == nil)
        #expect(RecipeImportURL.parse("two words.com") == nil)
    }

    @Test func findsTheLinkInPastedText() {
        #expect(RecipeImportURL.firstWebURL(in: "https://example.com/r")?.absoluteString == "https://example.com/r")
        #expect(RecipeImportURL.firstWebURL(in: "Look at this: https://example.com/pasta yum")?.absoluteString
                == "https://example.com/pasta")
        #expect(RecipeImportURL.firstWebURL(in: "write to me@example.com") == nil)
        #expect(RecipeImportURL.firstWebURL(in: "no link here") == nil)
    }
}

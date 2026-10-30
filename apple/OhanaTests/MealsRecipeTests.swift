import Foundation
import Testing
@testable import Ohana

/// The recipe screens' data: decoding what web/lib/meals/app-routes.ts sends, and the logic
/// ported from the web (scaling, quantities, machine programs, the form's payload, Markdown).
struct MealsRecipeDecodingTests {
    static let detailJSON = """
    {"recipe":{"id":"r1","title":"Tomato soup","description":"Warm","listType":"KNOWN","defaultServings":2,
    "prepTimeMinutes":10,"cookTimeMinutes":null,"leftoverDays":null,"image":"recipes/r1_1761800000000.webp",
    "createdAt":"2026-11-01T12:00:00.000Z","updatedAt":"2026-11-01T12:00:00.000Z",
    "tags":[{"id":"t1","category":"CUISINE","nameEn":"Italian","nameDe":"Italienisch"}],
    "ingredients":[{"id":11,"ingredientId":1,"quantity":"400","unitId":1,"order":0},
                   {"id":12,"ingredientId":3,"quantity":"2","unitId":2,"order":1}],
    "manualSteps":[{"id":21,"method":"MANUAL","stepNumber":1,"instruction":"Chop","programType":"","temperature":null,
      "durationSeconds":null,"speed":null,"turbo":false,"direction":"","weightGrams":null,
      "ingredients":[{"recipeIngredientId":11,"quantity":"400"}]}],
    "machineSteps":[{"id":22,"method":"MACHINE","stepNumber":1,"instruction":"Cook","programType":"MANUAL_COOKING",
      "temperature":100,"durationSeconds":600,"speed":1,"turbo":false,"direction":"LEFT","weightGrams":null,"ingredients":[]}]},
    "ingredients":[{"id":1,"nameEn":"Tomato","nameDe":"Tomate","category":"PRODUCE"},
                   {"id":3,"nameEn":"Basil","nameDe":"Basil","category":"OTHER"}],
    "units":[{"id":1,"nameEn":"gram","nameDe":"Gramm","abbreviation":"g"},
             {"id":2,"nameEn":"piece","nameDe":"Stück","abbreviation":"pc"}]}
    """

    static func detail() throws -> RecipeDetailResponse {
        try APIClient.decoder.decode(RecipeDetailResponse.self, from: Data(detailJSON.utf8))
    }

    @Test func decodesARecipe() throws {
        let response = try Self.detail()
        let r = response.recipe
        #expect(r.title == "Tomato soup")
        #expect(r.list == .known)
        #expect(r.cookTimeMinutes == nil)
        #expect(r.imagePath == "/api/images/recipes/r1_1761800000000.webp")
        #expect(r.tags.first?.category == "CUISINE")
        #expect(r.manualSteps.first?.ingredients.first?.recipeIngredientId == 11)
        #expect(r.machineSteps.first?.direction == "LEFT")
        #expect(response.units.map(\.abbreviation) == ["g", "pc"])
    }

    @Test func decodesAPageAndTheSmallAnswers() throws {
        let page = try APIClient.decoder.decode(RecipeListPage.self, from: Data("""
        {"items":[{"id":"r1","title":"Pizza","description":"","listType":"TO_TRY","defaultServings":4,"prepTimeMinutes":null,
        "cookTimeMinutes":30,"leftoverDays":1,"image":"","createdAt":"2026-11-01T12:00:00.000Z",
        "updatedAt":"2026-11-01T12:00:00.000Z","tags":[]}],"totalCount":7}
        """.utf8))
        #expect(page.totalCount == 7)
        #expect(page.items.first?.imagePath == nil)
        #expect(page.items.first?.leftoverDays == 1)

        let status = try APIClient.decoder.decode(MealsAIStatus.self, from: Data(#"{"generate":true,"photos":false}"#.utf8))
        #expect(status == MealsAIStatus(generate: true, photos: false))
        let tags = try APIClient.decoder.decode(RecipeTagsResponse.self, from: Data(
            #"{"tags":[{"id":"a","category":"DIETARY","nameEn":"Vegan","nameDe":"Vegan"}]}"#.utf8))
        #expect(tags.tags.count == 1)
        let catalog = try APIClient.decoder.decode(RecipeCatalog.self, from: Data(
            #"{"ingredients":[{"id":1,"nameEn":"Tomato","nameDe":"Tomate","category":"PRODUCE"}],"units":[{"id":1,"nameEn":"gram","nameDe":"Gramm","abbreviation":"g"}]}"#.utf8))
        #expect(catalog.ingredients.first?.nameDe == "Tomate")
        #expect(try APIClient.decoder.decode(RecipeMoveResponse.self, from: Data(#"{"listType":"TO_TRY"}"#.utf8)).listType == "TO_TRY")
        #expect(try APIClient.decoder.decode(RecipeBulkResponse.self, from: Data(#"{"createdIds":["x","y"]}"#.utf8)).createdIds.count == 2)
    }

    @Test func readsTheGeneratorStream() throws {
        let recipe = RecipeGenerateEvent.parse("""
        {"type":"recipe","index":0,"data":{"title":"Mock Recipe 1","description":"","default_servings":2,"prep_time_minutes":10,
        "cook_time_minutes":null,"leftover_days":null,"ingredients":[{"name_en":"Tomato","name_de":"Tomate","category":"PRODUCE",
        "quantity":200,"unit_abbreviation":"g","unit_id":1,"order":0},{"name_en":"Salt","name_de":"Salz","quantity":"1.5",
        "unit_abbreviation":"tsp","unit_id":null,"order":1}],"manual_steps":[{"step_number":1,"instruction":"Cook"}],
        "machine_steps":[{"step_number":1,"instruction":"Stir","program_type":"MANUAL_COOKING","temperature":100,
        "duration_seconds":60,"speed":1,"turbo":false,"direction":"LEFT","weight_grams":null}],"tag_names_en":["Fish"],"tag_ids":["t9"]}}
        """)
        guard case let .recipe(index, data) = recipe else { Issue.record("not a recipe: \(String(describing: recipe))"); return }
        #expect(index == 0)
        #expect(data.ingredients?.map { $0.quantity?.text } == ["200", "1.5"])

        let bulk = RecipeBulkInput.Recipe(generated: data, imageBase64: "AAAA")
        #expect(bulk.ingredients.map(\.unitAbbreviation) == ["g", "tsp"])
        #expect(bulk.machineSteps.first?.programType == "MANUAL_COOKING")
        #expect(bulk.tagIds == ["t9"])
        let json = try #require(String(data: APIClient.encoder.encode(RecipeBulkInput(recipes: [bulk])), encoding: .utf8))
        #expect(json.contains(#""cookTimeMinutes":null"#))
        #expect(json.contains(#""imageBase64":"AAAA""#))

        #expect(RecipeGenerateEvent.parse(#"{"type":"image","index":1,"data":{"image_base64":"UklG"}}"#) == .image(index: 1, base64: "UklG"))
        #expect(RecipeGenerateEvent.parse(#"{"type":"error","message":"boom"}"#) == .error("boom"))
        #expect(RecipeGenerateEvent.parse(#"{"type":"image_error","message":"no"}"#) == .imageError("no"))
        #expect(RecipeGenerateEvent.parse(#"{"type":"done"}"#) == .done)
        #expect(RecipeGenerateEvent.parse("  ") == nil)
    }
}

struct MealsRecipeLogicTests {
    @Test func scalesQuantities() {
        #expect(RecipeQuantity.scale("400", servings: 3, defaultServings: 2) == Decimal(600))
        #expect(RecipeQuantity.plain(RecipeQuantity.scale("1", servings: 1, defaultServings: 3)!) == "0.33")
        #expect(RecipeQuantity.plain(RecipeQuantity.scale("0,5", servings: 4, defaultServings: 2)!) == "1")
        #expect(RecipeQuantity.scale("a pinch", servings: 4, defaultServings: 2) == nil)
        #expect(RecipeQuantity.factor(servings: 2, defaultServings: 0) == 1)
    }

    @Test func roundsHalfToEven() {
        #expect(RecipeQuantity.plain(Decimal(string: "0.125")!) == "0.12")
        #expect(RecipeQuantity.plain(Decimal(string: "0.135")!) == "0.14")
        #expect(RecipeQuantity.plain(Decimal(string: "200.00")!) == "200")
        #expect(RecipeQuantity.normalized(" ") == "0")
        #expect(RecipeQuantity.normalized("1,25") == "1.25")
    }

    @Test func formatsDurations() {
        #expect(RecipeDuration.format(45) == "45s")
        #expect(RecipeDuration.format(120) == "2m")
        #expect(RecipeDuration.format(125) == "2m 5s")
    }

    @Test func checksMachinePrograms() {
        #expect(RecipeValidation.programErrors("MANUAL_COOKING", .init(temperature: 100, durationSeconds: 60, speed: 2, direction: "LEFT")).isEmpty)
        #expect(RecipeValidation.programErrors("MANUAL_COOKING", .init(temperature: 100, durationSeconds: 60, speed: 2))
            == ["direction is required for MANUAL_COOKING"])
        #expect(RecipeValidation.programErrors("TURBO", .init(durationSeconds: 61)) == ["duration_seconds must be between 1 and 60, got 61"])
        #expect(RecipeValidation.programErrors("SOUS_VIDE", .init(temperature: 60, durationSeconds: 40000)).isEmpty)
        #expect(RecipeValidation.programErrors("FERMENTATION", .init(temperature: 70, durationSeconds: 10))
            == ["temperature must be between 37 and 60, got 70"])
        #expect(RecipeValidation.programErrors("PRE_CLEANING", .init()).isEmpty)
        #expect(RecipeValidation.programErrors("NOPE", .init()) == ["Invalid program_type: NOPE"])
    }

    @Test func findsOverAllocatedIngredients() {
        let over = RecipeValidation.overAllocated(ingredients: [(0, "400"), (1, "2")],
                                                  steps: [(0, "300"), (0, "150"), (1, "2")])
        #expect(over == [0])
    }

    @Test func buildsTheFormPayload() throws {
        let response = try MealsRecipeDecodingTests.detail()
        let model = RecipeEditorModel(response.recipe, catalog: response.ingredients)
        #expect(model.ingredients.map(\.name) == ["Tomato", "Basil"])
        #expect(model.steps(.manual).first?.shares.count == 1)

        model.addStep(.manual) // empty: left out
        model.removeIngredients(at: [0]) // its step share goes too
        model.addIngredient(defaultUnit: 1)
        model.ingredients[1].name = "Saffron"
        model.ingredients[1].quantity = "0,5"
        let payload = model.payload
        #expect(payload.ingredients.map(\.order) == [0, 1])
        #expect(payload.ingredients[0].ingredientId == 3)
        #expect(payload.ingredients[1].ingredientId == nil)
        #expect(payload.ingredients[1].nameEn == "Saffron")
        #expect(payload.ingredients[1].quantity == "0.5")
        #expect(payload.steps.map(\.method) == ["MANUAL", "MACHINE"])
        #expect(payload.steps[0].ingredients.isEmpty)
        #expect(payload.steps[1].programType == "MANUAL_COOKING")
        #expect(payload.tagIds == ["t1"])

        let json = try #require(String(data: APIClient.encoder.encode(payload), encoding: .utf8))
        #expect(json.contains(#""cookTimeMinutes":null"#))
        #expect(json.contains(#""weightGrams":null"#))
    }

    @Test func checksTheForm() {
        let model = RecipeEditorModel(listType: .toTry)
        #expect(!model.problems.isEmpty)
        model.title = "Soup"
        #expect(model.problems.isEmpty)
        model.addStep(.machine)
        model.steps[0].programType = "WEIGHING"
        #expect(model.problems.count == 1)
        model.steps[0].weightGrams = 200
        #expect(model.problems.isEmpty)
        #expect(model.payload.listType == "TO_TRY")
        #expect(model.payload.steps.first?.stepNumber == 1)
    }

    @Test func movesStepsWithinTheirMethod() {
        let model = RecipeEditorModel(listType: .known)
        model.addStep(.manual); model.addStep(.machine); model.addStep(.manual)
        model.steps[0].instruction = "A"; model.steps[2].instruction = "B"
        let b = model.steps[2].id
        #expect(model.canMoveStep(b, by: -1))
        #expect(!model.canMoveStep(b, by: 1))
        model.moveStep(b, by: -1)
        #expect(model.steps(.manual).map(\.instruction) == ["B", "A"])
        #expect(model.steps[1].method == .machine)
    }

    @Test func writesMarkdown() throws {
        let recipe = RecipeResolved(try MealsRecipeDecodingTests.detail())
        let text = recipe.markdown(portions: 4, german: false)
        // Like the web, runs of spaces collapse (also a step ingredient's indent).
        #expect(text == """
        # Tomato soup

        Warm

        4 Servings · Prep: 10 min

        ## Ingredients

        - 800 g Tomato
        - 4 pc Basil

        ## Steps

        1. Chop
         - 800 g Tomato

        ## Machine Steps

        1. Cook

        """)
        let lines = recipe.lines(servings: 1)
        #expect(lines.map(\.unit) == ["g", "pc"])
        #expect(lines.map(\.name).count == 2)
        #expect(recipe.steps(.machine).count == 1)
    }
}

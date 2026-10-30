import Foundation

// The meals' recipe shapes as the server sends them (web/lib/meals/queries/recipes.ts,
// web/lib/meals/app-routes.ts, web/lib/meals/ai/recipes.ts). Field names match the JSON.

/// "KNOWN" (Favourites) or "TO_TRY" (Want to try).
enum RecipeListType: String, Codable, CaseIterable, Identifiable, Hashable {
    case known = "KNOWN"
    case toTry = "TO_TRY"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .known: "Favourites"
        case .toTry: "Want to try"
        }
    }

    var other: RecipeListType { self == .known ? .toTry : .known }
}

/// The list's orders (web: listRecipes `sort`).
enum RecipeSort: String, CaseIterable, Identifiable {
    case nameAsc = "name-asc"
    case nameDesc = "name-desc"
    case newest
    case updated

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .nameAsc: "Name A–Z"
        case .nameDesc: "Name Z–A"
        case .newest: "Newest first"
        case .updated: "Recently updated"
        }
    }
}

/// The tag categories, in the web's order.
enum RecipeTagCategory: String, CaseIterable, Identifiable {
    case dietary = "DIETARY"
    case protein = "PROTEIN"
    case cuisine = "CUISINE"
    case mealType = "MEAL_TYPE"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .dietary: "Dietary"
        case .protein: "Protein"
        case .cuisine: "Cuisine"
        case .mealType: "Meal Type"
        }
    }
}

struct RecipeTag: Codable, Hashable, Identifiable {
    let id: String
    let category: String
    let nameEn: String
    let nameDe: String

    var name: String { RecipeLocale.pick(en: nameEn, de: nameDe) }
}

struct RecipeTagsResponse: Codable {
    let tags: [RecipeTag]
}

struct RecipeSummary: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let description: String
    let listType: String
    let defaultServings: Int
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let leftoverDays: Int?
    /// Relative to the media root ("recipes/<id>_<ts>.webp"); "" without a photo.
    let image: String
    let createdAt: String
    let updatedAt: String
    let tags: [RecipeTag]

    var imagePath: String? { RecipeImage.path(image) }
}

struct RecipeListPage: Codable {
    let items: [RecipeSummary]
    let totalCount: Int
}

/// One of the shared ingredients (IngredientLite).
struct RecipeCatalogIngredient: Codable, Hashable, Identifiable {
    let id: Int
    let nameEn: String
    let nameDe: String
    let category: String

    var name: String { RecipeLocale.pick(en: nameEn, de: nameDe) }
}

/// One of the shared units (UnitLite).
struct RecipeUnit: Codable, Hashable, Identifiable {
    let id: Int
    let nameEn: String
    let nameDe: String
    let abbreviation: String
}

struct RecipeCatalog: Codable {
    let ingredients: [RecipeCatalogIngredient]
    let units: [RecipeUnit]
}

struct RecipeIngredient: Codable, Hashable, Identifiable {
    let id: Int
    let ingredientId: Int
    let quantity: String
    let unitId: Int
    let order: Int
}

struct RecipeStepIngredient: Codable, Hashable {
    let recipeIngredientId: Int
    let quantity: String
}

struct RecipeStep: Codable, Hashable, Identifiable {
    let id: Int
    let method: String
    let stepNumber: Int
    let instruction: String
    let programType: String
    let temperature: Int?
    let durationSeconds: Int?
    let speed: Int?
    let turbo: Bool
    let direction: String
    let weightGrams: Int?
    let ingredients: [RecipeStepIngredient]
}

struct RecipeDetail: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let description: String
    let listType: String
    let defaultServings: Int
    let prepTimeMinutes: Int?
    let cookTimeMinutes: Int?
    let leftoverDays: Int?
    let image: String
    let createdAt: String
    let updatedAt: String
    let tags: [RecipeTag]
    let ingredients: [RecipeIngredient]
    let manualSteps: [RecipeStep]
    let machineSteps: [RecipeStep]

    var imagePath: String? { RecipeImage.path(image) }
    var list: RecipeListType { RecipeListType(rawValue: listType) ?? .known }
}

/// GET /meals/recipes/{id}: the recipe with the shared ingredients and units it names.
struct RecipeDetailResponse: Codable {
    let recipe: RecipeDetail
    let ingredients: [RecipeCatalogIngredient]
    let units: [RecipeUnit]
}

/// GET /meals/status: whether the family's AI is set up (lib/meals/ai/status.ts).
struct MealsAIStatus: Codable, Equatable {
    let generate: Bool
    let photos: Bool

    static let none = MealsAIStatus(generate: false, photos: false)
}

struct RecipeIDResponse: Codable { let id: String }
struct RecipeMoveResponse: Codable { let listType: String }
struct RecipeImageResponse: Codable { let image: String }
struct RecipeBulkResponse: Codable { let createdIds: [String] }

// MARK: Saving (UpsertRecipeInput, web/lib/meals/recipes/upsert.ts)

struct RecipeUpsertInput: Codable, Equatable {
    var title: String
    var description: String
    var listType: String
    var defaultServings: Int
    var prepTimeMinutes: Int?
    var cookTimeMinutes: Int?
    var leftoverDays: Int?
    var ingredients: [Ingredient]
    var steps: [Step]
    var tagIds: [String]

    struct Ingredient: Codable, Equatable {
        var ingredientId: Int?
        var nameEn: String
        var nameDe: String
        var quantity: String
        var unitId: Int
        var order: Int
    }

    struct StepIngredient: Codable, Equatable {
        var recipeIngredientOrder: Int
        var quantity: String
    }

    struct Step: Codable, Equatable {
        var method: String
        var stepNumber: Int
        var instruction: String
        var programType: String
        var temperature: Int?
        var durationSeconds: Int?
        var speed: Int?
        var turbo: Bool
        var direction: String
        var weightGrams: Int?
        var ingredients: [StepIngredient]
    }

    /// Nulls are sent as `null` (the server's schema wants the keys).
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(listType, forKey: .listType)
        try c.encode(defaultServings, forKey: .defaultServings)
        try c.encode(prepTimeMinutes, forKey: .prepTimeMinutes)
        try c.encode(cookTimeMinutes, forKey: .cookTimeMinutes)
        try c.encode(leftoverDays, forKey: .leftoverDays)
        try c.encode(ingredients, forKey: .ingredients)
        try c.encode(steps, forKey: .steps)
        try c.encode(tagIds, forKey: .tagIds)
    }
}

extension RecipeUpsertInput.Ingredient {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ingredientId, forKey: .ingredientId)
        try c.encode(nameEn, forKey: .nameEn)
        try c.encode(nameDe, forKey: .nameDe)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unitId, forKey: .unitId)
        try c.encode(order, forKey: .order)
    }
}

extension RecipeUpsertInput.Step {
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        try c.encode(stepNumber, forKey: .stepNumber)
        try c.encode(instruction, forKey: .instruction)
        try c.encode(programType, forKey: .programType)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(speed, forKey: .speed)
        try c.encode(turbo, forKey: .turbo)
        try c.encode(direction, forKey: .direction)
        try c.encode(weightGrams, forKey: .weightGrams)
        try c.encode(ingredients, forKey: .ingredients)
    }
}

// MARK: Tags

struct RecipeTagInput: Codable {
    var category: String?
    var nameEn: String
    var nameDe: String
}

// MARK: AI generation (POST /recipes/generate, an NDJSON stream; web/lib/meals/ai/stream.ts)

struct RecipeGenerateRequest: Codable {
    var count: Int
    var tagIds: [String]
    var freeText: String
    var generateImages: Bool
}

/// A number or a string in the JSON, kept as text (the model's quantities).
struct RecipeLooseText: Codable, Hashable {
    let text: String

    init(_ text: String) { self.text = text }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = RecipeQuantity.plain(Decimal(d)) }
        else { text = "" }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// GeneratedRecipeData (snake_case, as the stream sends it).
struct RecipeGenerated: Codable, Hashable {
    let title: String
    let description: String?
    let default_servings: Int?
    let prep_time_minutes: Int?
    let cook_time_minutes: Int?
    let leftover_days: Int?
    let ingredients: [Ingredient]?
    let manual_steps: [Step]?
    let machine_steps: [Step]?
    let tag_names_en: [String]?
    let tag_ids: [String]?

    struct Ingredient: Codable, Hashable {
        let name_en: String
        let name_de: String
        let category: String?
        let quantity: RecipeLooseText?
        let unit_abbreviation: String?
        let unit_id: Int?
        let order: Int?
    }

    struct Step: Codable, Hashable {
        let step_number: Int
        let instruction: String?
        let program_type: String?
        let temperature: Int?
        let duration_seconds: Int?
        let speed: Int?
        let turbo: Bool?
        let direction: String?
        let weight_grams: Int?
    }
}

/// One line of the generator's stream.
enum RecipeGenerateEvent: Decodable, Equatable {
    case recipe(index: Int, data: RecipeGenerated)
    case image(index: Int, base64: String)
    case imageError(String)
    case error(String)
    case done
    case unknown

    private enum Keys: String, CodingKey { case type, index, data, message }
    private struct ImageData: Decodable { let image_base64: String }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "recipe":
            self = .recipe(index: try c.decode(Int.self, forKey: .index), data: try c.decode(RecipeGenerated.self, forKey: .data))
        case "image":
            self = .image(index: try c.decode(Int.self, forKey: .index),
                          base64: try c.decode(ImageData.self, forKey: .data).image_base64)
        case "image_error":
            self = .imageError(try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        case "error":
            self = .error(try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        case "done":
            self = .done
        default:
            self = .unknown
        }
    }

    static func parse(_ line: String) -> RecipeGenerateEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? APIClient.decoder.decode(RecipeGenerateEvent.self, from: Data(trimmed.utf8))
    }
}

/// BulkRecipeInput (web/lib/meals/recipes/bulk-create.ts): what saving the picks sends.
struct RecipeBulkInput: Codable, Equatable {
    var recipes: [Recipe]

    struct Recipe: Codable, Equatable {
        var title: String
        var description: String
        var defaultServings: Int
        var prepTimeMinutes: Int?
        var cookTimeMinutes: Int?
        var leftoverDays: Int?
        var ingredients: [Ingredient]
        var manualSteps: [Step]
        var machineSteps: [Step]
        var tagIds: [String]
        var imageBase64: String?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(description, forKey: .description)
            try c.encode(defaultServings, forKey: .defaultServings)
            try c.encode(prepTimeMinutes, forKey: .prepTimeMinutes)
            try c.encode(cookTimeMinutes, forKey: .cookTimeMinutes)
            try c.encode(leftoverDays, forKey: .leftoverDays)
            try c.encode(ingredients, forKey: .ingredients)
            try c.encode(manualSteps, forKey: .manualSteps)
            try c.encode(machineSteps, forKey: .machineSteps)
            try c.encode(tagIds, forKey: .tagIds)
            try c.encode(imageBase64, forKey: .imageBase64)
        }
    }

    struct Ingredient: Codable, Equatable {
        var nameEn: String
        var nameDe: String
        var category: String
        var quantity: String
        var unitAbbreviation: String
        var order: Int
    }

    struct Step: Codable, Equatable {
        var stepNumber: Int
        var instruction: String
        var programType: String?
        var temperature: Int?
        var durationSeconds: Int?
        var speed: Int?
        var turbo: Bool?
        var direction: String?
        var weightGrams: Int?
    }
}

extension RecipeBulkInput.Recipe {
    /// The generate page's toBulkInput.
    init(generated d: RecipeGenerated, imageBase64: String?) {
        title = d.title
        description = d.description ?? ""
        defaultServings = d.default_servings ?? 2
        prepTimeMinutes = d.prep_time_minutes
        cookTimeMinutes = d.cook_time_minutes
        leftoverDays = d.leftover_days
        ingredients = (d.ingredients ?? []).enumerated().map { idx, i in
            RecipeBulkInput.Ingredient(nameEn: i.name_en, nameDe: i.name_de, category: i.category ?? "OTHER",
                                       quantity: i.quantity?.text ?? "0", unitAbbreviation: i.unit_abbreviation ?? "",
                                       order: i.order ?? idx)
        }
        manualSteps = (d.manual_steps ?? []).map {
            RecipeBulkInput.Step(stepNumber: $0.step_number, instruction: $0.instruction ?? "")
        }
        machineSteps = (d.machine_steps ?? []).map {
            RecipeBulkInput.Step(stepNumber: $0.step_number, instruction: $0.instruction ?? "", programType: $0.program_type,
                                 temperature: $0.temperature, durationSeconds: $0.duration_seconds, speed: $0.speed,
                                 turbo: $0.turbo, direction: $0.direction, weightGrams: $0.weight_grams)
        }
        tagIds = d.tag_ids ?? []
        self.imageBase64 = imageBase64
    }
}

// MARK: Helpers

/// Which of a row's two names to show: the app's language (German or English).
enum RecipeLocale {
    static var isGerman: Bool {
        (Bundle.main.preferredLocalizations.first ?? Locale.current.language.languageCode?.identifier ?? "en")
            .hasPrefix("de")
    }

    /// The `locale` the list's name ordering uses.
    static var code: String { isGerman ? "de" : "en" }

    static func pick(en: String, de: String) -> String {
        isGerman ? (de.isEmpty ? en : de) : (en.isEmpty ? de : en)
    }
}

enum RecipeImage {
    /// The server path of a recipe's photo (served to the family's members only).
    static func path(_ image: String) -> String? {
        image.isEmpty ? nil : "/api/images/\(image)"
    }
}

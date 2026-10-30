import Foundation

// Pure recipe logic, ported from the web: scaling (lib/meals/domain/recipes/scaling.ts),
// quantities and durations (lib/meals/display/format.ts), the machine programs and their checks
// (domain/recipes/program-validation.ts, step-validation.ts) and the text export
// (lib/meals/recipes/export.ts generateMarkdown).

enum RecipeQuantity {
    /// A quantity as the server stores it ("400", "0.5"); a comma is taken as the decimal mark.
    static func parse(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, cleaned.range(of: #"^-?\d*\.?\d+$|^-?\d+\.$"#, options: .regularExpression) != nil
        else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// `servings / defaultServings` (scaleFactor).
    static func factor(servings: Int, defaultServings: Int) -> Decimal {
        guard defaultServings > 0 else { return 1 }
        return Decimal(servings) / Decimal(defaultServings)
    }

    /// A recipe quantity for `servings` (scaleQuantity); nil when it isn't a number.
    static func scale(_ quantity: String, servings: Int, defaultServings: Int) -> Decimal? {
        guard let q = parse(quantity) else { return nil }
        return q * factor(servings: servings, defaultServings: defaultServings)
    }

    /// Rounded to two decimals, half to even (formatQuantity).
    static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .bankers)
        return result
    }

    /// As the web writes it: "0.5", "200", "1.33".
    static func plain(_ value: Decimal) -> String {
        let r = rounded(value)
        return NSDecimalNumber(decimal: r).stringValue
    }

    /// For the screen: in the user's locale ("0,5" in German).
    static func display(_ value: Decimal) -> String {
        rounded(value).formatted(.number.precision(.fractionLength(0...2)))
    }

    /// A stored quantity scaled for `servings`, for the screen (the text itself when it isn't a number).
    static func display(_ quantity: String, servings: Int, defaultServings: Int) -> String {
        guard let scaled = scale(quantity, servings: servings, defaultServings: defaultServings) else { return quantity }
        return display(scaled)
    }

    /// What the server gets for a typed quantity: the number in its form ("0,5" → "0.5"),
    /// "0" when empty (the web editor's buildPayload).
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "0" }
        if let value = parse(trimmed) { return NSDecimalNumber(decimal: value).stringValue }
        return trimmed
    }
}

enum RecipeDuration {
    /// "45s", "2m", "2m 5s" (formatDuration).
    static func format(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60, s = seconds % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }
}

/// A machine program's parameter (PROGRAM_PARAMS' field names).
enum RecipeProgramParam: String, CaseIterable {
    case temperature
    case durationSeconds = "duration_seconds"
    case speed
    case direction
    case turbo
    case weightGrams = "weight_grams"
}

/// The machine programs (Thermomix-style) a machine step can run.
enum RecipeProgram: String, CaseIterable, Identifiable {
    case manualCooking = "MANUAL_COOKING"
    case chopping = "CHOPPING"
    case kneading = "KNEADING"
    case steaming = "STEAMING"
    case blending = "BLENDING"
    case searing = "SEARING"
    case slowCooking = "SLOW_COOKING"
    case sousVide = "SOUS_VIDE"
    case weighing = "WEIGHING"
    case turbo = "TURBO"
    case eggCooking = "EGG_COOKING"
    case fermentation = "FERMENTATION"
    case preCleaning = "PRE_CLEANING"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .manualCooking: "Manual Cooking"
        case .chopping: "Chopping"
        case .kneading: "Kneading"
        case .steaming: "Steaming"
        case .blending: "Blending"
        case .searing: "Searing"
        case .slowCooking: "Slow Cooking"
        case .sousVide: "Sous Vide"
        case .weighing: "Weighing"
        case .turbo: "Turbo"
        case .eggCooking: "Egg Cooking"
        case .fermentation: "Fermentation"
        case .preCleaning: "Pre-Cleaning"
        }
    }

    /// The program's parameters and whether each is required.
    var params: [(RecipeProgramParam, Bool)] {
        switch self {
        case .manualCooking: [(.temperature, true), (.durationSeconds, true), (.speed, true), (.direction, true), (.turbo, false)]
        case .chopping: [(.durationSeconds, true), (.speed, true)]
        case .kneading, .blending, .turbo, .eggCooking: [(.durationSeconds, true)]
        case .steaming, .slowCooking, .sousVide, .fermentation: [(.temperature, true), (.durationSeconds, true)]
        case .searing: [(.temperature, true), (.durationSeconds, true), (.speed, true)]
        case .weighing: [(.weightGrams, true)]
        case .preCleaning: []
        }
    }

    func uses(_ param: RecipeProgramParam) -> Bool { params.contains { $0.0 == param } }

    /// The allowed range of a numeric parameter (DEFAULT_RANGES with RANGE_OVERRIDES).
    func range(_ param: RecipeProgramParam) -> ClosedRange<Int> {
        switch (self, param) {
        case (.slowCooking, .durationSeconds), (.sousVide, .durationSeconds), (.fermentation, .durationSeconds): 1...43200
        case (.fermentation, .temperature): 37...60
        case (.turbo, .durationSeconds): 1...60
        case (_, .temperature): 37...130
        case (_, .durationSeconds): 1...5940
        case (_, .speed): 1...10
        case (_, .weightGrams): 1...5000
        default: 0...999_999
        }
    }

    /// The localized title of a stored program type ("" for none).
    static func title(of programType: String) -> String? {
        RecipeProgram(rawValue: programType).map { String(localized: $0.title) }
    }
}

/// A machine step's parameters, for checking.
struct RecipeProgramValues: Equatable {
    var temperature: Int?
    var durationSeconds: Int?
    var speed: Int?
    var direction: String?
    var turbo: Bool = false
    var weightGrams: Int?

    func value(_ param: RecipeProgramParam) -> Int? {
        switch param {
        case .temperature: temperature
        case .durationSeconds: durationSeconds
        case .speed: speed
        case .weightGrams: weightGrams
        case .direction, .turbo: nil
        }
    }
}

enum RecipeValidation {
    /// validateProgramStep: the problems of a machine step's parameters (empty: fine).
    static func programErrors(_ programType: String, _ v: RecipeProgramValues) -> [String] {
        guard let program = RecipeProgram(rawValue: programType) else { return ["Invalid program_type: \(programType)"] }
        var errors: [String] = []
        for (param, required) in program.params {
            switch param {
            case .turbo:
                continue
            case .direction:
                let direction = (v.direction?.isEmpty ?? true) ? nil : v.direction
                if required && direction == nil {
                    errors.append("direction is required for \(programType)")
                } else if let direction, direction != "LEFT", direction != "RIGHT" {
                    errors.append("direction must be one of LEFT, RIGHT, got \(direction)")
                }
            default:
                guard let value = v.value(param) else {
                    if required { errors.append("\(param.rawValue) is required for \(programType)") }
                    continue
                }
                let range = program.range(param)
                if !range.contains(value) {
                    errors.append("\(param.rawValue) must be between \(range.lowerBound) and \(range.upperBound), got \(value)")
                }
            }
        }
        return errors
    }

    /// validateStepIngredientTotals: ingredient orders whose step quantities add up to more than
    /// the recipe has.
    static func overAllocated(ingredients: [(order: Int, quantity: String)],
                              steps: [(order: Int, quantity: String)]) -> Set<Int> {
        var available: [Int: Decimal] = [:]
        for i in ingredients { available[i.order] = RecipeQuantity.parse(i.quantity) ?? 0 }
        var totals: [Int: Decimal] = [:]
        for s in steps { totals[s.order, default: 0] += RecipeQuantity.parse(s.quantity) ?? 0 }
        return Set(totals.compactMap { order, total in
            guard let have = available[order], total > have else { return nil }
            return order
        })
    }
}

/// A recipe with its names resolved, for showing, cooking and sharing.
struct RecipeResolved {
    let detail: RecipeDetail
    let ingredientsByID: [Int: RecipeCatalogIngredient]
    let unitsByID: [Int: RecipeUnit]

    init(_ response: RecipeDetailResponse) {
        detail = response.recipe
        ingredientsByID = Dictionary(response.ingredients.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        unitsByID = Dictionary(response.units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// One line of an ingredient list.
    struct Line: Identifiable, Hashable {
        let id: Int
        let quantity: String
        let unit: String
        let name: String
    }

    var sortedIngredients: [RecipeIngredient] { detail.ingredients.sorted { $0.order < $1.order } }

    func line(_ ri: RecipeIngredient, quantity: String? = nil, servings: Int) -> Line {
        Line(id: ri.id,
             quantity: RecipeQuantity.display(quantity ?? ri.quantity, servings: servings, defaultServings: detail.defaultServings),
             unit: unitsByID[ri.unitId]?.abbreviation ?? "",
             name: ingredientsByID[ri.ingredientId]?.name ?? "?")
    }

    func lines(servings: Int) -> [Line] {
        sortedIngredients.map { line($0, servings: servings) }
    }

    /// A step's own ingredients (its share of the recipe's), scaled.
    func lines(of step: RecipeStep, servings: Int) -> [Line] {
        step.ingredients.compactMap { si in
            guard let ri = detail.ingredients.first(where: { $0.id == si.recipeIngredientId }) else { return nil }
            return line(ri, quantity: si.quantity, servings: servings)
        }
    }

    func steps(_ method: RecipeCookMethod) -> [RecipeStep] {
        (method == .machine ? detail.machineSteps : detail.manualSteps).sorted { $0.stepNumber < $1.stepNumber }
    }

    /// The export's fixed words, in the language of the recipe's names (export.ts metaLabels,
    /// sectionLabels).
    struct ExportLabels {
        let servings, prep, cook, ingredients, steps, machine: String

        init(german: Bool) {
            if german {
                (servings, prep, cook, ingredients, steps, machine) =
                    ("Portionen", "Vorbereitung", "Kochen", "Zutaten", "Zubereitung", "Maschinenschritte")
            } else {
                (servings, prep, cook, ingredients, steps, machine) =
                    ("Servings", "Prep", "Cook", "Ingredients", "Steps", "Machine Steps")
            }
        }
    }

    /// One step of the export: its text and its ingredient lines.
    struct ExportStep: Equatable {
        let instruction: String
        let ingredients: [String]
    }

    /// "4 Servings · Prep: 10 min · Cook: 20 min"
    func exportMeta(portions: Int, german: Bool) -> String {
        let labels = ExportLabels(german: german)
        var meta = ["\(portions) \(labels.servings)"]
        if let prep = detail.prepTimeMinutes { meta.append("\(labels.prep): \(prep) min") }
        if let cook = detail.cookTimeMinutes { meta.append("\(labels.cook): \(cook) min") }
        return meta.joined(separator: " · ")
    }

    /// "400 g Tomato" scaled to `portions`, behind `prefix` (export.ts ingredientLine).
    func exportLine(_ prefix: String, _ ri: RecipeIngredient, quantity: String? = nil, portions: Int, german: Bool) -> String {
        let scale = detail.defaultServings > 0 ? Decimal(portions) / Decimal(detail.defaultServings) : 1
        let q = RecipeQuantity.plain((RecipeQuantity.parse(quantity ?? ri.quantity) ?? 0) * scale)
        let unit = unitsByID[ri.unitId]?.abbreviation ?? ""
        let name = ingredientsByID[ri.ingredientId].map { german ? $0.nameDe : $0.nameEn } ?? "?"
        return "\(prefix)\(q) \(unit) \(name)"
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
    }

    /// The recipe's ingredient lines (those Ohana knows) for the export.
    func exportIngredients(_ prefix: String, portions: Int, german: Bool) -> [String] {
        sortedIngredients.filter { ingredientsByID[$0.ingredientId] != nil }
            .map { exportLine(prefix, $0, portions: portions, german: german) }
    }

    /// The steps of one method for the export, in order, with their ingredient lines.
    func exportSteps(_ method: RecipeCookMethod, prefix: String, portions: Int, german: Bool) -> [ExportStep] {
        steps(method).map { step in
            ExportStep(instruction: step.instruction, ingredients: step.ingredients.compactMap { si in
                guard let ri = detail.ingredients.first(where: { $0.id == si.recipeIngredientId }),
                      ingredientsByID[ri.ingredientId] != nil else { return nil }
                return exportLine(prefix, ri, quantity: si.quantity, portions: portions, german: german)
            })
        }
    }

    /// The recipe as Markdown text for `portions` (generateMarkdown).
    func markdown(portions: Int, sections: RecipeExportSections = .all, german: Bool = RecipeLocale.isGerman) -> String {
        let labels = ExportLabels(german: german)
        func steps(_ method: RecipeCookMethod) -> String {
            exportSteps(method, prefix: "   - ", portions: portions, german: german).enumerated().map { i, step in
                ([("\(i + 1). \(step.instruction)")] + step.ingredients).joined(separator: "\n")
            }.joined(separator: "\n")
        }

        var lines = ["# \(detail.title)", ""]
        if sections.description, !detail.description.isEmpty { lines += [detail.description, ""] }
        lines += [exportMeta(portions: portions, german: german), ""]
        let ingredients = exportIngredients("- ", portions: portions, german: german)
        if sections.ingredients, !ingredients.isEmpty {
            lines += ["## \(labels.ingredients)", ""] + ingredients + [""]
        }
        if sections.steps {
            if !detail.manualSteps.isEmpty { lines += ["## \(labels.steps)", "", steps(.manual), ""] }
            if !detail.machineSteps.isEmpty { lines += ["## \(labels.machine)", "", steps(.machine), ""] }
        }
        var text = lines.joined(separator: "\n")
        while text.last?.isWhitespace == true { text.removeLast() }
        return text + "\n"
    }
}

/// What a recipe export includes (the web's export dialog).
struct RecipeExportSections: Hashable {
    var image = true
    var description = true
    var ingredients = true
    var steps = true

    static let all = RecipeExportSections()
}

/// How a recipe is cooked: by hand or with the machine.
enum RecipeCookMethod: String, CaseIterable, Identifiable {
    case manual = "MANUAL"
    case machine = "MACHINE"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .manual: "By Hand"
        case .machine: "Machine"
        }
    }
}

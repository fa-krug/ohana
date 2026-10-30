import Foundation
import Observation

/// The recipe form (web: recipe-editor.tsx with its react-hook-form values): rows carry local
/// ids, so a step's ingredient shares stay with their ingredient when rows are removed.
@Observable
final class RecipeEditorModel {
    struct IngredientRow: Identifiable, Equatable {
        let id = UUID()
        /// The shared ingredient picked; nil: a new one named `name` (created when saving).
        var ingredientID: Int?
        var name: String = ""
        var quantity: String = ""
        var unitID: Int
    }

    struct Share: Identifiable, Equatable {
        let id = UUID()
        var ingredientRowID: UUID
        var quantity: String = ""
    }

    struct StepRow: Identifiable, Equatable {
        let id = UUID()
        var method: RecipeCookMethod
        var instruction: String = ""
        var programType: String = ""
        var temperature: Int?
        var durationSeconds: Int?
        var speed: Int?
        var turbo = false
        var direction: String = ""
        var weightGrams: Int?
        var shares: [Share] = []

        var program: RecipeProgram? { RecipeProgram(rawValue: programType) }

        var isEmpty: Bool { instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && programType.isEmpty }

        var programErrors: [String] {
            guard method == .machine, !programType.isEmpty else { return [] }
            return RecipeValidation.programErrors(programType, RecipeProgramValues(
                temperature: temperature, durationSeconds: durationSeconds, speed: speed,
                direction: direction, turbo: turbo, weightGrams: weightGrams))
        }
    }

    let recipeID: String?
    var title = ""
    var description = ""
    var listType: RecipeListType
    var servings = 2
    var prepMinutes: Int?
    var cookMinutes: Int?
    var leftoverDays: Int?
    var ingredients: [IngredientRow] = []
    var steps: [StepRow] = []
    var tagIDs: Set<String> = []
    /// What saving would have sent when the form opened.
    @ObservationIgnored private var original: RecipeUpsertInput?

    var isNew: Bool { recipeID == nil }

    /// Saving would change something (rows added but left empty, like empty steps, don't count
    /// where saving leaves them out).
    var hasChanges: Bool { payload != original }

    init(listType: RecipeListType) {
        recipeID = nil
        self.listType = listType
        original = payload
    }

    /// The form of a stored recipe (toInitialValues).
    init(_ recipe: RecipeDetail, catalog: [RecipeCatalogIngredient]) {
        recipeID = recipe.id
        title = recipe.title
        description = recipe.description
        listType = recipe.list
        servings = recipe.defaultServings
        prepMinutes = recipe.prepTimeMinutes
        cookMinutes = recipe.cookTimeMinutes
        leftoverDays = recipe.leftoverDays
        let names = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var rowByRecipeIngredient: [Int: UUID] = [:]
        ingredients = recipe.ingredients.sorted { $0.order < $1.order }.map { ri in
            let row = IngredientRow(ingredientID: ri.ingredientId, name: names[ri.ingredientId] ?? "",
                                    quantity: RecipeQuantity.parse(ri.quantity).map(RecipeQuantity.display) ?? ri.quantity,
                                    unitID: ri.unitId)
            rowByRecipeIngredient[ri.id] = row.id
            return row
        }
        func row(_ s: RecipeStep, _ method: RecipeCookMethod) -> StepRow {
            StepRow(method: method, instruction: s.instruction, programType: method == .machine ? s.programType : "",
                    temperature: s.temperature, durationSeconds: s.durationSeconds, speed: s.speed, turbo: s.turbo,
                    direction: s.direction, weightGrams: s.weightGrams,
                    shares: s.ingredients.compactMap { si in
                        rowByRecipeIngredient[si.recipeIngredientId].map {
                            Share(ingredientRowID: $0, quantity: RecipeQuantity.parse(si.quantity).map(RecipeQuantity.display) ?? si.quantity)
                        }
                    })
        }
        steps = recipe.manualSteps.sorted { $0.stepNumber < $1.stepNumber }.map { row($0, .manual) }
            + recipe.machineSteps.sorted { $0.stepNumber < $1.stepNumber }.map { row($0, .machine) }
        tagIDs = Set(recipe.tags.map(\.id))
        original = payload
    }

    // MARK: Editing

    func addIngredient(defaultUnit: Int) {
        ingredients.append(IngredientRow(unitID: defaultUnit))
    }

    func removeIngredients(at offsets: IndexSet) {
        let gone = Set(offsets.map { ingredients[$0].id })
        ingredients.remove(atOffsets: offsets)
        for i in steps.indices { steps[i].shares.removeAll { gone.contains($0.ingredientRowID) } }
    }

    func removeIngredient(_ id: UUID) {
        if let index = ingredients.firstIndex(where: { $0.id == id }) { removeIngredients(at: [index]) }
    }

    func addStep(_ method: RecipeCookMethod) {
        steps.append(StepRow(method: method))
    }

    func removeStep(_ id: UUID) {
        steps.removeAll { $0.id == id }
    }

    func steps(_ method: RecipeCookMethod) -> [StepRow] { steps.filter { $0.method == method } }

    /// Moves a step up (-1) or down (+1) among the steps of its method.
    func moveStep(_ id: UUID, by delta: Int) {
        guard let step = steps.first(where: { $0.id == id }) else { return }
        let same = steps.indices.filter { steps[$0].method == step.method }
        guard let pos = same.firstIndex(where: { steps[$0].id == id }) else { return }
        let target = pos + delta
        guard same.indices.contains(target) else { return }
        steps.swapAt(same[pos], same[target])
    }

    func canMoveStep(_ id: UUID, by delta: Int) -> Bool {
        guard let step = steps.first(where: { $0.id == id }) else { return false }
        let same = steps(step.method)
        guard let pos = same.firstIndex(where: { $0.id == id }) else { return false }
        return same.indices.contains(pos + delta)
    }

    // MARK: Checks

    /// Ingredient rows whose steps take more than the recipe has.
    var overAllocatedRows: Set<UUID> {
        let order = Dictionary(uniqueKeysWithValues: ingredients.enumerated().map { ($1.id, $0) })
        let over = RecipeValidation.overAllocated(
            ingredients: ingredients.enumerated().map { ($0, $1.quantity.isEmpty ? "0" : $1.quantity) },
            steps: steps.flatMap(\.shares).compactMap { share in
                order[share.ingredientRowID].map { ($0, share.quantity.isEmpty ? "0" : share.quantity) }
            })
        return Set(ingredients.enumerated().filter { over.contains($0.offset) }.map(\.element.id))
    }

    /// What keeps the form from saving (the server's checks, said before sending).
    var problems: [String] {
        var out: [String] = []
        if let titleProblem { out.append(titleProblem) }
        out += ingredientProblems
        if let error = steps.lazy.flatMap(\.programErrors).first { out.append(error) }
        return out
    }

    /// Shown under the name.
    var titleProblem: String? {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Title is required") : nil
    }

    /// Shown under the ingredients (a step's share is an ingredient's quantity too).
    var ingredientProblems: [String] {
        var out: [String] = []
        if ingredients.contains(where: { $0.ingredientID == nil && $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            out.append(String(localized: "Every ingredient needs a name"))
        }
        if ingredients.contains(where: { !$0.quantity.isEmpty && RecipeQuantity.parse($0.quantity) == nil })
            || steps.flatMap(\.shares).contains(where: { !$0.quantity.isEmpty && RecipeQuantity.parse($0.quantity) == nil }) {
            out.append(String(localized: "Quantities must be numbers"))
        }
        if !overAllocatedRows.isEmpty { out.append(String(localized: "Step ingredients exceed recipe quantities")) }
        return out
    }

    // MARK: Saving

    /// The UpsertRecipeInput of the form (buildPayload): empty steps are left out, steps are
    /// numbered per method, blank quantities become "0".
    var payload: RecipeUpsertInput {
        let order = Dictionary(uniqueKeysWithValues: ingredients.enumerated().map { ($1.id, $0) })
        func stepInputs(_ method: RecipeCookMethod) -> [RecipeUpsertInput.Step] {
            steps(method).filter { !$0.isEmpty }.enumerated().map { n, s in
                RecipeUpsertInput.Step(
                    method: method.rawValue, stepNumber: n + 1, instruction: s.instruction,
                    programType: method == .manual ? "" : s.programType,
                    temperature: s.temperature, durationSeconds: s.durationSeconds, speed: s.speed, turbo: s.turbo,
                    direction: s.direction, weightGrams: s.weightGrams,
                    ingredients: s.shares.compactMap { share in
                        order[share.ingredientRowID].map {
                            RecipeUpsertInput.StepIngredient(recipeIngredientOrder: $0, quantity: RecipeQuantity.normalized(share.quantity))
                        }
                    })
            }
        }
        return RecipeUpsertInput(
            title: title.trimmingCharacters(in: .whitespaces),
            description: description,
            listType: listType.rawValue,
            defaultServings: max(1, servings),
            prepTimeMinutes: prepMinutes,
            cookTimeMinutes: cookMinutes,
            leftoverDays: leftoverDays,
            ingredients: ingredients.enumerated().map { index, row in
                let name = row.name.trimmingCharacters(in: .whitespaces)
                return RecipeUpsertInput.Ingredient(
                    ingredientId: row.ingredientID, nameEn: row.ingredientID == nil ? name : "",
                    nameDe: row.ingredientID == nil ? name : "", quantity: RecipeQuantity.normalized(row.quantity),
                    unitId: row.unitID, order: index)
            },
            steps: stepInputs(.manual) + stepInputs(.machine),
            tagIds: tagIDs.sorted())
    }
}

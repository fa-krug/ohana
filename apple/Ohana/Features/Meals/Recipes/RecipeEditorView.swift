import SwiftUI

/// Creating or editing a recipe (web: recipe-editor.tsx): name, description, servings and times,
/// the list, ingredients from the shared list (or new ones) with quantities and units, steps by
/// hand and with the machine (program, settings, the step's share of the ingredients), tags.
struct RecipeEditorSheet: View {
    enum Mode {
        case create(RecipeListType)
        case edit(RecipeResolved)
    }

    let mode: Mode
    var onSaved: ((String) -> Void)?

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Loaded> = .idle

    struct Loaded {
        let model: RecipeEditorModel
        let catalog: RecipeCatalog
        var tags: [RecipeTag]
    }

    var body: some View {
        NavigationStack {
            LoadStateView(state: state, retry: load) { loaded in
                RecipeEditorForm(model: loaded.model, catalog: loaded.catalog, tags: loaded.tags, onSaved: { id in
                    onSaved?(id)
                    dismiss()
                })
            }
            .toolbar {
                if state.value == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
            }
        }
        .task { await load() }
        .interactiveDismissDisabled()
        .recipeSheetFrame(minWidth: 620, minHeight: 680)
    }

    private func load() async {
        await LoadState.run($state) {
            let c = try await RecipeCatalogCache.load(family.api)
            let t = try await family.api.get("/meals/tags", as: RecipeTagsResponse.self)
            let model: RecipeEditorModel
            switch mode {
            case let .create(list):
                model = RecipeEditorModel(listType: list)
            case let .edit(recipe):
                // Names of ingredients new since the catalog was cached come with the recipe.
                model = RecipeEditorModel(recipe.detail, catalog: c.ingredients + Array(recipe.ingredientsByID.values))
            }
            return Loaded(model: model, catalog: c, tags: t.tags)
        }
    }
}

private struct RecipeEditorForm: View {
    @Bindable var model: RecipeEditorModel
    let catalog: RecipeCatalog
    @State var tags: [RecipeTag]
    let onSaved: (String) -> Void

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var newTag = RecipeNewTag()

    var body: some View {
        Form {
            Section {
                TextField("Recipe name", text: $model.title, prompt: Text("What’s it called?"))
                    .font(.headline)
                TextField("Description", text: $model.description, axis: .vertical)
                    .lineLimit(2...6)
                if model.isNew {
                    Picker("List", selection: $model.listType) {
                        ForEach(RecipeListType.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                Stepper(value: $model.servings, in: 1...100) {
                    LabeledContent("Servings", value: "\(model.servings)")
                }
                RecipeMinutesField(title: "Prep (min)", value: $model.prepMinutes)
                RecipeMinutesField(title: "Cooking (min)", value: $model.cookMinutes)
            }

            ingredientsSection
            stepsSection(.manual)
            stepsSection(.machine)
            tagsSection

            if !model.problems.isEmpty {
                Section {
                    ForEach(model.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.isNew ? LocalizedStringKey("New Recipe") : LocalizedStringKey("Edit Recipe"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save", role: .confirm) { save() }
                        .disabled(!model.problems.isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
    }

    // MARK: Ingredients

    private var ingredientsSection: some View {
        Section {
            ForEach($model.ingredients) { $row in
                RecipeIngredientRowEditor(row: $row, catalog: catalog,
                                          overAllocated: model.overAllocatedRows.contains(row.id)) {
                    withAnimation { model.removeIngredient(row.id) }
                }
            }
            .onDelete { model.removeIngredients(at: $0) }
            Button {
                withAnimation { model.addIngredient(defaultUnit: catalog.units.first?.id ?? 1) }
            } label: {
                Label("Add ingredient", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Ingredients")
        }
    }

    // MARK: Steps

    private func stepsSection(_ method: RecipeCookMethod) -> some View {
        Section {
            let rows = model.steps(method)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, step in
                if let binding = binding(for: step.id) {
                    RecipeStepEditor(step: binding, number: index + 1, ingredients: model.ingredients, catalog: catalog,
                                     canMoveUp: model.canMoveStep(step.id, by: -1),
                                     canMoveDown: model.canMoveStep(step.id, by: 1),
                                     move: { delta in withAnimation { model.moveStep(step.id, by: delta) } },
                                     remove: { withAnimation { model.removeStep(step.id) } })
                }
            }
            Button {
                withAnimation { model.addStep(method) }
            } label: {
                Label("Add step", systemImage: "plus.circle.fill")
            }
        } header: {
            Text(method == .manual ? LocalizedStringKey("Manual steps") : LocalizedStringKey("Machine steps"))
        }
    }

    private func binding(for id: UUID) -> Binding<RecipeEditorModel.StepRow>? {
        guard model.steps.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.steps.first { $0.id == id } ?? RecipeEditorModel.StepRow(method: .manual) },
            set: { value in
                if let i = model.steps.firstIndex(where: { $0.id == id }) { model.steps[i] = value }
            })
    }

    // MARK: Tags

    private var tagsSection: some View {
        Section {
            RecipeTagPicker(tags: tags, selection: $model.tagIDs)
                .padding(.vertical, 4)
            DisclosureGroup("New tag") {
                RecipeNewTagFields(tag: $newTag)
                Button("Add") { createTag() }
                    .disabled(!newTag.isValid)
            }
        } header: {
            Text("Tags")
        }
    }

    private func createTag() {
        let input = newTag
        if tags.contains(where: { $0.category == input.category.rawValue
            && $0.nameEn.lowercased() == input.nameEn.trimmingCharacters(in: .whitespaces).lowercased() }) {
            ErrorBanner.shared.show(String(localized: "A tag with that name already exists in this category."))
            return
        }
        perform {
            let created: RecipeIDResponse = try await family.api.send(.post, "/meals/tags", body: input.body)
            tags.append(RecipeTag(id: created.id, category: input.category.rawValue,
                                  nameEn: input.body.nameEn, nameDe: input.body.nameDe))
            model.tagIDs.insert(created.id)
            newTag = RecipeNewTag(category: input.category)
            family.didChange(.recipes)
        }
    }

    // MARK: Saving

    private func save() {
        saving = true
        let payload = model.payload
        let recipeID = model.recipeID
        perform {
            defer { saving = false }
            let id: String
            if let recipeID {
                let res: RecipeIDResponse = try await family.api.send(.patch, "/meals/recipes/\(recipeID)", body: payload)
                id = res.id
            } else {
                let res: RecipeIDResponse = try await family.api.send(.post, "/meals/recipes", body: payload)
                id = res.id
            }
            if payload.ingredients.contains(where: { $0.ingredientId == nil }) {
                // New ingredients joined the shared list.
                _ = try? await RecipeCatalogCache.load(family.api, refresh: true)
            }
            family.didChange(.recipes, .meals, .mealPlan)
            onSaved(id)
        }
    }
}

/// A whole number of minutes, or nothing.
private struct RecipeMinutesField: View {
    let title: LocalizedStringKey
    @Binding var value: Int?

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number, prompt: Text("—"))
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .frame(maxWidth: 120)
                .labelsHidden()
        }
    }
}

/// One ingredient: the name with suggestions from the shared list, quantity and unit.
private struct RecipeIngredientRowEditor: View {
    @Binding var row: RecipeEditorModel.IngredientRow
    let catalog: RecipeCatalog
    let overAllocated: Bool
    let remove: () -> Void
    @FocusState private var nameFocused: Bool

    private var suggestions: [RecipeCatalogIngredient] {
        let query = row.name.trimmingCharacters(in: .whitespaces)
        guard nameFocused, !query.isEmpty else { return [] }
        if let id = row.ingredientID, catalog.ingredients.first(where: { $0.id == id })?.name == query { return [] }
        return catalog.ingredients
            .filter { $0.name.localizedStandardContains(query) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(query.lowercased()), bp = b.name.lowercased().hasPrefix(query.lowercased())
                if ap != bp { return ap }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: row.ingredientID == nil ? "plus.circle" : "checkmark.circle.fill")
                    .foregroundStyle(row.ingredientID == nil ? Color.secondary : ModuleTint.meals)
                    .help(row.ingredientID == nil ? LocalizedStringKey("A new ingredient") : LocalizedStringKey("From the ingredient list"))
                TextField("Ingredient", text: Binding(get: { row.name }, set: { value in
                    row.name = value
                    row.ingredientID = catalog.ingredients.first { $0.name.caseInsensitiveCompare(value) == .orderedSame }?.id
                }), prompt: Text("Search ingredient…"))
                .focused($nameFocused)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif
                TextField("Qty", text: $row.quantity)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .foregroundStyle(overAllocated ? .red : .primary)
                Picker("Unit", selection: $row.unitID) {
                    ForEach(catalog.units) { unit in
                        Text(unit.abbreviation.isEmpty ? unit.nameEn : unit.abbreviation).tag(unit.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                #if os(macOS)
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove")
                #endif
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions) { item in
                            Button(item.name) {
                                row.ingredientID = item.id
                                row.name = item.name
                                nameFocused = false
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

/// One step: for the machine its program and settings, the instruction, and which part of
/// the recipe's ingredients goes in.
private struct RecipeStepEditor: View {
    @Binding var step: RecipeEditorModel.StepRow
    let number: Int
    let ingredients: [RecipeEditorModel.IngredientRow]
    let catalog: RecipeCatalog
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Step \(number)").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Move up", systemImage: "arrow.up") { move(-1) }.disabled(!canMoveUp)
                    Button("Move down", systemImage: "arrow.down") { move(1) }.disabled(!canMoveDown)
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if step.method == .machine { programEditor }
            TextField("Instruction", text: $step.instruction, prompt: Text("What to do in this step…"), axis: .vertical)
                .lineLimit(2...8)
            sharesEditor
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var programEditor: some View {
        Picker("Program", selection: $step.programType) {
            Text("Free text").tag("")
            ForEach(RecipeProgram.allCases) { Text($0.title).tag($0.rawValue) }
        }
        if let program = step.program {
            if program.uses(.temperature) { RecipeIntField(title: "Temperature (°C)", value: $step.temperature) }
            if program.uses(.durationSeconds) { RecipeIntField(title: "Duration (s)", value: $step.durationSeconds) }
            if program.uses(.speed) { RecipeIntField(title: "Speed", value: $step.speed) }
            if program.uses(.weightGrams) { RecipeIntField(title: "Weight (g)", value: $step.weightGrams) }
            if program.uses(.direction) {
                Picker("Direction", selection: $step.direction) {
                    Text("—").tag("")
                    Text("Left").tag("LEFT")
                    Text("Right").tag("RIGHT")
                }
            }
            if program.uses(.turbo) { Toggle("Turbo", isOn: $step.turbo) }
            if let error = step.programErrors.first {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var sharesEditor: some View {
        ForEach($step.shares) { $share in
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Picker("Ingredient", selection: $share.ingredientRowID) {
                    ForEach(ingredients) { row in
                        Text(name(of: row)).tag(row.id)
                    }
                }
                .labelsHidden()
                TextField("Qty", text: $share.quantity)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Button {
                    step.shares.removeAll { $0.id == share.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
            }
        }
        if let first = ingredients.first {
            Button {
                step.shares.append(.init(ingredientRowID: first.id))
            } label: {
                Label("Add ingredient to step", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
    }

    private func name(of row: RecipeEditorModel.IngredientRow) -> String {
        if !row.name.isEmpty { return row.name }
        if let id = row.ingredientID, let item = catalog.ingredients.first(where: { $0.id == id }) { return item.name }
        return String(localized: "Unnamed ingredient")
    }
}

/// A whole-number setting, or nothing.
private struct RecipeIntField: View {
    let title: LocalizedStringKey
    @Binding var value: Int?

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number, prompt: Text("—"))
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .frame(maxWidth: 100)
                .labelsHidden()
        }
    }
}

/// A tag being created: category and both names.
struct RecipeNewTag: Equatable {
    var category: RecipeTagCategory = .cuisine
    var nameEn = ""
    var nameDe = ""

    var isValid: Bool {
        !nameEn.trimmingCharacters(in: .whitespaces).isEmpty && !nameDe.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: RecipeTagInput {
        RecipeTagInput(category: category.rawValue,
                       nameEn: nameEn.trimmingCharacters(in: .whitespaces),
                       nameDe: nameDe.trimmingCharacters(in: .whitespaces))
    }
}

struct RecipeNewTagFields: View {
    @Binding var tag: RecipeNewTag
    var showsCategory = true

    var body: some View {
        if showsCategory {
            Picker("Category", selection: $tag.category) {
                ForEach(RecipeTagCategory.allCases) { Text($0.title).tag($0) }
            }
        }
        TextField("Name (English)", text: $tag.nameEn)
        TextField("Name (German)", text: $tag.nameDe)
    }
}

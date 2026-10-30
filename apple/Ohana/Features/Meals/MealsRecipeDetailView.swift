import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A recipe's page (web: meals/recipes/[id]): photo, times, tags, the ingredients scaled to the
/// servings chosen here, the steps by hand and with the machine, and the actions: cook, edit,
/// share, move between the lists, photo (upload, AI, remove), delete. Pushed from the recipes
/// and from the meal plan.
struct MealsRecipeDetailView: View {
    let recipeID: String

    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<RecipeResolved> = .idle
    @State private var ai = MealsAIStatus.none
    @State private var servings: Int?
    @State private var editing = false
    @State private var cooking = false
    @State private var confirmDelete = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickingPhoto = false
    @State private var importingPhoto = false
    @State private var photoBusy = false

    var body: some View {
        LoadStateView(state: state, retry: load) { recipe in
            content(recipe)
        }
        .ohanaBackground(ModuleTint.meals)
        .navigationTitle(state.value?.detail.title ?? String(localized: "Recipe"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: family.revision(.recipes)) { await load() }
        .task { ai = (try? await family.api.get("/meals/status", as: MealsAIStatus.self)) ?? ai }
        .toolbar { if let recipe = state.value { toolbar(recipe) } }
        .sheet(isPresented: $editing) {
            if let recipe = state.value { RecipeEditorSheet(mode: .edit(recipe)) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $cooking) {
            NavigationStack { MealsCookView(recipeID: recipeID, servings: servings) }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await upload(data)
            }
        }
        #else
        .navigationDestination(isPresented: $cooking) { MealsCookView(recipeID: recipeID, servings: servings) }
        #endif
        .fileImporter(isPresented: $importingPhoto, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await upload(data) }
        }
        .confirmationDialog("Delete recipe?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let recipe = state.value?.detail {
                    RecipePendingDeletes.shared.schedule(recipe.id, title: recipe.title, family: family)
                    dismiss()
                }
            }
        } message: {
            Text("Delete this recipe? You’ll have a few seconds to undo.")
        }
    }

    private func load() async {
        await LoadState.run($state) {
            RecipeResolved(try await family.api.get("/meals/recipes/\(recipeID)", as: RecipeDetailResponse.self))
        }
    }

    // MARK: Page

    private func content(_ recipe: RecipeResolved) -> some View {
        let detail = recipe.detail
        let portions = servings ?? detail.defaultServings
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero(detail)
                VStack(alignment: .leading, spacing: 10) {
                    Text(detail.title)
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    RecipeMetaRow(prep: detail.prepTimeMinutes, cook: detail.cookTimeMinutes, servings: detail.defaultServings)
                    if !detail.description.isEmpty {
                        Text(detail.description)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !detail.tags.isEmpty {
                        RecipeFlowLayout(spacing: 6) {
                            ForEach(detail.tags) { RecipeTagChip(tag: $0) }
                        }
                    }
                }
                actions(recipe)
                servingsCard(detail, portions: portions)
                if !detail.ingredients.isEmpty {
                    GlassSection("Ingredients", systemImage: "carrot", tint: ModuleTint.meals) {
                        ForEach(recipe.lines(servings: portions)) { line in
                            RecipeIngredientLineView(line: line)
                        }
                    }
                }
                stepsSection(recipe, .manual, portions: portions)
                stepsSection(recipe, .machine, portions: portions)
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private func hero(_ detail: RecipeDetail) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(path: detail.imagePath) { RecipePhotoPlaceholder() }
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 28))
                .backgroundExtensionEffect()
            if photoBusy {
                ProgressView()
                    .padding(10)
                    .glassEffect(.regular, in: .circle)
                    .padding(12)
            }
        }
        .padding(.top, 8)
    }

    private func actions(_ recipe: RecipeResolved) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    cooking = true
                } label: {
                    Label("Let’s cook!", systemImage: "frying.pan")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(recipe.detail.manualSteps.isEmpty && recipe.detail.machineSteps.isEmpty)
                ShareLink(item: recipe.markdown(portions: servings ?? recipe.detail.defaultServings),
                          subject: Text(recipe.detail.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .tint(ModuleTint.meals)
    }

    private func servingsCard(_ detail: RecipeDetail, portions: Int) -> some View {
        HStack {
            Label("Servings", systemImage: "person.2")
                .font(.headline)
            Spacer()
            if portions != detail.defaultServings {
                Button("Reset") { withAnimation { servings = nil } }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            Stepper(value: Binding(get: { portions }, set: { servings = $0 }), in: 1...50) {
                Text(verbatim: "\(portions)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            .fixedSize()
        }
        .glassCard(cornerRadius: 22, padding: 14)
        .animation(.snappy, value: portions)
    }

    @ViewBuilder
    private func stepsSection(_ recipe: RecipeResolved, _ method: RecipeCookMethod, portions: Int) -> some View {
        let steps = recipe.steps(method)
        if !steps.isEmpty {
            GlassSection(method == .manual ? LocalizedStringKey("By Hand") : LocalizedStringKey("Machine"),
                         systemImage: method == .manual ? "hand.raised" : "gearshape.2", tint: ModuleTint.meals) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text(verbatim: "\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background((method == .manual ? ModuleTint.meals : Color.secondary).gradient, in: .circle)
                        VStack(alignment: .leading, spacing: 6) {
                            if let program = RecipeProgram.title(of: step.programType) {
                                Text(program).font(.subheadline.weight(.semibold)).foregroundStyle(ModuleTint.meals)
                            }
                            if !step.instruction.isEmpty {
                                Text(step.instruction).fixedSize(horizontal: false, vertical: true)
                            }
                            RecipeStepParams(step: step)
                            let lines = recipe.lines(of: step, servings: portions)
                            if !lines.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(lines) { RecipeIngredientLineView(line: $0, compact: true) }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if index < steps.count - 1 { Divider() }
                }
            }
        }
    }

    // MARK: Toolbar and actions

    @ToolbarContentBuilder
    private func toolbar(_ recipe: RecipeResolved) -> some ToolbarContent {
        if family.canEdit {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .keyboardShortcut("e", modifiers: .command)
                Menu {
                    Section("Photo") {
                        Button {
                            #if os(iOS)
                            pickingPhoto = true
                            #else
                            importingPhoto = true
                            #endif
                        } label: {
                            Label("Upload Photo", systemImage: "photo.badge.plus")
                        }
                        #if os(iOS)
                        Button {
                            importingPhoto = true
                        } label: {
                            Label("Choose File", systemImage: "folder")
                        }
                        #endif
                        if ai.photos {
                            Button {
                                generatePhoto()
                            } label: {
                                Label("Generate with AI", systemImage: "sparkles")
                            }
                        }
                        if recipe.detail.imagePath != nil {
                            Button(role: .destructive) {
                                removePhoto()
                            } label: {
                                Label("Remove Photo", systemImage: "photo.badge.minus")
                            }
                        }
                    }
                    .disabled(photoBusy)
                    Section {
                        Button {
                            move(recipe.detail)
                        } label: {
                            if recipe.detail.list == .known {
                                Label("Move to Want to try", systemImage: "arrow.right.arrow.left")
                            } else {
                                Label("Move to Favourites", systemImage: "arrow.right.arrow.left")
                            }
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }

    private func move(_ recipe: RecipeDetail) {
        perform {
            let _: RecipeMoveResponse = try await family.api.send(.post, "/meals/recipes/\(recipe.id)/move")
            family.didChange(.recipes, .meals)
        }
    }

    private func upload(_ data: Data) async {
        photoBusy = true
        defer { photoBusy = false }
        do {
            try await family.api.uploadRecipePhoto(recipeID, data: data)
            family.didChange(.recipes, .meals)
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    private func generatePhoto() {
        photoBusy = true
        perform {
            defer { photoBusy = false }
            let client = family.api.client
            var req = client.request(.post, family.api.path("/meals/recipes/\(recipeID)/image/generate"))
            req.timeoutInterval = 180
            _ = try await client.data(for: req)
            family.didChange(.recipes, .meals)
        }
    }

    private func removePhoto() {
        perform {
            try await family.api.perform(.delete, "/meals/recipes/\(recipeID)/image")
            family.didChange(.recipes, .meals)
        }
    }
}

/// "400 g Tomato": quantity, unit, name.
struct RecipeIngredientLineView: View {
    let line: RecipeResolved.Line
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.quantity)
                .fontWeight(.semibold)
                .monospacedDigit()
            if !line.unit.isEmpty {
                Text(line.unit).foregroundStyle(.secondary)
            }
            Text(line.name)
            Spacer(minLength: 0)
        }
        .font(compact ? .callout : .body)
        .foregroundStyle(compact ? .secondary : .primary)
    }
}

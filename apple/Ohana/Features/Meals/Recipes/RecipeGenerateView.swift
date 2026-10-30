import SwiftUI

/// The recipe generator (web: meals/recipes/generate, generate-recipes.tsx): how many, tags
/// every recipe should have, more wishes, photos (with an image model). The recipes stream in
/// (POST /recipes/generate, NDJSON); the picked ones are saved to "Want to try".
struct RecipeGenerateView: View {
    /// Called after saving (the list switches to "Want to try").
    var onSaved: () -> Void = {}

    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [RecipeTag] = []
    @State private var ai = MealsAIStatus.none
    @State private var count = 5
    @State private var tagIDs: Set<String> = []
    @State private var freeText = ""
    @State private var makePhotos = true
    @State private var results: [Int: Result] = [:]
    @State private var generating = false
    @State private var ran = false
    @State private var saving = false
    @State private var task: Task<Void, Never>?

    struct Result: Equatable {
        var data: RecipeGenerated
        var imageBase64: String?
        var selected = true
    }

    private var ordered: [(index: Int, result: Result)] {
        results.keys.sorted().map { ($0, results[$0]!) }
    }

    private var selectedCount: Int { results.values.filter(\.selected).count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $count, in: 1...20) {
                        LabeledContent("Number of recipes", value: "\(count)")
                    }
                    if ai.photos {
                        Toggle("Make photos", isOn: $makePhotos)
                    }
                }
                .disabled(generating)
                if !tags.isEmpty {
                    Section("Every recipe should be …") {
                        RecipeTagPicker(tags: tags, selection: $tagIDs)
                            .padding(.vertical, 4)
                    }
                    .disabled(generating)
                }
                Section("Additional wishes") {
                    TextField("Additional wishes", text: $freeText,
                              prompt: Text("e.g. comfort food for cold days, ready in 30 minutes"), axis: .vertical)
                        .lineLimit(3...6)
                        .labelsHidden()
                        .onChange(of: freeText) { _, text in if text.count > 2000 { freeText = String(text.prefix(2000)) } }
                }
                .disabled(generating)
                Section {
                    if generating {
                        Button(role: .destructive) {
                            task?.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(waitingForPhotos ? LocalizedStringKey("Making photos …") : LocalizedStringKey("Generating recipes …"))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            generate()
                        } label: {
                            Label("Generate", systemImage: "sparkles").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ModuleTint.meals)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                if !results.isEmpty {
                    Section {
                        ForEach(ordered, id: \.index) { item in
                            RecipeGeneratedRow(result: binding(item.index), waitingForPhoto: waitingForPhotos)
                        }
                    } header: {
                        Text("\(selectedCount) selected")
                    }
                } else if ran && !generating {
                    Section {
                        Text("No recipes came up. Try other settings.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Generate recipes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(role: .confirm) {
                            save()
                        } label: {
                            Text("Save \(selectedCount) recipes")
                        }
                        .disabled(selectedCount == 0 || generating)
                        .keyboardShortcut("s", modifiers: .command)
                    }
                }
            }
        }
        .task {
            tags = (try? await family.api.get("/meals/tags", as: RecipeTagsResponse.self).tags) ?? []
            ai = (try? await family.api.get("/meals/status", as: MealsAIStatus.self)) ?? ai
        }
        .onDisappear { task?.cancel() }
        .interactiveDismissDisabled(generating || !results.isEmpty)
        .recipeSheetFrame(minWidth: 620, minHeight: 700)
    }

    private var waitingForPhotos: Bool { generating && ai.photos && makePhotos && !results.isEmpty }

    private func binding(_ index: Int) -> Binding<Result> {
        Binding(get: { results[index] ?? Result(data: RecipeGenerated.empty) }, set: { results[index] = $0 })
    }

    private func generate() {
        guard let client = app.client else { return }
        results = [:]
        ran = true
        generating = true
        let body = RecipeGenerateRequest(count: count, tagIds: tagIDs.sorted(), freeText: freeText,
                                         generateImages: ai.photos && makePhotos)
        let path = family.api.path("/recipes/generate")
        task = Task {
            defer { generating = false; task = nil }
            do {
                var req = client.request(.post, path, body: try APIClient.encoder.encode(body))
                req.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
                // The model may think for a while before the first line comes.
                req.timeoutInterval = 300
                for try await line in try await client.lines(req) {
                    guard let event = RecipeGenerateEvent.parse(line) else { continue }
                    apply(event)
                    if event == .done { break }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                if !Task.isCancelled {
                    ErrorBanner.shared.show(String(localized: "Generating failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func apply(_ event: RecipeGenerateEvent) {
        switch event {
        case let .recipe(index, data):
            withAnimation { results[index] = Result(data: data) }
        case let .image(index, base64):
            results[index]?.imageBase64 = base64
        case let .imageError(message):
            ErrorBanner.shared.show(String(localized: "The photos couldn’t be made: \(message)"))
        case let .error(message):
            ErrorBanner.shared.show(String(localized: "Generating failed: \(message)"))
        case .done, .unknown:
            break
        }
    }

    private func save() {
        let chosen = ordered.filter(\.result.selected).map {
            RecipeBulkInput.Recipe(generated: $0.result.data, imageBase64: $0.result.imageBase64)
        }
        guard !chosen.isEmpty else { return }
        saving = true
        perform {
            defer { saving = false }
            let client = family.api.client
            var req = client.request(.post, family.api.path("/meals/recipes/bulk"),
                                     body: try APIClient.encoder.encode(RecipeBulkInput(recipes: chosen)))
            req.timeoutInterval = 120
            let (data, _) = try await client.data(for: req)
            let created = (try? APIClient.decoder.decode(RecipeBulkResponse.self, from: data).createdIds.count) ?? chosen.count
            family.didChange(.recipes, .meals)
            ErrorBanner.shared.success(String(localized: "\(created) recipes added to “Want to try”"))
            onSaved()
            dismiss()
        }
    }
}

extension RecipeGenerated {
    static let empty = RecipeGenerated(title: "", description: nil, default_servings: nil, prep_time_minutes: nil,
                                       cook_time_minutes: nil, leftover_days: nil, ingredients: nil, manual_steps: nil,
                                       machine_steps: nil, tag_names_en: nil, tag_ids: nil)
}

/// One generated recipe: pick it, see its photo and (unfolded) ingredients and steps.
private struct RecipeGeneratedRow: View {
    @Binding var result: RecipeGenerateView.Result
    let waitingForPhoto: Bool
    @State private var expanded = false

    var body: some View {
        let d = result.data
        let ingredients = d.ingredients ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Toggle(isOn: $result.selected) { EmptyView() }
                    .labelsHidden()
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .accessibilityLabel(d.title)
                photo
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.title).font(.headline)
                    Text(verbatim: [
                        String(localized: "\(ingredients.count) ingredients"),
                        String(localized: "\(d.default_servings ?? 2) servings"),
                        String(localized: "\((d.prep_time_minutes ?? 0) + (d.cook_time_minutes ?? 0)) min"),
                    ].joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let text = d.description, !text.isEmpty { Text(text).font(.callout) }
                    ForEach(Array(ingredients.enumerated()), id: \.offset) { _, i in
                        Text(verbatim: "• \(i.quantity?.text ?? "") \(i.unit_abbreviation ?? "") \(RecipeLocale.pick(en: i.name_en, de: i.name_de))")
                            .font(.callout)
                    }
                    ForEach(Array((d.manual_steps ?? []).enumerated()), id: \.offset) { n, s in
                        Text(verbatim: "\(n + 1). \(s.instruction ?? "")").font(.callout)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Details").font(.callout)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var photo: some View {
        Group {
            if let base64 = result.imageBase64, let data = Data(base64Encoded: base64), let image = PlatformImage(data: data) {
                #if canImport(UIKit)
                Image(uiImage: image).resizable().scaledToFill()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            } else {
                RecipePhotoPlaceholder()
                    .overlay { if waitingForPhoto { ProgressView().controlSize(.small) } }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(.rect(cornerRadius: 12))
    }
}

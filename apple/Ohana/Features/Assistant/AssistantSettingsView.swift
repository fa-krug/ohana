import SwiftUI

/// Settings → Assistant (web: components/assistant/ai-settings.tsx): the family's
/// OpenAI-compatible AI (provider, key, model; the URL and context window under Advanced; a
/// test), the model for recipe photos, the web search, and whether the assistant may change
/// things. Editors only; viewers see who can set it up. Keys are write-only: the server only
/// says that one is stored (and its last four characters); a blank field keeps it.
struct AssistantSettingsView: View {
    /// Shown as a sheet (from the chat): Cancel asks before unsaved changes are dropped.
    var inSheet = false
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<AssistantSettings> = .idle
    @State private var hasChanges = false

    var body: some View {
        Group {
            if family.canEdit {
                LoadStateView(state: state, retry: load) { settings in
                    AssistantSettingsForm(settings: settings, hasChanges: $hasChanges) { state = .loaded($0) }
                }
            } else {
                AssistantSettingsViewerView()
            }
        }
        .ohanaBackground(ModuleTint.assistant)
        .navigationTitle("Assistant")
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    if hasChanges {
                        CancelButton(hasChanges: true)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .discardGuard(hasChanges: inSheet && hasChanges)
        .task(id: family.revision(.settings)) {
            if family.canEdit { await load() }
        }
    }

    private func load() async {
        await LoadState.run($state) { try await family.api.get("/ai/settings", as: AssistantSettings.self) }
    }
}

/// What a viewer sees: whether the assistant is set up, and who can set it up.
private struct AssistantSettingsViewerView: View {
    @Environment(FamilyContext.self) private var family
    @State private var settings: AssistantSettings?

    var body: some View {
        Form {
            Section {
                if let settings {
                    LabeledContent("Status") {
                        Text(settings.configured ? "Set up" : "Not set up")
                    }
                    if settings.configured, !settings.model.isEmpty {
                        LabeledContent("Model") { Text(verbatim: settings.model) }
                    }
                }
            } footer: {
                Text("Only editors of the family can set up the assistant. You can chat with it once it is set up; it only reads for you.")
            }
        }
        .formStyle(.grouped)
        .task { settings = try? await family.api.get("/ai/settings", as: AssistantSettings.self) }
    }
}

private struct AssistantSettingsForm: View {
    @Environment(FamilyContext.self) private var family
    let settings: AssistantSettings
    @Binding var hasChanges: Bool
    let saved: (AssistantSettings) -> Void

    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var imageModel = ""
    /// Tokens as typed; "" finds the window out.
    @State private var contextWindow = ""
    @State private var models: [String]?
    @State private var searchProvider = "none"
    @State private var searchKey = ""
    @State private var busy: Busy?
    @State private var test: (ok: Bool, text: String)?
    @State private var applied: AssistantSettings?
    /// "Other" picked as the provider: the API URL is typed under Advanced.
    @State private var customProvider = false
    @State private var showAdvanced = false
    @State private var confirmRemoveKey = false

    private enum Busy { case save, models, test }

    private var dirty: Bool {
        baseUrl != (settings.baseUrl ?? "")
            || model != settings.model
            || (Int(contextWindow) ?? 0) != (settings.contextWindow ?? 0)
            || !apiKey.isEmpty
            || imageModel != (settings.imageModel ?? "")
            || searchProvider != (settings.searchProvider ?? "none")
            || !searchKey.isEmpty
    }

    var body: some View {
        Form {
            endpointSection
            advancedSection
            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    if busy == .test { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .buttonStyle(.bordered)
                .disabled(busy != nil || !settings.configured || dirty)
                if let test {
                    Label {
                        Text(verbatim: test.text)
                    } icon: {
                        Image(systemName: test.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(test.ok ? .green : .red)
                    }
                    .font(.callout)
                }
            }
            photosSection
            searchSection
            permissionsSection
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if busy == .save { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy != nil || !dirty)
            }
        }
        .onAppear { apply(settings) }
        .onChange(of: settings) { apply(settings) }
        .onChange(of: dirty, initial: true) { hasChanges = dirty }
        .confirmationDialog("Remove the API key?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                Task { await save(.init(apiKey: "")) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The assistant stops working for everyone in the family until a new key is saved.")
        }
    }

    /// The provider picked: a preset, "other", or "" for none yet.
    private var provider: Binding<String> {
        Binding {
            customProvider ? AssistantProviders.other : AssistantProviders.provider(for: baseUrl)
        } set: { name in
            if let url = AssistantProviders.url(of: name) {
                customProvider = false
                baseUrl = url
            } else if name == AssistantProviders.other {
                if AssistantProviders.url(of: AssistantProviders.provider(for: baseUrl)) != nil { baseUrl = "" }
                customProvider = true
                showAdvanced = true
            }
        }
    }

    // MARK: Sections

    private var endpointSection: some View {
        Section {
            Picker("Provider", selection: provider) {
                if provider.wrappedValue.isEmpty { Text("Choose…").tag("") }
                ForEach(AssistantProviders.presets, id: \.name) { preset in
                    Text(verbatim: preset.name).tag(preset.name)
                }
                Text("Other (OpenAI-compatible)").tag(AssistantProviders.other)
            }
            .onChange(of: baseUrl) { models = nil }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SecureField("API key", text: $apiKey,
                                prompt: Text(verbatim: settings.hasKey == true ? "••••••••\(settings.keyHint ?? "")" : "sk-…"))
                    if settings.hasKey == true {
                        Button("Remove", role: .destructive) { confirmRemoveKey = true }
                            .disabled(busy != nil)
                    }
                }
                Group {
                    if settings.hasKey == true {
                        Text("A key ending in \(settings.keyHint ?? "") is saved. Type a new one to replace it.")
                    } else {
                        Text("Stored encrypted on the server and never shown again.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let models, !models.isEmpty {
                        Picker("Model", selection: $model) {
                            if model.isEmpty { Text("Pick a model").tag("") }
                            ForEach(Self.unique([model] + models).filter { !$0.isEmpty }, id: \.self) { m in
                                Text(verbatim: m).tag(m)
                            }
                        }
                    } else {
                        TextField("Model", text: $model, prompt: Text(verbatim: "gpt-4.1-mini"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    Button {
                        Task { await loadModels() }
                    } label: {
                        if busy == .models {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Load models", systemImage: "arrow.clockwise")
                        }
                    }
                    #if os(iOS)
                    // Just the icon: the label wraps next to the model on an iPhone.
                    .labelStyle(.iconOnly)
                    #endif
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Load models")
                    .disabled(baseUrl.isEmpty || busy != nil)
                }
                Text("Load the list from the API, or type a model name. It needs to support tool calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI model")
        } footer: {
            Text("Pick the AI service you have an account with and paste its key. Everyone in the family uses this setup.")
        }
    }

    /// What only some need: another service's address, a model's context window.
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("API URL", text: $baseUrl, prompt: Text(verbatim: "https://api.openai.com/v1"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Group {
                        Text("Any API that speaks OpenAI’s chat format with tool calls.")
                        Text("Including the version, e.g. …/v1. A model on your home network works only if the server allows it (AI_ALLOW_PRIVATE_ENDPOINT).")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Context window (tokens)", text: $contextWindow, prompt: Text(verbatim: "128000"))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text("How many tokens the model takes at once. Empty: from the API’s model list if it says, else 128,000. Long chats are condensed before it is full.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var photosSection: some View {
        Section {
            HStack {
                TextField("Image model", text: $imageModel, prompt: Text(verbatim: "gpt-image-1"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if let models, !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { m in
                            Button { imageModel = m } label: { Text(verbatim: m) }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("Pick a model"))
                }
            }
        } header: {
            Text("Recipe photos")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("The meals module can make a photo of a recipe with an image model of the same API. Without one, the photo buttons stay hidden.")
                Text("E.g. gpt-image-1 or dall-e-3 (OpenAI), gemini-2.5-flash-image (Google’s Gemini API). Empty: no AI photos.")
            }
        }
    }

    private var searchSection: some View {
        Section {
            Picker("Search provider", selection: $searchProvider) {
                Text("Off").tag("none")
                Text(verbatim: "Tavily").tag("tavily")
                Text(verbatim: "Brave Search").tag("brave")
            }
            if searchProvider != "none" {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Search API key", text: $searchKey,
                                prompt: Text(verbatim: settings.hasSearchKey == true ? "••••••••\(settings.searchKeyHint ?? "")" : ""))
                    if settings.hasSearchKey == true {
                        Text("A key ending in \(settings.searchKeyHint ?? "") is saved. Type a new one to replace it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Web search")
        } footer: {
            Text("Lets the assistant search the web (e.g. for school holidays). Without it, it can still read pages you link.")
        }
    }

    private var permissionsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.allowWrites },
                set: { value in Task { await save(.init(allowWrites: value)) } }
            )) {
                Text("Allow changes")
                Text("The assistant may change the calendar, finances, meals and appointment searches for editors (most changes can be undone). Off: it only reads. For viewers it always only reads.")
            }
            .disabled(busy != nil)
        } header: {
            Text("Permissions")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your messages and the data the assistant looks at are sent to the AI API you set up above.")
                HStack(spacing: 4) {
                    Text("For other AI agents that use Ohana’s API with an API token:")
                    Link(destination: family.api.client.url(family.api.path("/agent"))) {
                        Text("instructions for AI agents")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func apply(_ s: AssistantSettings) {
        guard applied != s else { return }
        applied = s
        baseUrl = s.baseUrl ?? ""
        customProvider = AssistantProviders.provider(for: baseUrl) == AssistantProviders.other
        model = s.model
        imageModel = s.imageModel ?? ""
        contextWindow = (s.contextWindow ?? 0) > 0 ? String(s.contextWindow ?? 0) : ""
        searchProvider = s.searchProvider ?? "none"
        apiKey = ""
        searchKey = ""
    }

    private func save(_ patch: AssistantSettingsPatch? = nil) async {
        busy = .save
        defer { busy = nil }
        var body = AssistantSettingsPatch(
            baseUrl: baseUrl.trimmingCharacters(in: .whitespaces), model: model.trimmingCharacters(in: .whitespaces),
            searchProvider: searchProvider,
            contextWindow: Int(contextWindow.trimmingCharacters(in: .whitespaces)) ?? 0, imageModel: imageModel
        )
        if !apiKey.isEmpty { body.apiKey = apiKey }
        if !searchKey.isEmpty { body.searchKey = searchKey }
        if let patch {
            if patch.apiKey != nil { body.apiKey = patch.apiKey }
            if patch.allowWrites != nil { body.allowWrites = patch.allowWrites }
        }
        do {
            let result = try await family.api.send(.put, "/ai/settings", body: body, as: AssistantSettings.self)
            saved(result)
            apply(result)
            family.didChange(.settings)
            ErrorBanner.shared.success(String(localized: "Saved."))
        } catch {
            ErrorBanner.shared.show(String(localized: "Couldn’t save: \(error.localizedDescription)"))
        }
    }

    private func loadModels() async {
        busy = .models
        defer { busy = nil }
        struct Body: Encodable { let baseUrl: String; let apiKey: String? }
        do {
            let result = try await family.api.send(
                .post, "/ai/models", body: Body(baseUrl: baseUrl, apiKey: apiKey.isEmpty ? nil : apiKey),
                as: AssistantModelList.self
            )
            models = result.models
            if model.isEmpty, let first = result.models.first { model = first }
            if result.models.isEmpty { ErrorBanner.shared.show(String(localized: "The API returned no models")) }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    private func runTest() async {
        busy = .test
        test = nil
        defer { busy = nil }
        do {
            let r = try await family.api.send(.post, "/ai/test", body: Empty(), as: AssistantTestResult.self)
            let reply = r.reply.isEmpty ? "…" : r.reply
            test = (true, String(localized: "\(r.model) answered: \(reply)"))
        } catch {
            test = (false, error.localizedDescription)
        }
    }

    static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

/// The AI services the settings offer by name (their OpenAI-compatible endpoints); any other is
/// "other", with its URL typed under Advanced.
enum AssistantProviders {
    static let presets: [(name: String, url: String)] = [
        ("OpenAI", "https://api.openai.com/v1"),
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("Mistral", "https://api.mistral.ai/v1"),
        ("Groq", "https://api.groq.com/openai/v1"),
        ("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
        ("Ollama", "http://localhost:11434/v1"),
    ]

    static let other = "other"

    /// The preset an API URL belongs to (a trailing slash doesn't matter), "other" for any
    /// other URL, "" for none.
    static func provider(for url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty { return "" }
        return presets.first { $0.url.caseInsensitiveCompare(trimmed) == .orderedSame }?.name ?? other
    }

    static func url(of provider: String) -> String? {
        presets.first { $0.name == provider }?.url
    }
}
